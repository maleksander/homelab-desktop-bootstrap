#!/usr/bin/env bash
# The first boot, after install.sh: from a bare system to the whole machine.
# Run as the user, on the console, with a card plugged in:
#
#   curl -fsSLO https://raw.githubusercontent.com/maleksander/homelab-desktop-bootstrap/main/first-boot.sh
#   bash first-boot.sh
#
# The card is the only credential: its authentication key is the owner's on
# GitHub, so it clones the private repositories, and Ansible does the rest
# (homelab-desktop). It asks for the card's PIN once, a touch per connection, and
# the user's password for sudo. Safe to run again.
set -euo pipefail

OWNER=maleksander
PROJECTS="$HOME/projects"
REPOSITORIES=(homelab-ops homelab-platform homelab-desktop)
# github.com's own key: public, published by GitHub, pinned so the first connection
# is not a blind trust.
GITHUB_HOST_KEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

die() { printf 'first-boot: %s\n' "$1" >&2; exit 1; }
say() { printf '\n==> %s\n' "$1"; }

[ "$(id -u)" -ne 0 ] || die "run it as the user, not root"
[ -n "$(tty 2>/dev/null || true)" ] || die "run it on a terminal: the card's PIN is asked here"

# ---- The card, as the SSH agent. ----
# The same places dotfiles uses, which replaces these two small files later.
say "The card"
export GNUPGHOME="$HOME/.local/share/gnupg"
mkdir -p "$GNUPGHOME"
chmod 0700 "$GNUPGHOME"
[ -e "$GNUPGHOME/gpg-agent.conf" ] || echo enable-ssh-support > "$GNUPGHOME/gpg-agent.conf"
# Through pcscd: without this scdaemon and pcscd fight over the card's USB interface.
[ -e "$GNUPGHOME/scdaemon.conf" ] || echo disable-ccid > "$GNUPGHOME/scdaemon.conf"
export GPG_TTY
GPG_TTY="$(tty)"
gpgconf --launch gpg-agent
SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
export SSH_AUTH_SOCK
gpg-connect-agent updatestartuptty /bye >/dev/null
until gpg --card-status >/dev/null 2>&1; do
  read -rp "No card found. Plug one in, then press Enter. "
done
# scdaemon has now read the card, which is what lets the agent offer its key.
ssh-add -L | grep -q . || die "the agent offers no key: is this card one of the owner's?"

# ---- The repositories, over the card. ----
say "The repositories (a touch for each)"
mkdir -p "$HOME/.ssh" "$PROJECTS"
chmod 0700 "$HOME/.ssh"
grep -qsF "$GITHUB_HOST_KEY" "$HOME/.ssh/known_hosts" || echo "$GITHUB_HOST_KEY" >> "$HOME/.ssh/known_hosts"
# unbound: gpg-agent cannot sign the card's Ed25519 over the longer host-bound form.
export GIT_SSH_COMMAND='ssh -o PubkeyAuthentication=unbound -o StrictHostKeyChecking=yes'
for repository in "${REPOSITORIES[@]}"; do
  if [ -d "$PROJECTS/$repository/.git" ]; then
    git -C "$PROJECTS/$repository" pull --ff-only --quiet
    echo "$repository: up to date"
  else
    git clone "git@github.com:$OWNER/$repository.git" "$PROJECTS/$repository"
  fi
done

# ---- Ansible, and the rest. ----
say "Ansible"
sudo pacman -Syu --needed --noconfirm ansible-core
cd "$PROJECTS/homelab-desktop/ansible"
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml --ask-become-pass

# ---- What needs the card and the lab. ----
# The sign-in kubeconfig holds the cluster's public CA, read over SSH with the card:
# Ansible has no agent. Needs the lab: on another network, it is left for later.
say "kubectl, through Authentik (a touch)"
cd "$PROJECTS/homelab-ops"
if mise run kubeconfig && mise exec -- scripts/kubeconfig_oidc.sh; then
  rm -f "$XDG_RUNTIME_DIR/homelab-admin.yaml"
else
  echo "Not reachable from here: later, in homelab-ops, mise run kubeconfig, then scripts/kubeconfig_oidc.sh"
fi

say "Done. Reboot into the desktop."

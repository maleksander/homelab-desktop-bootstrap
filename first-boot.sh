#!/usr/bin/env bash
# The first boot, after install.sh: from a bare system to the whole machine.
# Run as the user, on the console, with a card plugged in:
#
#   curl -fsSLO https://raw.githubusercontent.com/maleksander/homelab-desktop-bootstrap/main/first-boot.sh
#   bash first-boot.sh
#
# Checked first against its signature and the card (README, "Checking the scripts").
#
# The card is the only credential: its authentication key is the owner's on
# GitHub, so it clones the private repositories, and Ansible does the rest
# (homelab-desktop). It asks for the card's PIN once, a touch per connection, and
# the user's password for sudo. Safe to run again.
set -euo pipefail

OWNER=maleksander
PROJECTS="$HOME/projects"
REPOSITORIES=(homelab-ops homelab-platform homelab-desktop dotfiles)
# github.com's own key: public, published by GitHub, pinned so the first connection
# is not a blind trust.
GITHUB_HOST_KEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

die() { printf 'first-boot: %s\n' "$1" >&2; exit 1; }
say() { printf '\n==> %s\n' "$1"; }

[ "$(id -u)" -ne 0 ] || die "run it as the user, not root"
[ -n "$(tty 2>/dev/null || true)" ] || die "run it on a terminal: the card's PIN is asked here"

# sudo's password once, here, and kept fresh for the whole run: Ansible's first run is
# long, and sudo's prompt later on (the restore) gives up after 5 minutes unanswered.
sudo -v
while sleep 60; do sudo -n -v 2>/dev/null || exit; done &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

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
# A gpg in ~/.gnupg (the signature's check, README) left its scdaemon holding the card:
# ours then finds none (2026-11-15, the VM). Stopped; nothing else uses ~/.gnupg here.
[ ! -d "$HOME/.gnupg" ] || gpgconf --homedir "$HOME/.gnupg" --kill all 2>/dev/null || true
gpgconf --launch gpg-agent
SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
export SSH_AUTH_SOCK
gpg-connect-agent updatestartuptty /bye >/dev/null
until gpg --card-status >/dev/null 2>&1; do
  read -rp "No card found. Plug one in, then press Enter. "
  # scdaemon keeps a "no card" it once saw: a fresh one looks again.
  gpgconf --kill scdaemon
done
# scdaemon has now read the card, which is what lets the agent offer its key.
ssh-add -L | grep -q . || die "the agent offers no key: is this card one of the owner's?"

# ---- The repositories, over the card. ----
say "The repositories (a touch for each)"
mkdir -p "$HOME/.ssh" "$PROJECTS"
chmod 0700 "$HOME/.ssh"
grep -qsF "$GITHUB_HOST_KEY" "$HOME/.ssh/known_hosts" || echo "$GITHUB_HOST_KEY" >> "$HOME/.ssh/known_hosts"
# unbound: gpg-agent cannot sign the card's Ed25519 over the longer host-bound form.
SSH=(ssh -o PubkeyAuthentication=unbound -o StrictHostKeyChecking=yes)
export GIT_SSH_COMMAND="${SSH[*]}"
# A sign-in first, for the PIN: GitHub drops a login that waits on it, which would stop
# the clone. The second try finds the PIN entered. Only two: a wrong PIN costs a try of
# three. Its words, not its exit: GitHub offers no shell, so a good sign-in exits 1.
github_sign_in() {
  local answer
  answer="$("${SSH[@]}" -T git@github.com 2>&1 || true)"
  [[ $answer == *"successfully authenticated"* ]]
}
if ! github_sign_in && ! github_sign_in; then
  die "no sign-in to GitHub: the PIN and a touch must both land in time. Run this again: the PIN stays entered"
fi
for repository in "${REPOSITORIES[@]}"; do
  if [ -d "$PROJECTS/$repository/.git" ]; then
    git -C "$PROJECTS/$repository" pull --ff-only --quiet
    echo "$repository: up to date"
  else
    git clone "git@github.com:$OWNER/$repository.git" "$PROJECTS/$repository"
  fi
done

# The password store, when it has been pushed: pass-from-bitwarden makes it otherwise.
# Where dotfiles' PASSWORD_STORE_DIR points.
PASS_STORE="$HOME/.local/share/pass"
if [ ! -d "$PASS_STORE/.git" ] && [ -n "$(git ls-remote "git@github.com:$OWNER/pass-store.git" HEAD 2>/dev/null)" ]; then
  mkdir -p "$(dirname "$PASS_STORE")"
  git clone "git@github.com:$OWNER/pass-store.git" "$PASS_STORE"
fi

# ---- Ansible, and the rest. ----
say "Ansible"
sudo pacman -Syu --needed --noconfirm ansible-core
cd "$PROJECTS/homelab-desktop/ansible"
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml --ask-become-pass

# ---- The data, from the NAS (homelab-desktop's docs/restic.md, "A new install"). ----
# /data's newest backup: the owner's files and Claude Code's state (/data/claude), before
# anything starts Claude Code and fills it. Only into an empty /data (a run again finds
# it restored and passes by), only where the NAS answers (at home); asks for the
# repository's password and this machine's rest-server login, both in Bitwarden.
if [ -z "$(find /data -mindepth 2 -not -path '/data/.snapshots*' -print -quit 2>/dev/null)" ]; then
  say "Your data, from the NAS"
  if ! sudo -n true 2>/dev/null; then
    echo "sudo wants its password again: skipped. Later: sudo data-backup setup, then restore."
  elif ! sudo -n data-backup reachable; then
    echo "The NAS does not answer from here: later, at home, sudo data-backup setup, then restore."
  elif read -rp "Restore /data from its newest backup now? [Y/n] " a && [[ ${a:-y} == [Yy]* ]]; then
    # In an if: a password mistyped or the prompt left skips the restore, not first-boot.
    if { sudo test -s /etc/restic/rest.env || sudo data-backup setup; } \
       && sudo data-backup snapshots && sudo data-backup restore; then
      echo "Restored into /data."
    else
      echo "Not restored: sudo data-backup setup (if a password was wrong), then sudo data-backup restore."
    fi
  fi
fi

# ---- The folders shared through the NAS (Syncthing; homelab-desktop's plan-sync.md). ----
# After the restore, not in the Ansible run above: the restore puts back this machine's
# Syncthing key (/data/syncthing), so a reinstalled machine stays the same device to the
# NAS. Where there was none to restore, one is made, and its device ID said -- for
# homelab-ops' syncthing_hub_devices. The folders' password from pass, with the card.
say "Syncthing, the folders shared through the NAS (BECOME: your password again)"
if ! (cd "$PROJECTS/homelab-desktop/ansible" &&
      ansible-playbook playbooks/site.yml --tags sync -e sync_new_identity=true --ask-become-pass); then
  echo "Not set up: later, in homelab-desktop/ansible, site.yml --tags sync -e sync_new_identity=true -K"
fi

# ---- dotfiles' own bootstrap: nvim and the notebook, over the card. ----
say "dotfiles (a touch for each clone)"
yadm bootstrap

# zsh's plugins, public, once and over HTTPS: dotfiles turns GitHub's URLs into SSH, so
# the first terminal would otherwise ask for the card for every plugin.
say "zsh's plugins"
GIT_CONFIG_GLOBAL=/dev/null zsh -ic exit || true

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

say "Done. Reboot into the desktop. pass-from-bitwarden copies the vault into pass."

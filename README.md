# homelab-desktop-bootstrap

What runs before a machine has any credential: `install.sh` installs Arch from
the ISO, and `first-boot.sh` takes it from there with the owner's card. Public for
that reason; it holds no secret.

```bash
# On the Arch ISO, as root (Wi-Fi first if needed: iwctl).
curl -fsSL --remote-name-all \
  'https://raw.githubusercontent.com/maleksander/homelab-desktop-bootstrap/main/{install.sh,install.sh.asc,owner-2026.asc}'
# Checking the scripts, below: before running anything as root.
less install.sh      # it erases a disk: read it
ls -l /dev/disk/by-id | grep -v part     # the disks by model and serial: pick the one to erase
bash install.sh --disk /dev/disk/by-id/nvme-<model>_<serial> --hostname laptop --user masander
```

## Checking the scripts

Both scripts are signed by the owner's card (M1's signing key): `install.sh.asc`,
`first-boot.sh.asc`. The card is what makes the check worth anything: a key from this
repository alone would prove only that whoever changed the script also changed the key.

```bash
export GNUPGHOME="$(mktemp -d)"  # a throwaway keyring, for the check alone
gpg --import owner-2026.asc
gpg --verify install.sh.asc install.sh
#   Good signature ... using EDDSA key EE1E8CDC13115D94501B7BE42AA1A1FAE7227C0A
systemctl start pcscd            # the ISO's card service; the card plugged in
gpg --card-status | grep -i 'signature key'
#   Signature key ....: EE1E 8CDC 1311 5D94 501B  7BE4 2AA1 A1FA E722 7C0A
```

The two fingerprints must be the same; if not, or not a good signature, stop. The same
for `first-boot.sh` after the first boot (`curl` its `.asc` too).

**The throwaway keyring** (`GNUPGHOME` in a temporary directory): without it, the check
after the first boot writes a keyring into `~/.gnupg` -- before `first-boot.sh` sets the
machine's own (`~/.local/share/gnupg`) -- and it stays, unused and in the way: a tool that
looks for GnuPG without `GNUPGHOME` finds that one (found 2026-11-22: the touch
notifier would have watched its agent; removed then).

**After changing a script**: `mise run sign` (a touch per script), then commit the
`.asc` files with it. The pre-commit hook refuses a commit whose staged scripts the
signatures do not match.

**It erases the disk**, after asking you to type the disk's name.

Then, after the reboot, as the user, on the console, with a card plugged in:

```bash
curl -fsSL --remote-name-all \
  'https://raw.githubusercontent.com/maleksander/homelab-desktop-bootstrap/main/{first-boot.sh,first-boot.sh.asc,owner-2026.asc}'
( export GNUPGHOME="$(mktemp -d)"     # the throwaway keyring, as above
  gpg --import owner-2026.asc && gpg --verify first-boot.sh.asc first-boot.sh
  gpg --card-status | grep -i 'signature key'
  gpgconf --kill all )                 # its agent and scdaemon gone: they would hold the card
bash first-boot.sh
```

The card is the only credential the machine needs: it clones the private
repositories, and Ansible builds the rest. At home, it then offers to restore `/data` from its newest
backup on the NAS -- the owner's files and Claude Code's state -- asking for the
backup's two passwords (Bitwarden).

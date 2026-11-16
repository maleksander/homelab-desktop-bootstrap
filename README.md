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
gpg --import owner-2026.asc
gpg --verify install.sh.asc install.sh
#   Good signature ... using EDDSA key EE1E8CDC13115D94501B7BE42AA1A1FAE7227C0A
systemctl start pcscd            # the ISO's card service; the card plugged in
gpg --card-status | grep -i 'signature key'
#   Signature key ....: EE1E 8CDC 1311 5D94 501B  7BE4 2AA1 A1FA E722 7C0A
```

The two fingerprints must be the same; if not, or not a good signature, stop. The same
for `first-boot.sh` after the first boot (`curl` its `.asc` too).

**After changing a script**: `mise run sign` (a touch per script), then commit the
`.asc` files with it. The pre-commit hook refuses a commit whose staged scripts the
signatures do not match.

**It erases the disk**, after asking you to type the disk's name.

Then, after the reboot, as the user, on the console, with a card plugged in:

```bash
curl -fsSL --remote-name-all \
  'https://raw.githubusercontent.com/maleksander/homelab-desktop-bootstrap/main/{first-boot.sh,first-boot.sh.asc,owner-2026.asc}'
gpg --import owner-2026.asc && gpg --verify first-boot.sh.asc first-boot.sh   # and the card, as above
bash first-boot.sh
```

The card is the only credential the machine needs: it clones the private
repositories, and Ansible builds the rest. At home, it then offers to restore `/data` from its newest
backup on the NAS -- the owner's files and Claude Code's state -- asking for the
backup's two passwords (Bitwarden).

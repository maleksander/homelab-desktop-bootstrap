# homelab-desktop-bootstrap

What runs before a machine has any credential: `install.sh` installs Arch from
the ISO, and `first-boot.sh` takes it from there with the owner's card. Public for
that reason; it holds no secret.

```bash
# On the Arch ISO, as root (Wi-Fi first if needed: iwctl).
curl -fsSLO https://raw.githubusercontent.com/maleksander/homelab-desktop-bootstrap/main/install.sh
less install.sh      # it erases a disk: read it
bash install.sh --disk /dev/nvme0n1 --hostname laptop --user masander
```

**It erases the disk**, after asking you to type the disk's name.

Then, after the reboot, as the user, on the console, with a card plugged in:

```bash
curl -fsSLO https://raw.githubusercontent.com/maleksander/homelab-desktop-bootstrap/main/first-boot.sh
bash first-boot.sh
```

The card is the only credential the machine needs: it clones the private
repositories, and Ansible builds the rest.

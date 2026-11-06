# homelab-desktop-bootstrap

Installs Arch Linux from the Arch ISO: the disk, the base system, the boot
loader, one user. Public because it has to be reachable before any credential
exists on the machine; it holds no secret and nothing else.

```bash
# On the Arch ISO, as root (Wi-Fi first if needed: iwctl).
curl -fsSLO https://raw.githubusercontent.com/maleksander/homelab-desktop-bootstrap/main/install.sh
less install.sh      # it erases a disk: read it
bash install.sh --disk /dev/nvme0n1 --hostname hektor --user masander
```

**It erases the disk**, after asking you to type the disk's name.

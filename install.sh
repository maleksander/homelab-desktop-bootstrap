#!/usr/bin/env bash
# Install Arch Linux on this machine, from the Arch ISO: the disk, the base
# system, the boot loader, one user. Nothing else -- everything after the first
# boot is homelab-desktop's (Ansible), which the card fetches.
#
#   ./install.sh --disk /dev/nvme0n1 --hostname hektor --user masander
#
# THIS ERASES THE DISK. It asks you to type the disk's name first. Passwords
# are asked at the prompt and never appear in an argument, a file or the shell
# history; root's stays locked (sudo is the way to root).
#
# The layout: an EFI system partition (1 GiB, /boot) and the rest as root,
# btrfs: subvolumes @ (/), @home, @snapshots (outside @, so a snapshot can
# replace it), and @log and @pkg, kept out of root's snapshots so a rollback
# does not lose logs or re-download packages. No swap
# partition: zram, so nothing of memory reaches the disk in the clear.
set -euo pipefail

TIMEZONE="Europe/Warsaw"
MOUNT=/mnt
ESP_SIZE=1G
BTRFS_OPTIONS=noatime,compress=zstd:1

disk="" hostname="" user=""
while [ $# -gt 0 ]; do
  case "$1" in
    --disk)     disk="${2:-}"; shift 2 ;;
    --hostname) hostname="${2:-}"; shift 2 ;;
    --user)     user="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) printf 'install: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

die() { printf 'install: %s\n' "$1" >&2; exit 1; }
say() { printf '\n==> %s\n' "$1"; }

# ---- Refuse anything but the intended situation, before touching a disk. ----
[ "$(id -u)" -eq 0 ] || die "run it as root, from the Arch ISO"
[ -d /run/archiso ] || die "this is not the Arch ISO: refusing to repartition a running system"
[ -d /sys/firmware/efi/efivars ] || die "not booted in UEFI mode: systemd-boot needs it"
[ -n "$disk" ] && [ -n "$hostname" ] && [ -n "$user" ] || die "--disk, --hostname and --user are all required (--help)"
[ -b "$disk" ] || die "$disk is not a block device"
[ "$(lsblk -dno TYPE "$disk")" = disk ] || die "$disk is not a whole disk"
[[ "$hostname" =~ ^[a-z0-9-]+$ ]] || die "the hostname: lowercase letters, digits and - only"
[[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "the user name: lowercase letters, digits, _ and - only"
if lsblk -no MOUNTPOINTS "$disk" | grep -q .; then
  die "$disk has something mounted: unmount it first"
fi
curl -fsS --max-time 15 -o /dev/null https://archlinux.org || die "no internet (Wi-Fi: iwctl; docs in the README)"

# ---- The passwords, before the long part: nothing to wait for afterwards. ----
read_password() {
  local a b
  while :; do
    IFS= read -rsp "Password for $user: " a; echo
    IFS= read -rsp "Again: " b; echo
    [ -n "$a" ] && [ "$a" = "$b" ] && break
    echo "They differ, or are empty. Again."
  done
  password="$a"
}
password=""
read_password

# ---- The one irreversible step. ----
echo
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL "$disk"
echo
printf 'Everything on %s will be ERASED. Type the disk name to go on: ' "$disk"
IFS= read -r answer
[ "$answer" = "$disk" ] || die "not confirmed: nothing was changed"

# ---- The disk. ----
say "Partitioning $disk"
# Partition names: /dev/nvme0n1 -> /dev/nvme0n1p1, /dev/vda -> /dev/vda1.
case "$disk" in
  *[0-9]) part="${disk}p" ;;
  *)      part="$disk" ;;
esac
wipefs --all --force "$disk"
sgdisk --zap-all "$disk" >/dev/null
sgdisk --new=1:0:+"$ESP_SIZE" --typecode=1:ef00 --change-name=1:ESP \
       --new=2:0:0 --typecode=2:8304 --change-name=2:root "$disk" >/dev/null
partprobe "$disk"
udevadm settle
mkfs.fat -F 32 -n ESP "${part}1" >/dev/null
mkfs.btrfs -q -f -L root "${part}2"
mount "${part}2" "$MOUNT"
for subvolume in @ @home @snapshots @log @pkg; do
  btrfs -q subvolume create "$MOUNT/$subvolume"
done
umount "$MOUNT"
mount -o "$BTRFS_OPTIONS,subvol=@" "${part}2" "$MOUNT"
mount --mkdir -o "$BTRFS_OPTIONS,subvol=@home" "${part}2" "$MOUNT/home"
mount --mkdir -o "$BTRFS_OPTIONS,subvol=@snapshots" "${part}2" "$MOUNT/.snapshots"
mount --mkdir -o "$BTRFS_OPTIONS,subvol=@log" "${part}2" "$MOUNT/var/log"
mount --mkdir -o "$BTRFS_OPTIONS,subvol=@pkg" "${part}2" "$MOUNT/var/cache/pacman/pkg"
mount --mkdir -o fmask=0077,dmask=0077 "${part}1" "$MOUNT/boot"

# ---- The base system. ----
say "Installing the base system"
ucode=""
case "$(awk '/vendor_id/{print $3; exit}' /proc/cpuinfo)" in
  GenuineIntel) ucode=intel-ucode ;;
  AuthenticAMD) ucode=amd-ucode ;;
esac
# Read by mkinitcpio while pacstrap installs the kernel, so it comes first.
mkdir -p "$MOUNT/etc"
echo 'KEYMAP=us' > "$MOUNT/etc/vconsole.conf"
# git, gnupg, the PC/SC stack and an SSH client: what the card needs to fetch
# homelab-desktop on the first boot. openssh brings sshd too: it is not enabled.
pacstrap -K "$MOUNT" base linux linux-firmware $ucode btrfs-progs sudo networkmanager zram-generator \
  git gnupg pcsclite ccid openssh
# By subvolume name only: a subvolid in fstab would pin the mount to the old
# subvolume after a rollback.
genfstab -U "$MOUNT" | sed -E 's/,?subvolid=[0-9]+//' >> "$MOUNT/etc/fstab"

# ---- The configuration, inside it. ----
say "Configuring"
echo "$hostname" > "$MOUNT/etc/hostname"
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s\n' "$hostname" >> "$MOUNT/etc/hosts"
printf 'en_US.UTF-8 UTF-8\npl_PL.UTF-8 UTF-8\n' >> "$MOUNT/etc/locale.gen"
cat > "$MOUNT/etc/locale.conf" <<LOCALE
LANG=en_US.UTF-8
LC_ADDRESS=pl_PL.UTF-8
LC_IDENTIFICATION=pl_PL.UTF-8
LC_MEASUREMENT=pl_PL.UTF-8
LC_MONETARY=pl_PL.UTF-8
LC_NAME=pl_PL.UTF-8
LC_NUMERIC=pl_PL.UTF-8
LC_PAPER=pl_PL.UTF-8
LC_TELEPHONE=pl_PL.UTF-8
LC_TIME=pl_PL.UTF-8
LOCALE
printf '[zram0]\nzram-size = min(ram / 2, 8192)\n' > "$MOUNT/etc/systemd/zram-generator.conf"
echo '%wheel ALL=(ALL:ALL) ALL' > "$MOUNT/etc/sudoers.d/wheel"
chmod 0440 "$MOUNT/etc/sudoers.d/wheel"
# resolved's stub: made here, before the service first starts, or it imports
# NetworkManager's file as global servers (homelab-ops docs/operator.md).
ln -sf ../run/systemd/resolve/stub-resolv.conf "$MOUNT/etc/resolv.conf"

arch-chroot "$MOUNT" /bin/bash -euo pipefail <<CHROOT
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
locale-gen >/dev/null
useradd --create-home --groups wheel "$user"
passwd --lock root >/dev/null
systemctl enable NetworkManager systemd-resolved systemd-timesyncd pcscd.socket
CHROOT
printf '%s:%s\n' "$user" "$password" | arch-chroot "$MOUNT" chpasswd
password=""

# ---- The boot loader. ----
# From the ISO's side, not the chroot's: inside it bootctl skips the firmware's
# variables, and the machine would only boot through the fallback path.
bootctl --esp-path="$MOUNT/boot" install
root_uuid="$(blkid -s PARTUUID -o value "${part}2")"
initrd_ucode=""
[ -z "$ucode" ] || initrd_ucode="initrd  /$ucode.img"
printf 'default arch.conf\ntimeout 2\neditor no\n' > "$MOUNT/boot/loader/loader.conf"
for entry in arch fallback; do
  image=initramfs-linux.img
  [ "$entry" = arch ] || image=initramfs-linux-fallback.img
  cat > "$MOUNT/boot/loader/entries/$entry.conf" <<ENTRY
title   Arch Linux ($entry)
linux   /vmlinuz-linux
$initrd_ucode
initrd  /$image
options root=PARTUUID=$root_uuid rootflags=subvol=@ rw
ENTRY
done

umount -R "$MOUNT"
say "Done. Remove the install medium and reboot."

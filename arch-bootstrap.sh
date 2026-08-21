#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_ROOT_DEV=/dev/nvme1n1p3
EXPECTED_BOOT_DEV=/dev/nvme1n1p5
USER_NAME=magetsu
HOST_NAME=predator

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run as root inside arch-chroot"

ROOT_SOURCE="$(findmnt -no SOURCE / 2>/dev/null || true)"
ROOT_DEV="${ROOT_SOURCE%%[*}"
BOOT_DEV="$(findmnt -no SOURCE /boot 2>/dev/null || true)"
ROOT_FS="$(findmnt -no FSTYPE / 2>/dev/null || true)"
BOOT_FS="$(findmnt -no FSTYPE /boot 2>/dev/null || true)"
ROOT_OPTS="$(findmnt -no OPTIONS / 2>/dev/null || true)"

[[ "$ROOT_DEV" == "$EXPECTED_ROOT_DEV" ]] || fail "root is $ROOT_SOURCE, expected $EXPECTED_ROOT_DEV subvol=@"
[[ "$BOOT_DEV" == "$EXPECTED_BOOT_DEV" ]] || fail "/boot is $BOOT_DEV, expected $EXPECTED_BOOT_DEV"
[[ "$ROOT_FS" == "btrfs" ]] || fail "root is not btrfs"
[[ "$BOOT_FS" == "vfat" ]] || fail "/boot is not vfat"
[[ "$ROOT_OPTS" == *"subvol=/@"* || "$ROOT_OPTS" == *"subvol=@"* ]] || fail "root is not mounted on @ subvolume"

# Explicitly refuse to proceed if protected old-Arch partitions are the active target.
[[ "$ROOT_DEV" != "/dev/nvme1n1p2" ]] || fail "refusing to touch old Arch root"
[[ "$BOOT_DEV" != "/dev/nvme1n1p1" ]] || fail "refusing to touch old Arch EFI"

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV")"
[[ -n "$ROOT_UUID" ]] || fail "could not determine new root UUID"

echo "============================================================"
echo " NEW ARCH BOOTSTRAP"
echo "============================================================"
echo "root:  $ROOT_DEV UUID=$ROOT_UUID"
echo "boot:  $BOOT_DEV"
echo "old Arch p1+p2: untouched"
echo "migration p4: untouched"
echo "Windows NVMe: untouched"
echo

# Base identity / locale.
ln -sf /usr/share/zoneinfo/Asia/Dubai /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
printf 'KEYMAP=us\n' > /etc/vconsole.conf
printf '%s\n' "$HOST_NAME" > /etc/hostname
printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t%s.localdomain %s\n' "$HOST_NAME" "$HOST_NAME" > /etc/hosts

# Clean, practical laptop + Wayland foundation.
pacman -Syu --needed --noconfirm \
  networkmanager openssh sudo zsh git base-devel vim nano \
  nvidia-open nvidia-utils mesa vulkan-intel intel-media-driver \
  hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
  firefox kitty waybar rofi wl-clipboard \
  pipewire pipewire-pulse wireplumber pavucontrol alsa-utils sof-firmware \
  bluez bluez-utils brightnessctl power-profiles-daemon \
  polkit-gnome xdg-user-dirs xdg-utils \
  noto-fonts noto-fonts-emoji ttf-firacode-nerd

# User account. No secret is embedded in this script.
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd -m -G wheel,video -s /bin/zsh "$USER_NAME"
fi
install -d -m 0755 /etc/sudoers.d
printf '%s ALL=(ALL:ALL) ALL\n' "$USER_NAME" > "/etc/sudoers.d/10-$USER_NAME"
chmod 0440 "/etc/sudoers.d/10-$USER_NAME"

# Minimal bootstrap Hyprland config only; dream rice comes later.
install -d -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.config/hypr"
cat > "/home/$USER_NAME/.config/hypr/hyprland.conf" <<'HYPR'
monitor=,preferred,auto,1
$mod = SUPER
bind = $mod, RETURN, exec, kitty
bind = $mod, F, exec, firefox
bind = $mod, Q, killactive,
bind = $mod, M, exit,
exec-once = waybar
HYPR
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/hypr/hyprland.conf"

# Services for first boot.
systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable sshd.service
systemctl enable fstrim.timer
systemctl enable systemd-timesyncd.service
systemctl enable power-profiles-daemon.service

# Rebuild initramfs after graphics/firmware installation.
mkinitcpio -P

# Bootloader goes ONLY to the new 4 GiB EFI partition mounted at /boot.
bootctl --esp-path=/boot install
install -d -m 0755 /boot/loader/entries
cat > /boot/loader/loader.conf <<'LOADER'
default arch-new.conf
timeout 5
console-mode max
editor no
LOADER
cat > /boot/loader/entries/arch-new.conf <<EOF
title   Arch Linux (new)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rootflags=subvol=@ rw
EOF

# Sanity checks before handing control back.
[[ -s /boot/vmlinuz-linux ]] || fail "kernel missing from new EFI"
[[ -s /boot/initramfs-linux.img ]] || fail "initramfs missing from new EFI"
[[ -s /boot/intel-ucode.img ]] || fail "intel microcode missing from new EFI"
[[ -s /boot/EFI/systemd/systemd-bootx64.efi ]] || fail "systemd-boot EFI binary missing"

echo
echo "============================================================"
echo " ACCOUNT PASSWORD"
echo "============================================================"
echo "Set the password for $USER_NAME now."
passwd "$USER_NAME"
passwd -l root >/dev/null 2>&1 || true

touch /root/ARCH_BOOTSTRAP_COMPLETE

echo
echo "============================================================"
echo " BOOTSTRAP COMPLETE"
echo "============================================================"
echo "New root: $ROOT_DEV (Btrfs @)"
echo "New EFI:  $BOOT_DEV (systemd-boot)"
echo "Old Arch p1+p2 was not modified by this script."
echo "Next: exit chroot, unmount /mnt, reboot, choose Linux Boot Manager/new EFI."
echo "After TTY login as $USER_NAME, run: Hyprland"
echo "SUPER+F opens Firefox; SUPER+ENTER opens Kitty."
bootctl --esp-path=/boot status || true

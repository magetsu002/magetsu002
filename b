#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/dev/nvme1n1p3
EFI=/dev/nvme1n1p5
BACKUP=/dev/nvme1n1p4
MNT=/mnt
ROOT_UUID=ce979d1c-c145-4be0-9ce3-591b6fd0a3a1
EFI_UUID=30B5-B3B9
BACKUP_UUID=1411e6f3-209c-4e53-9860-cf920a7fce2b
USER_NAME=magetsu
HOST_NAME=predator

fail(){ echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run as root@archiso"
[[ -d /sys/firmware/efi/efivars ]] || fail "not booted in UEFI mode"
[[ -b "$ROOT" && -b "$EFI" && -b "$BACKUP" ]] || fail "expected nvme1n1 p3/p4/p5 not present in this live session"
[[ "$(blkid -s UUID -o value "$ROOT")" == "$ROOT_UUID" ]] || fail "p3 UUID mismatch"
[[ "$(blkid -s TYPE -o value "$ROOT")" == btrfs ]] || fail "p3 is not Btrfs"
[[ "$(blkid -s UUID -o value "$EFI")" == "$EFI_UUID" ]] || fail "p5 UUID mismatch"
[[ "$(blkid -s TYPE -o value "$EFI")" == vfat ]] || fail "p5 is not FAT"
[[ "$(blkid -s UUID -o value "$BACKUP")" == "$BACKUP_UUID" ]] || fail "p4 backup UUID mismatch"

echo "Targets locked:"
echo "  ROOT   $ROOT  UUID=$ROOT_UUID"
echo "  EFI    $EFI   UUID=$EFI_UUID"
echo "  BACKUP $BACKUP  VERIFIED/NOT MOUNTED"

echo "[1/6] Rebuilding known-good mounts"
mountpoint -q "$MNT" && umount -R "$MNT" || true
mkdir -p "$MNT"
mount -o subvol=@,compress=zstd,noatime "$ROOT" "$MNT"
mkdir -p "$MNT/home" "$MNT/.snapshots" "$MNT/var/log" "$MNT/boot"
mount -o subvol=@home,compress=zstd,noatime "$ROOT" "$MNT/home"
mount -o subvol=@snapshots,compress=zstd,noatime "$ROOT" "$MNT/.snapshots"
mount -o subvol=@var_log,compress=zstd,noatime "$ROOT" "$MNT/var/log"
mount "$EFI" "$MNT/boot"

findmnt -R -n -o SOURCE "$MNT" | grep -Fq "$BACKUP" && fail "backup unexpectedly mounted below /mnt"

echo "[2/6] Rebuilding fstab"
[[ -d "$MNT/etc" ]] || fail "new Arch install missing under /mnt"
genfstab -U "$MNT" > "$MNT/etc/fstab"

echo "[3/6] Configuring base system"
ln -sf /usr/share/zoneinfo/Asia/Dubai "$MNT/etc/localtime"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$MNT/etc/locale.gen"
printf 'LANG=en_US.UTF-8\n' > "$MNT/etc/locale.conf"
printf 'KEYMAP=us\n' > "$MNT/etc/vconsole.conf"
printf '%s\n' "$HOST_NAME" > "$MNT/etc/hostname"
printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t%s.localdomain %s\n' "$HOST_NAME" "$HOST_NAME" > "$MNT/etc/hosts"
arch-chroot "$MNT" locale-gen
arch-chroot "$MNT" hwclock --systohc

if ! arch-chroot "$MNT" id "$USER_NAME" >/dev/null 2>&1; then
  arch-chroot "$MNT" useradd -m -G wheel -s /bin/bash "$USER_NAME"
else
  arch-chroot "$MNT" usermod -aG wheel "$USER_NAME"
fi
install -d -m 0755 "$MNT/etc/sudoers.d"
printf '%s ALL=(ALL:ALL) ALL\n' "$USER_NAME" > "$MNT/etc/sudoers.d/10-$USER_NAME"
chmod 0440 "$MNT/etc/sudoers.d/10-$USER_NAME"
arch-chroot "$MNT" visudo -cf /etc/sudoers >/dev/null
arch-chroot "$MNT" systemctl enable NetworkManager.service >/dev/null

STATE="$(arch-chroot "$MNT" passwd -S "$USER_NAME" | awk '{print $2}')"
if [[ "$STATE" != P ]]; then
  echo
  echo "Set password for $USER_NAME:"
  arch-chroot "$MNT" passwd "$USER_NAME"
fi
arch-chroot "$MNT" passwd -l root >/dev/null 2>&1 || true

echo "[4/6] Rebuilding initramfs"
arch-chroot "$MNT" mkinitcpio -P
[[ -s "$MNT/boot/vmlinuz-linux" ]] || fail "vmlinuz-linux missing"
[[ -s "$MNT/boot/intel-ucode.img" ]] || fail "intel-ucode.img missing"
[[ -s "$MNT/boot/initramfs-linux.img" ]] || fail "initramfs-linux.img missing"

echo "[5/6] Creating direct EFISTUB one-shot boot"
BEFORE="$(efibootmgr | sed -n 's/^BootOrder: //p')"
[[ -n "$BEFORE" ]] || fail "cannot read BootOrder"
LABEL="Arch New EFISTUB $(date +%H%M%S)"
efibootmgr --create --disk /dev/nvme1n1 --part 5 --label "$LABEL" --loader '\vmlinuz-linux' --unicode "root=UUID=$ROOT_UUID rw rootflags=subvol=@ initrd=\\intel-ucode.img initrd=\\initramfs-linux.img"
efibootmgr -o "$BEFORE"
LINE="$(efibootmgr | grep -F "$LABEL" | head -n1)"
BOOTNUM="$(sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' <<<"$LINE")"
[[ -n "$BOOTNUM" ]] || fail "could not identify new EFISTUB entry"
efibootmgr -n "$BOOTNUM"

AFTER="$(efibootmgr | sed -n 's/^BootOrder: //p')"
NEXT="$(efibootmgr | sed -n 's/^BootNext: //p')"
[[ "$AFTER" == "$BEFORE" ]] || fail "BootOrder was not preserved"
[[ "${NEXT^^}" == "${BOOTNUM^^}" ]] || fail "BootNext was not set"

echo "[6/6] Final verification"
findmnt -R "$MNT"
touch "$MNT/root/FIRST_BOOT_READY"
sync

echo
echo "============================================================"
echo " FIRST BOOT READY"
echo "============================================================"
echo "BootOrder preserved: $AFTER"
echo "BootNext: $NEXT"
echo "New Arch will boot directly via EFISTUB from p5."
echo "Old Arch and p4 backup were not mounted or modified."
echo "No automatic reboot performed."

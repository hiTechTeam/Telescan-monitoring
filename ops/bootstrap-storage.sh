#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /dev/disk/by-id/<data-disk>" >&2
  exit 2
fi

device="$1"
mount_point=/var/lib/telescan-monitoring

if [[ ! -b "$device" ]]; then
  echo "Block device does not exist: $device" >&2
  exit 1
fi

size_bytes="$(blockdev --getsize64 "$device")"
if (( size_bytes < 60 * 1024 * 1024 * 1024 )); then
  echo "Refusing to format an unexpectedly small device: $device" >&2
  exit 1
fi

if findmnt --source "$device" >/dev/null 2>&1; then
  echo "Refusing to format a mounted device: $device" >&2
  exit 1
fi

if [[ -n "$(blkid -o value -s TYPE "$device" 2>/dev/null || true)" ]]; then
  echo "Refusing to format a device that already has a filesystem: $device" >&2
  exit 1
fi

if [[ -n "$(wipefs --no-act --output TYPE "$device" 2>/dev/null | tail -n +2)" ]]; then
  echo "Refusing to format a device with existing signatures: $device" >&2
  exit 1
fi

mkfs.ext4 -F -L telescan-monitoring "$device"
install -d -m 0755 "$mount_point"

uuid="$(blkid -s UUID -o value "$device")"
if ! grep -qF "UUID=$uuid" /etc/fstab; then
  printf 'UUID=%s %s ext4 defaults,nofail,nodev,nosuid 0 2\n' \
    "$uuid" "$mount_point" >>/etc/fstab
fi

mount "$mount_point"
findmnt --verify --verbose
findmnt "$mount_point"

#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 || "$1" != --apply || "$2" != --confirm || \
      "$3" != APPLY_MONITORING_RELEASE_RECOVERY_UNIT ]]; then
  echo "Usage: $0 --apply --confirm APPLY_MONITORING_RELEASE_RECOVERY_UNIT" >&2
  exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_unit="$root/systemd/telescan-monitoring-release-recovery.service"
destination=/etc/systemd/system/telescan-monitoring-release-recovery.service
source_path_unit="$root/systemd/telescan-monitoring-release-recovery.path"
path_destination=/etc/systemd/system/telescan-monitoring-release-recovery.path
backup="$(mktemp)"
path_backup="$(mktemp)"
had_previous=false
had_previous_path=false
if sudo test -f "$destination"; then
  sudo cp "$destination" "$backup"
  had_previous=true
fi
if sudo test -f "$path_destination"; then
  sudo cp "$path_destination" "$path_backup"
  had_previous_path=true
fi
sudo test ! -e /home/ubuntu/telescan-monitoring/.release-state/intent.json
complete=false
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$complete" != true ]]; then
    if [[ "$had_previous" == true ]]; then
      sudo install -m 0644 "$backup" "$destination"
    else
      sudo rm -f -- "$destination"
    fi
    if [[ "$had_previous_path" == true ]]; then
      sudo install -m 0644 "$path_backup" "$path_destination"
    else
      sudo rm -f -- "$path_destination"
    fi
    sudo systemctl daemon-reload || true
  fi
  rm -f -- "$backup" "$path_backup"
  exit "$status"
}
trap cleanup EXIT
sudo install -m 0644 "$source_unit" "$destination"
sudo install -m 0644 "$source_path_unit" "$path_destination"
sudo systemctl daemon-reload
sudo systemctl reset-failed \
  telescan-monitoring-release-recovery.service \
  telescan-monitoring-release-recovery.path
sudo systemctl enable telescan-monitoring-release-recovery.service
sudo systemctl enable --now telescan-monitoring-release-recovery.path
sudo systemctl is-enabled --quiet telescan-monitoring-release-recovery.service
sudo systemctl is-enabled --quiet telescan-monitoring-release-recovery.path
sudo systemctl is-active --quiet telescan-monitoring-release-recovery.path
complete=true
echo "Monitoring durable release recovery unit installed; no recovery was executed."

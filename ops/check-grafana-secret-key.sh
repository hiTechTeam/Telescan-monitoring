#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data_root="${MONITORING_DATA_ROOT:-}"
if [[ -z "$data_root" && -r "$repo_root/.env" ]]; then
  while IFS='=' read -r key value; do
    if [[ "$key" == MONITORING_DATA_ROOT ]]; then
      data_root="${value%$'\r'}"
      break
    fi
  done <"$repo_root/.env"
fi
data_root="${data_root:-/var/lib/telescan-monitoring}"
key_file="$data_root/secrets/grafana_secret_key"
marker_file="$data_root/secrets/grafana_secret_key_ready"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi
if [[ ! "$data_root" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Invalid MONITORING_DATA_ROOT." >&2
  exit 1
fi
if [[ ! -f "$key_file" || ! -s "$key_file" ]]; then
  echo "Grafana secret key is absent." >&2
  exit 1
fi
if [[ "$(stat -c '%a:%u:%g' "$key_file")" != 400:472:472 ]]; then
  echo "Grafana secret key must have mode 0400 and owner 472:472." >&2
  exit 1
fi

IFS= read -r key <"$key_file"
if [[ ! "$key" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Grafana secret key must contain exactly 64 hexadecimal characters." >&2
  exit 1
fi
unset key

if [[ ! -f "$marker_file" || "$(stat -c '%a:%u:%g' "$marker_file")" != 444:0:0 ]]; then
  echo "Grafana migration marker is absent or has unsafe ownership/mode." >&2
  exit 1
fi
if ! grep -qx 'status=ready' "$marker_file"; then
  echo "Grafana migration marker is not ready." >&2
  exit 1
fi

echo "Grafana secret-key file and migration guard passed without exposing key material."

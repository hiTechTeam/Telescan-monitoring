#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root" >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 monitoring|moscow|eu" >&2
  exit 2
fi

role="$1"
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
template="$repo_dir/network/config/$role.conf.template"
private_key_file=/etc/wireguard/wg-monitor.key

if [[ ! -r "$template" ]]; then
  echo "Unknown role or missing template: $role" >&2
  exit 1
fi

if [[ ! -s "$private_key_file" ]]; then
  echo "Generate the host key first with network/ops/generate-key.sh" >&2
  exit 1
fi

if grep -q '__[A-Z_]*__' "$template"; then
  echo "Template still contains unresolved placeholders: $template" >&2
  exit 1
fi

private_key="$(<"$private_key_file")"
tmp_config="$(mktemp /etc/wireguard/.wg-monitor.conf.XXXXXX)"
trap 'rm -f "$tmp_config"' EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == 'PrivateKey = PRIVATE_KEY_FROM_HOST' ]]; then
    printf 'PrivateKey = %s\n' "$private_key"
  else
    printf '%s\n' "$line"
  fi
done <"$template" >"$tmp_config"

install -m 0600 "$tmp_config" /etc/wireguard/wg-monitor.conf
systemctl enable wg-quick@wg-monitor

if systemctl is-active --quiet wg-quick@wg-monitor; then
  wg syncconf wg-monitor <(wg-quick strip wg-monitor)
else
  systemctl start wg-quick@wg-monitor
fi

wg show wg-monitor
ip -brief address show wg-monitor

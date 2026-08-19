#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root" >&2
  exit 1
fi

command -v wg >/dev/null 2>&1 || {
  echo "wireguard-tools is required" >&2
  exit 1
}

install -d -m 0700 /etc/wireguard
private_key=/etc/wireguard/wg-monitor.key
public_key=/etc/wireguard/wg-monitor.pub

if [[ ! -s "$private_key" ]]; then
  tmp_private="$(mktemp /etc/wireguard/.wg-monitor.key.XXXXXX)"
  trap 'rm -f "$tmp_private"' EXIT
  umask 077
  wg genkey >"$tmp_private"
  install -m 0600 "$tmp_private" "$private_key"
  rm -f "$tmp_private"
  trap - EXIT
fi

tmp_public="$(mktemp /etc/wireguard/.wg-monitor.pub.XXXXXX)"
trap 'rm -f "$tmp_public"' EXIT
wg pubkey <"$private_key" >"$tmp_public"
install -m 0644 "$tmp_public" "$public_key"

cat "$public_key"

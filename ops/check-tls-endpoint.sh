#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 HOSTNAME [PORT] [CONNECT_ADDRESS]" >&2
  exit 2
fi

hostname="$1"
port="${2:-443}"
connect_address="${3:-$hostname}"

if [[ ! "$hostname" =~ ^[A-Za-z0-9.-]+$ || ! "$port" =~ ^[0-9]{1,5}$ || \
      ! "$connect_address" =~ ^[A-Za-z0-9.:-]+$ ]]; then
  echo "Invalid TLS endpoint." >&2
  exit 2
fi

output_file="$(mktemp)"
client_pid=""
watchdog_pid=""
cleanup() {
  [[ -z "$client_pid" ]] || kill "$client_pid" >/dev/null 2>&1 || true
  [[ -z "$watchdog_pid" ]] || kill "$watchdog_pid" >/dev/null 2>&1 || true
  rm -f -- "$output_file"
}
trap cleanup EXIT

openssl s_client \
  -connect "$connect_address:$port" \
  -servername "$hostname" \
  -verify_hostname "$hostname" \
  -verify_return_error \
  </dev/null >"$output_file" 2>/dev/null &
client_pid=$!
(sleep 15; kill "$client_pid" >/dev/null 2>&1 || true) &
watchdog_pid=$!

client_status=0
wait "$client_pid" || client_status=$?
client_pid=""
kill "$watchdog_pid" >/dev/null 2>&1 || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
if [[ "$client_status" -ne 0 ]]; then
  echo "TLS chain or hostname verification failed for $hostname." >&2
  exit 1
fi

certificate="$(<"$output_file")"

openssl x509 -noout \
  -subject -issuer -dates -serial -fingerprint -sha256 \
  <<<"$certificate"
echo "hostname_verification=passed host=$hostname"

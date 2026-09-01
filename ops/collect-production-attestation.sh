#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: sudo $0 --read-only --confirm COLLECT_TELESCAN_PRODUCTION_ATTESTATION --role monitoring|moscow|eu --expected-api-ip IPv4 --expected-main-ip IPv4 [--expected-image-id SELECTOR=sha256:ID]..." >&2
  exit 2
}

[[ $# -ge 5 ]] || usage
[[ "$1" == --read-only && "$2" == --confirm && \
   "$3" == COLLECT_TELESCAN_PRODUCTION_ATTESTATION && "$4" == --role ]] || usage
role="$5"
shift 5
[[ "$role" =~ ^(monitoring|moscow|eu)$ ]] || usage

expected_api_ip=""
expected_main_ip=""
expected_image_ids=()
while (( $# > 0 )); do
  case "$1" in
    --expected-api-ip)
      (( $# >= 2 )) || usage
      expected_api_ip="$2"
      shift 2
      ;;
    --expected-main-ip)
      (( $# >= 2 )) || usage
      expected_main_ip="$2"
      shift 2
      ;;
    --expected-image-id)
      (( $# >= 2 )) || usage
      expected_image_ids+=("$2")
      shift 2
      ;;
    *) usage ;;
  esac
done

if [[ -z "$expected_api_ip" || -z "$expected_main_ip" ]]; then
  echo "Both exact DNS A records are mandatory attestation inputs." >&2
  exit 2
fi
for address in "$expected_api_ip" "$expected_main_ip"; do
  if [[ ! "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Expected DNS values must be IPv4 addresses." >&2
    exit 2
  fi
done
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root so firewall, WireGuard, Docker, and effective SSH state are complete." >&2
  exit 1
fi

failures=()
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

section() {
  printf '\n## %s\n' "$1"
}

required() {
  local description="$1"
  shift
  echo "### $description"
  if ! "$@"; then
    echo "FAILED TO COLLECT: $description" >&2
    failures+=("required evidence unavailable: $description")
  fi
}

tls_evidence() {
  local host="$1"
  local evidence
  if ! evidence="$("$script_dir/check-tls-endpoint.sh" "$host")"; then
    failures+=("TLS chain or hostname verification failed for $host")
    return
  fi
  printf '%s\n' "$evidence"
}

section "attestation metadata"
printf 'schema=telescan-production-attestation/v1\n'
printf 'collected_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'role=%s\n' "$role"
printf 'hostname=%s\n' "$(hostname --fqdn 2>/dev/null || hostname)"
printf 'kernel=%s\n' "$(uname -srmo)"

section "network addresses"
if address_output="$(ip -brief -4 address show 2>&1)"; then
  echo "### IPv4 addresses"
  printf '%s\n' "$address_output"
else
  failures+=("required evidence unavailable: IPv4 addresses")
fi

section "exact DNS, role listeners, containers, and image identities"
inventory_command=(
  python3 "$script_dir/check-attestation-inventory.py"
  --role "$role"
  --expected-api-ip "$expected_api_ip"
  --expected-main-ip "$expected_main_ip"
)
if (( ${#expected_image_ids[@]} > 0 )); then
  for expected_image_id in "${expected_image_ids[@]}"; do
    inventory_command+=(--expected-image-id "$expected_image_id")
  done
fi
required "frozen role inventory" "${inventory_command[@]}"

section "firewall"
if command -v ufw >/dev/null 2>&1; then
  ufw_output="$(ufw status verbose 2>&1 || true)"
  echo "### UFW effective policy"
  printf '%s\n' "${ufw_output:-<none>}"
  if ! grep -q '^Status: active$' <<<"$ufw_output"; then
    failures+=("UFW is installed but not active")
  fi
fi
if command -v nft >/dev/null 2>&1; then
  required "nftables effective ruleset" nft list ruleset
elif command -v iptables-save >/dev/null 2>&1; then
  required "iptables effective ruleset" iptables-save
else
  failures+=("no supported firewall inspection command is installed")
fi

section "WireGuard public state"
if command -v wg >/dev/null 2>&1; then
  wg_interfaces="$(wg show interfaces 2>/dev/null || true)"
  echo "### WireGuard interfaces"
  printf '%s\n' "${wg_interfaces:-<none>}"
  for interface in $wg_interfaces; do
    echo "### interface=$interface"
    wg show "$interface" public-key
    wg show "$interface" listen-port
    wg show "$interface" peers
    wg show "$interface" endpoints
    wg show "$interface" allowed-ips
    wg show "$interface" latest-handshakes
  done
  if [[ "$role" == monitoring ]]; then
    required_interfaces=(wg-monitor)
  else
    required_interfaces=(wg0 wg-monitor)
  fi
  for interface in "${required_interfaces[@]}"; do
    if ! tr ' ' '\n' <<<"$wg_interfaces" | grep -qxF "$interface"; then
      failures+=("required WireGuard interface $interface is absent")
    fi
  done
else
  failures+=("WireGuard tooling is unavailable")
fi

section "public TLS"
tls_evidence api.tgtelescan.ru
tls_evidence tgtelescan.ru

section "effective SSH policy"
sshd_bin="$(command -v sshd || true)"
if [[ -n "$sshd_bin" ]]; then
  sshd_policy="$($sshd_bin -T 2>&1 || true)"
  grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|x11forwarding|authenticationmethods|allowusers|allowgroups|maxauthtries|logingracetime) ' \
    <<<"$sshd_policy" || true
  for setting in \
    'permitrootlogin no' \
    'passwordauthentication no' \
    'kbdinteractiveauthentication no' \
    'pubkeyauthentication yes' \
    'x11forwarding no'; do
    if ! grep -qxF "$setting" <<<"$sshd_policy"; then
      failures+=("effective SSH policy is missing: $setting")
    fi
  done
else
  failures+=("sshd is unavailable")
fi

section "storage and scheduled controls"
required "mounted filesystems" findmnt --real --output TARGET,SOURCE,FSTYPE,OPTIONS
required "filesystem capacity" df -hT
required "filesystem inode capacity" df -hi
if [[ "$role" == monitoring ]]; then
  required "canonical monitoring data mount" \
    findmnt --mountpoint /var/lib/telescan-monitoring --output TARGET,SOURCE,FSTYPE,OPTIONS
fi

timer_output="$(systemctl list-timers --all --no-pager --no-legend 'telescan-*' 2>&1 || true)"
echo "### Telescan timers"
printf '%s\n' "${timer_output:-<none>}"
case "$role" in
  monitoring)
    required_timers=(telescan-monitoring-state.timer)
    ;;
  moscow)
    required_timers=(
      telescan-certbot-renew.timer
      telescan-mongodb-backup.timer
      telescan-monitoring-state.timer
    )
    ;;
  eu)
    required_timers=(telescan-relay-certbot-renew.timer telescan-monitoring-state.timer)
    ;;
esac
for timer in "${required_timers[@]}"; do
  if ! systemctl is-enabled --quiet "$timer" || ! systemctl is-active --quiet "$timer"; then
    failures+=("required timer is not enabled and active: $timer")
  fi
done

section "result"
if (( ${#failures[@]} > 0 )); then
  printf 'FAIL: %s\n' "${failures[@]}" >&2
  echo "attestation=failed"
  exit 1
fi
echo "attestation=passed"

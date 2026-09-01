#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 || "$1" != --apply || "$2" != --confirm || \
      "$3" != INSTALL_CENTRAL_STATE_COLLECTOR ]]; then
  echo "Usage: sudo $0 --apply --confirm INSTALL_CENTRAL_STATE_COLLECTOR" >&2
  exit 2
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data_root="${MONITORING_DATA_ROOT:-}"
compose_profiles="${COMPOSE_PROFILES:-}"
if [[ -r "$repo_root/.env" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      MONITORING_DATA_ROOT)
        [[ -z "$data_root" ]] && data_root="${value%$'\r'}"
        ;;
      COMPOSE_PROFILES)
        [[ -z "$compose_profiles" ]] && compose_profiles="${value%$'\r'}"
        ;;
    esac
  done <"$repo_root/.env"
fi
data_root="${data_root:-/var/lib/telescan-monitoring}"

if [[ "$data_root" != /var/lib/telescan-monitoring ]] || ! mountpoint -q "$data_root"; then
  echo "The collector and alerts require the data disk at /var/lib/telescan-monitoring." >&2
  exit 1
fi

expected_containers='telescan_grafana telescan_prometheus telescan_loki telescan_alloy'
if [[ ",$compose_profiles," == *",restricted-ingest,"* ]]; then
  expected_containers+=' telescan_restricted_ingest'
fi

config_file=/etc/default/telescan-monitoring-agent
tmp_config="$(mktemp)"
trap 'rm -f -- "$tmp_config"' EXIT
{
  echo 'TELESCAN_HOST=monitoring'
  printf 'EXPECTED_CONTAINERS=%q\n' "$expected_containers"
  echo 'MONITORED_TIMERS='
  echo 'MONITORED_SERVICES='
  echo 'MONITORED_WIREGUARD_INTERFACES=wg-monitor'
  printf 'TELESCAN_MONITORING_STATE_OUTPUT_DIR=%q\n' "$data_root/alloy/textfile"
} >"$tmp_config"

install -o root -g root -m 0644 "$tmp_config" "$config_file"
install -o root -g root -m 0755 \
  "$repo_root/agent/ops/collect-host-state.sh" \
  /usr/local/sbin/telescan-monitoring-state
install -o root -g root -m 0644 \
  "$repo_root/systemd/telescan-monitoring-central-state.service" \
  /etc/systemd/system/telescan-monitoring-state.service
install -o root -g root -m 0644 \
  "$repo_root/agent/systemd/telescan-monitoring-state.timer" \
  /etc/systemd/system/telescan-monitoring-state.timer

systemctl daemon-reload
systemctl enable --now telescan-monitoring-state.timer
systemctl start telescan-monitoring-state.service
systemctl is-active --quiet telescan-monitoring-state.timer
test -s "$data_root/alloy/textfile/host-state.prom"
grep -q '^telescan_monitoring_state_last_success_timestamp_seconds [0-9][0-9]*$' \
  "$data_root/alloy/textfile/host-state.prom"

echo "Central state collector installed and freshness output verified."

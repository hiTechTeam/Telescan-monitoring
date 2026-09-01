#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data_root="${MONITORING_DATA_ROOT:-}"
require_state_freshness_metrics="${REQUIRE_STATE_FRESHNESS_METRICS:-}"
if [[ -r "$repo_root/.env" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      MONITORING_DATA_ROOT)
        [[ -z "$data_root" ]] && data_root="${value%$'\r'}"
        ;;
      REQUIRE_STATE_FRESHNESS_METRICS)
        [[ -z "$require_state_freshness_metrics" ]] && \
          require_state_freshness_metrics="${value%$'\r'}"
        ;;
    esac
  done <"$repo_root/.env"
fi
data_root="${data_root:-/var/lib/telescan-monitoring}"
require_state_freshness_metrics="${require_state_freshness_metrics:-false}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root" >&2
  exit 1
fi
if [[ ! "$data_root" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Invalid MONITORING_DATA_ROOT." >&2
  exit 1
fi
if [[ "$require_state_freshness_metrics" != true && \
      "$require_state_freshness_metrics" != false ]]; then
  echo "REQUIRE_STATE_FRESHNESS_METRICS must be true or false." >&2
  exit 1
fi

if ! mountpoint -q "$data_root"; then
  echo "Monitoring data disk is not mounted at $data_root" >&2
  exit 1
fi

install -d -m 0755 \
  "$data_root/grafana" \
  "$data_root/prometheus" \
  "$data_root/loki" \
  "$data_root/alloy" \
  "$data_root/alloy/data" \
  "$data_root/alloy/textfile" \
  "$data_root/secrets"

chown 472:472 "$data_root/grafana"
chown 65534:65534 "$data_root/prometheus"
chown 10001:10001 "$data_root/loki"
chown -R 0:0 "$data_root/alloy"
chmod 0700 "$data_root/secrets"

freshness_enforcement=0
[[ "$require_state_freshness_metrics" == true ]] && freshness_enforcement=1
control_metric_tmp="$(mktemp "$data_root/alloy/textfile/.monitoring-controls.XXXXXX")"
trap 'rm -f -- "$control_metric_tmp"' EXIT
{
  echo '# HELP telescan_state_freshness_enforcement Whether missing collector freshness series are alertable.'
  echo '# TYPE telescan_state_freshness_enforcement gauge'
  printf 'telescan_state_freshness_enforcement %s\n' "$freshness_enforcement"
} >"$control_metric_tmp"
chmod 0644 "$control_metric_tmp"
mv -f -- "$control_metric_tmp" "$data_root/alloy/textfile/monitoring-controls.prom"
trap - EXIT

grafana_password="$data_root/secrets/grafana_admin_password"
if [[ ! -s "$grafana_password" ]]; then
  openssl rand -out "$grafana_password" -base64 36
fi
chown 472:472 "$grafana_password"
chmod 0400 "$grafana_password"

systemctl daemon-reload
findmnt "$data_root"

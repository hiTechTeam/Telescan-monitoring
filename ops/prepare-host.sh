#!/usr/bin/env bash
set -Eeuo pipefail

data_root="${MONITORING_DATA_ROOT:-/var/lib/telescan-monitoring}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root" >&2
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
  "$data_root/secrets"

chown 472:472 "$data_root/grafana"
chown 65534:65534 "$data_root/prometheus"
chown 10001:10001 "$data_root/loki"
chown -R 0:0 "$data_root/alloy"
chmod 0700 "$data_root/secrets"

grafana_password="$data_root/secrets/grafana_admin_password"
if [[ ! -s "$grafana_password" ]]; then
  openssl rand -out "$grafana_password" -base64 36
fi
chown 472:472 "$grafana_password"
chmod 0400 "$grafana_password"

systemctl daemon-reload
findmnt "$data_root"

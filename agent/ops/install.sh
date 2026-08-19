#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root" >&2
  exit 1
fi

if [[ $# -lt 5 || $# -gt 6 ]]; then
  echo "Usage: $0 HOST EXPECTED_CONTAINERS MONITORED_TIMERS MONITORED_SERVICES MONITORED_WIREGUARD_INTERFACES [MEMORY_LIMIT]" >&2
  exit 2
fi

host="$1"
expected_containers="$2"
monitored_timers="$3"
monitored_services="$4"
monitored_wireguard_interfaces="$5"
memory_limit="${6:-224m}"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
data_root=/var/lib/telescan-monitoring-agent

if [[ ! "$host" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
  echo "Invalid host label: $host" >&2
  exit 2
fi

if [[ ! "$memory_limit" =~ ^[0-9]+[mMgG]$ ]]; then
  echo "Invalid memory limit: $memory_limit" >&2
  exit 2
fi

install -d -m 0755 "$data_root/alloy/data" "$data_root/textfile"
chown -R 0:0 "$data_root"

config_file=/etc/default/telescan-monitoring-agent
tmp_config="$(mktemp)"
trap 'rm -f "$tmp_config"' EXIT
{
  printf 'TELESCAN_HOST=%q\n' "$host"
  printf 'EXPECTED_CONTAINERS=%q\n' "$expected_containers"
  printf 'MONITORED_TIMERS=%q\n' "$monitored_timers"
  printf 'MONITORED_SERVICES=%q\n' "$monitored_services"
  printf 'MONITORED_WIREGUARD_INTERFACES=%q\n' "$monitored_wireguard_interfaces"
} >"$tmp_config"
install -m 0644 "$tmp_config" "$config_file"

tmp_environment="$(mktemp)"
{
  printf 'TELESCAN_HOST=%s\n' "$host"
  printf 'PROMETHEUS_REMOTE_WRITE_URL=http://10.78.0.1:9090/api/v1/write\n'
  printf 'LOKI_WRITE_URL=http://10.78.0.1:3100/loki/api/v1/push\n'
  printf 'ALLOY_MEMORY_LIMIT=%s\n' "$memory_limit"
  printf 'ALLOY_CPU_LIMIT=0.35\n'
} >"$tmp_environment"
install -m 0600 "$tmp_environment" "$repo_dir/.env"
rm -f "$tmp_environment"

install -m 0755 "$repo_dir/ops/collect-host-state.sh" /usr/local/sbin/telescan-monitoring-state
install -m 0644 "$repo_dir/systemd/telescan-monitoring-state.service" /etc/systemd/system/telescan-monitoring-state.service
install -m 0644 "$repo_dir/systemd/telescan-monitoring-state.timer" /etc/systemd/system/telescan-monitoring-state.timer

systemctl daemon-reload
systemctl enable --now telescan-monitoring-state.timer
systemctl start telescan-monitoring-state.service

cd "$repo_dir"
docker compose config --quiet
docker compose pull
docker compose up -d --force-recreate --remove-orphans

deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
  if [[ "$(docker inspect --format '{{.State.Status}}' telescan_alloy_agent 2>/dev/null || true)" == running ]]; then
    sleep 5
    if ! docker logs --since=15s telescan_alloy_agent 2>&1 | grep -qE 'level=error|Error:'; then
      docker compose ps
      systemctl --no-pager --full status telescan-monitoring-state.timer
      exit 0
    fi
  fi
  sleep 5
done

docker compose ps
docker compose logs --tail=100
exit 1

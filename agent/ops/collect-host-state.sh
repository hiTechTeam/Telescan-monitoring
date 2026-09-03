#!/usr/bin/env bash
set -Eeuo pipefail

config_file="${TELESCAN_MONITORING_STATE_CONFIG_FILE:-/etc/default/telescan-monitoring-agent}"
output_dir=/var/lib/telescan-monitoring-agent/textfile

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root" >&2
  exit 1
fi

if [[ ! "$config_file" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Invalid TELESCAN_MONITORING_STATE_CONFIG_FILE." >&2
  exit 1
fi

if [[ ! -r "$config_file" ]]; then
  echo "Missing $config_file" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$config_file"
: "${TELESCAN_HOST:?TELESCAN_HOST is required}"
output_dir="${TELESCAN_MONITORING_STATE_OUTPUT_DIR:-$output_dir}"
if [[ ! "$output_dir" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Invalid TELESCAN_MONITORING_STATE_OUTPUT_DIR." >&2
  exit 1
fi

install -d -m 0755 "$output_dir"
tmp_file="$(mktemp "$output_dir/.host-state.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

escape_label() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

declare -A expected=()
declare -A containers=()

for container in ${EXPECTED_CONTAINERS:-}; do
  expected["$container"]=1
  containers["$container"]=1
done

while IFS= read -r container; do
  [[ -n "$container" ]] && containers["$container"]=1
done < <(docker ps -a --format '{{.Names}}')

{
  printf '# HELP telescan_monitoring_state_last_success_timestamp_seconds Last successful host-state collection as Unix seconds.\n'
  printf '# TYPE telescan_monitoring_state_last_success_timestamp_seconds gauge\n'
  printf 'telescan_monitoring_state_last_success_timestamp_seconds %s\n' "$(date +%s)"

  printf '# HELP telescan_container_expected Whether the container is part of the expected production set.\n'
  printf '# TYPE telescan_container_expected gauge\n'
  printf '# HELP telescan_container_running Whether the container is currently running.\n'
  printf '# TYPE telescan_container_running gauge\n'
  printf '# HELP telescan_container_healthcheck Whether the container defines a Docker healthcheck.\n'
  printf '# TYPE telescan_container_healthcheck gauge\n'
  printf '# HELP telescan_container_healthy Whether the Docker healthcheck currently reports healthy.\n'
  printf '# TYPE telescan_container_healthy gauge\n'
  printf '# HELP telescan_container_restarts_total Docker restart count for the current container lifecycle.\n'
  printf '# TYPE telescan_container_restarts_total counter\n'
  printf '# HELP telescan_container_state_info Current Docker state and health labels.\n'
  printf '# TYPE telescan_container_state_info gauge\n'

  for container in "${!containers[@]}"; do
    expected_value="${expected[$container]:-0}"
    if inspect="$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{index .Config.Labels "com.docker.compose.service"}}' "$container" 2>/dev/null)"; then
      IFS='|' read -r state health restarts service <<<"$inspect"
      [[ "$service" == '<no value>' ]] && service=''
    else
      state=missing
      health=missing
      restarts=0
      service=''
    fi

    running=0
    healthcheck=0
    healthy=0
    [[ "$state" == running ]] && running=1
    if [[ "$health" != none && "$health" != missing ]]; then
      healthcheck=1
      [[ "$health" == healthy ]] && healthy=1
    fi

    container_label="$(escape_label "$container")"
    service_label="$(escape_label "$service")"
    state_label="$(escape_label "$state")"
    health_label="$(escape_label "$health")"
    labels="container=\"$container_label\",service=\"$service_label\""

    printf 'telescan_container_expected{%s} %s\n' "$labels" "$expected_value"
    printf 'telescan_container_running{%s} %s\n' "$labels" "$running"
    printf 'telescan_container_healthcheck{%s} %s\n' "$labels" "$healthcheck"
    printf 'telescan_container_healthy{%s} %s\n' "$labels" "$healthy"
    printf 'telescan_container_restarts_total{%s} %s\n' "$labels" "$restarts"
    printf 'telescan_container_state_info{%s,state=\"%s\",health=\"%s\"} 1\n' \
      "$labels" "$state_label" "$health_label"
  done

  printf '# HELP telescan_systemd_timer_active Whether a monitored systemd timer is active.\n'
  printf '# TYPE telescan_systemd_timer_active gauge\n'
  printf '# HELP telescan_systemd_timer_last_trigger_timestamp_seconds Last timer trigger time as Unix seconds.\n'
  printf '# TYPE telescan_systemd_timer_last_trigger_timestamp_seconds gauge\n'
  for unit in ${MONITORED_TIMERS:-}; do
    value=0
    systemctl is-active --quiet "$unit" && value=1
    timestamp="$(systemctl show "$unit" --property=LastTriggerUSec --value 2>/dev/null || true)"
    epoch=0
    if [[ -n "$timestamp" && "$timestamp" != n/a ]]; then
      epoch="$(date --date="$timestamp" +%s 2>/dev/null || printf '0')"
    fi
    labels="unit=\"$(escape_label "$unit")\""
    printf 'telescan_systemd_timer_active{%s} %s\n' "$labels" "$value"
    printf 'telescan_systemd_timer_last_trigger_timestamp_seconds{%s} %s\n' \
      "$labels" "$epoch"
  done

  printf '# HELP telescan_systemd_service_success Whether the last monitored service result was success.\n'
  printf '# TYPE telescan_systemd_service_success gauge\n'
  printf '# HELP telescan_systemd_service_last_exit_timestamp_seconds Last service exit time as Unix seconds.\n'
  printf '# TYPE telescan_systemd_service_last_exit_timestamp_seconds gauge\n'
  for unit in ${MONITORED_SERVICES:-}; do
    result="$(systemctl show "$unit" --property=Result --value 2>/dev/null || true)"
    timestamp="$(systemctl show "$unit" --property=ExecMainExitTimestamp --value 2>/dev/null || true)"
    success=0
    [[ "$result" == success ]] && success=1
    epoch=0
    if [[ -n "$timestamp" && "$timestamp" != n/a ]]; then
      epoch="$(date --date="$timestamp" +%s 2>/dev/null || printf '0')"
    fi
    labels="unit=\"$(escape_label "$unit")\""
    printf 'telescan_systemd_service_success{%s} %s\n' "$labels" "$success"
    printf 'telescan_systemd_service_last_exit_timestamp_seconds{%s} %s\n' "$labels" "$epoch"
  done

  printf '# HELP telescan_wireguard_latest_handshake_seconds Latest peer handshake as Unix seconds.\n'
  printf '# TYPE telescan_wireguard_latest_handshake_seconds gauge\n'
  for interface in ${MONITORED_WIREGUARD_INTERFACES:-}; do
    latest="$(wg show "$interface" latest-handshakes 2>/dev/null | awk 'BEGIN { max=0 } $2 > max { max=$2 } END { print max }')"
    printf 'telescan_wireguard_latest_handshake_seconds{interface="%s"} %s\n' \
      "$(escape_label "$interface")" "${latest:-0}"
  done
} >"$tmp_file"

chmod 0644 "$tmp_file"
mv -f "$tmp_file" "$output_dir/host-state.prom"
trap - EXIT

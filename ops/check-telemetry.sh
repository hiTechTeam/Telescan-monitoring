#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

ingest_bind_address="${INGEST_BIND_ADDRESS:-}"
if [[ -z "$ingest_bind_address" && -r .env ]]; then
  while IFS='=' read -r key value; do
    if [[ "$key" == INGEST_BIND_ADDRESS ]]; then
      ingest_bind_address="${value%$'\r'}"
      break
    fi
  done <.env
fi
ingest_bind_address="${ingest_bind_address:-127.0.0.1}"

if [[ ! "$ingest_bind_address" =~ ^[0-9A-Fa-f:.]+$ ]]; then
  echo "Invalid INGEST_BIND_ADDRESS: $ingest_bind_address" >&2
  exit 1
fi

PROMETHEUS_URL="http://$ingest_bind_address:9090" \
LOKI_URL="http://$ingest_bind_address:3100" \
python3 <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request

prometheus_url = os.environ["PROMETHEUS_URL"]
loki_url = os.environ["LOKI_URL"]
failures = []


def get_json(url, params=None):
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.load(response)


def query(expression):
    payload = get_json(
        f"{prometheus_url}/api/v1/query",
        {"query": expression},
    )
    if payload.get("status") != "success":
        raise RuntimeError(payload)
    return payload["data"]["result"]


def positive_checks(name, expression):
    rows = query(expression)
    active = [row for row in rows if float(row["value"][1]) > 0]
    if active:
        labels = [row["metric"] for row in active]
        failures.append(f"{name}: {labels}")


probe_rows = query(
    'probe_success{job=~"integrations/blackbox/(api-ready|eu-relay)"}'
)
probe_jobs = {row["metric"].get("job") for row in probe_rows}
expected_jobs = {
    "integrations/blackbox/api-ready",
    "integrations/blackbox/eu-relay",
}
if probe_jobs != expected_jobs or any(float(row["value"][1]) != 1 for row in probe_rows):
    failures.append(f"public probes: jobs={sorted(probe_jobs)}")

host_rows = query('max by (host) (node_uname_info{host=~"monitoring|moscow|eu"})')
hosts = {row["metric"].get("host") for row in host_rows}
expected_hosts = {"monitoring", "moscow", "eu"}
if hosts != expected_hosts:
    failures.append(f"host telemetry: hosts={sorted(hosts)}")

host_series = query('count by (host) (node_uname_info{host=~"monitoring|moscow|eu"})')
duplicate_hosts = {
    row["metric"].get("host"): int(float(row["value"][1]))
    for row in host_series
    if int(float(row["value"][1])) != 1
}
if duplicate_hosts:
    failures.append(f"duplicate host metric series: {duplicate_hosts}")

container_series = query("count by (host, container) (telescan_container_running)")
duplicate_containers = [
    row["metric"]
    for row in container_series
    if int(float(row["value"][1])) != 1
]
if duplicate_containers:
    failures.append(f"duplicate container metric series: {duplicate_containers}")

positive_checks(
    "stopped expected containers",
    "(1 - telescan_container_running) "
    "and on (host, container, service) (telescan_container_expected == 1)",
)
positive_checks(
    "unhealthy expected containers",
    "(1 - telescan_container_healthy) "
    "and on (host, container, service) (telescan_container_healthcheck == 1) "
    "and on (host, container, service) (telescan_container_expected == 1)",
)
positive_checks("inactive timers", "1 - telescan_systemd_timer_active")
positive_checks("failed monitored services", "1 - telescan_systemd_service_success")
positive_checks(
    "stale MongoDB backup",
    "time() - telescan_systemd_service_last_exit_timestamp_seconds"
    '{unit="telescan-mongodb-backup.service"} - 108000',
)
positive_checks(
    "stale WireGuard handshakes",
    "time() - telescan_wireguard_latest_handshake_seconds - 300",
)
positive_checks(
    "root disk above 85 percent",
    "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / "
    "node_filesystem_size_bytes{mountpoint=\"/\"}) - 85",
)
positive_checks(
    "memory above 90 percent",
    "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) - 90",
)

loki_payload = get_json(f"{loki_url}/loki/api/v1/label/host/values")
log_hosts = set(loki_payload.get("data", []))
if not expected_hosts.issubset(log_hosts):
    failures.append(f"Loki log hosts: {sorted(log_hosts)}")

if failures:
    for failure in failures:
        print(f"FAILED: {failure}", file=sys.stderr)
    raise SystemExit(1)

print(f"Public probes healthy: {', '.join(sorted(probe_jobs))}")
print(f"Metric hosts present: {', '.join(sorted(hosts))}")
print(f"Log hosts present: {', '.join(sorted(log_hosts))}")
print("Production telemetry checks passed.")
PY

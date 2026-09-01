#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

ingest_bind_address="${INGEST_BIND_ADDRESS:-}"
require_state_freshness_metrics="${REQUIRE_STATE_FRESHNESS_METRICS:-}"
if [[ -r .env ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      INGEST_BIND_ADDRESS)
        [[ -z "$ingest_bind_address" ]] && ingest_bind_address="${value%$'\r'}"
        ;;
      REQUIRE_STATE_FRESHNESS_METRICS)
        [[ -z "$require_state_freshness_metrics" ]] && \
          require_state_freshness_metrics="${value%$'\r'}"
        ;;
    esac
  done <.env
fi
ingest_bind_address="${ingest_bind_address:-127.0.0.1}"
require_state_freshness_metrics="${require_state_freshness_metrics:-false}"

if [[ ! "$ingest_bind_address" =~ ^[0-9A-Fa-f:.]+$ ]]; then
  echo "Invalid INGEST_BIND_ADDRESS: $ingest_bind_address" >&2
  exit 1
fi
if [[ "$require_state_freshness_metrics" != true && \
      "$require_state_freshness_metrics" != false ]]; then
  echo "REQUIRE_STATE_FRESHNESS_METRICS must be true or false." >&2
  exit 1
fi

PROMETHEUS_URL="http://$ingest_bind_address:9090" \
LOKI_URL="http://$ingest_bind_address:3100" \
REQUIRE_STATE_FRESHNESS_METRICS="$require_state_freshness_metrics" \
python3 <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request

prometheus_url = os.environ["PROMETHEUS_URL"]
loki_url = os.environ["LOKI_URL"]
require_state_freshness_metrics = os.environ["REQUIRE_STATE_FRESHNESS_METRICS"] == "true"
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


probe_rows = query(
    'probe_success{job=~"integrations/blackbox/(api-ready|eu-relay|privacy-page|terms-page)"}'
)
probe_jobs = {row["metric"].get("job") for row in probe_rows}
expected_jobs = {
    "integrations/blackbox/api-ready",
    "integrations/blackbox/eu-relay",
    "integrations/blackbox/privacy-page",
    "integrations/blackbox/terms-page",
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

problem_rows = query("telescan:production_problem")
if not any(row["metric"].get("check") == "healthy_sentinel" for row in problem_rows):
    failures.append("production recording rule is missing its healthy sentinel")
active_problems = [
    row
    for row in problem_rows
    if row["metric"].get("check") != "healthy_sentinel"
    and float(row["value"][1]) > 0
]
if active_problems:
    failures.append(
        "production health checks: "
        + repr([row["metric"] for row in active_problems])
    )

if require_state_freshness_metrics:
    state_rows = query(
        "max by (host) (telescan_monitoring_state_last_success_timestamp_seconds)"
    )
    state_hosts = {row["metric"].get("host") for row in state_rows}
    if state_hosts != expected_hosts:
        failures.append(f"state freshness metrics: hosts={sorted(state_hosts)}")

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
if require_state_freshness_metrics:
    print("State freshness coverage is required and present for every host.")
else:
    print("State freshness coverage is in staged mode; set REQUIRE_STATE_FRESHNESS_METRICS=true after all agents are updated.")
print("Production telemetry checks passed.")
PY

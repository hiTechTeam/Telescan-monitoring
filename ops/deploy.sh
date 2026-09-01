#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

compose=(sudo docker compose)
if [[ -n "${TELESCAN_MONITORING_RESTART_OVERRIDE:-}" ]]; then
  if ! { : >&9; } 2>/dev/null || ! flock --nonblock 9; then
    echo "The transaction restart override requires inherited production lock FD 9." >&2
    exit 1
  fi
  override="$(realpath "$TELESCAN_MONITORING_RESTART_OVERRIDE")"
  case "$override" in
    /home/ubuntu/telescan-monitoring/.release-state/*/ops/compose-transaction-no-restart.yaml|\
    /home/ubuntu/telescan-monitoring/.release-state/controllers/*/ops/compose-transaction-no-restart.yaml|\
    /tmp/telescan-monitoring-transaction-test.*/*/ops/compose-transaction-no-restart.yaml|\
    /private/tmp/telescan-monitoring-transaction-test.*/*/ops/compose-transaction-no-restart.yaml) ;;
    *) echo "Unsafe monitoring restart override path." >&2; exit 2 ;;
  esac
  compose+=(--project-name telescan-monitoring -f "$PWD/compose.yaml" -f "$override")
fi

sudo ./ops/prepare-host.sh
"${compose[@]}" config --quiet
if "${compose[@]}" config | grep -q 'GF_SECURITY_SECRET_KEY__FILE'; then
  sudo ./ops/check-grafana-secret-key.sh
fi
"${compose[@]}" pull
"${compose[@]}" up -d --remove-orphans

expected_services="$("${compose[@]}" config --services | wc -l | tr -d ' ')"
if [[ ! "$expected_services" =~ ^[1-9][0-9]*$ ]]; then
  echo "Could not determine the enabled Docker Compose service count." >&2
  exit 1
fi

deadline=$((SECONDS + 180))
stack_ready=false
while (( SECONDS < deadline )); do
  unhealthy="$(
    "${compose[@]}" ps --format json |
      python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    rows = []
else:
    try:
        decoded = json.loads(raw)
        rows = decoded if isinstance(decoded, list) else [decoded]
    except json.JSONDecodeError:
        rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
bad = [row["Service"] for row in rows if row.get("Health") not in ("", "healthy")]
print(" ".join(bad))
'
  )"
  running="$("${compose[@]}" ps --services --status running | wc -l | tr -d ' ')"
  if [[ "$running" -eq "$expected_services" && -z "$unhealthy" ]]; then
    ./ops/check-stack.sh
    stack_ready=true
    break
  fi
  sleep 5
done

if [[ "$stack_ready" != true ]]; then
  "${compose[@]}" ps
  "${compose[@]}" logs --tail=100
  echo "Monitoring stack did not become healthy within 180 seconds" >&2
  exit 1
fi

# A green container healthcheck is not sufficient: wait for remote host
# metrics, public probes, recording rules, and Loki labels to be queryable.
telemetry_deadline=$((SECONDS + 300))
while (( SECONDS < telemetry_deadline )); do
  if ./ops/check-telemetry.sh; then
    echo "Monitoring deployment and full telemetry verification passed."
    exit 0
  fi
  echo "Full telemetry is not ready yet; retrying in 10 seconds." >&2
  sleep 10
done

"${compose[@]}" ps
"${compose[@]}" logs --tail=100
echo "Full telemetry verification did not pass within 300 seconds." >&2
exit 1

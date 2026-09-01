#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage() {
  echo "Usage: sudo $0 --apply --confirm SEND_TELESCAN_TELEGRAM_DRILL --drill-id ID" >&2
  exit 2
}

[[ $# -eq 5 ]] || usage
[[ "$1" == --apply ]] || usage
[[ "$2" == --confirm ]] || usage
[[ "$3" == SEND_TELESCAN_TELEGRAM_DRILL ]] || usage
[[ "$4" == --drill-id ]] || usage
drill_id="$5"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi
if [[ ! -t 0 ]]; then
  echo "The full delivery drill requires an interactive operator to attest both Telegram messages." >&2
  exit 1
fi
if [[ ! "$drill_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
  echo "Drill ID must be 1-64 ASCII letters, digits, underscores, or hyphens." >&2
  exit 2
fi

monitoring_data_root="${MONITORING_DATA_ROOT:-}"
ingest_bind_address="${INGEST_BIND_ADDRESS:-}"
if [[ -r .env ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      MONITORING_DATA_ROOT)
        [[ -z "$monitoring_data_root" ]] && monitoring_data_root="${value%$'\r'}"
        ;;
      INGEST_BIND_ADDRESS)
        [[ -z "$ingest_bind_address" ]] && ingest_bind_address="${value%$'\r'}"
        ;;
    esac
  done <.env
fi
monitoring_data_root="${monitoring_data_root:-/var/lib/telescan-monitoring}"
ingest_bind_address="${ingest_bind_address:-127.0.0.1}"

if [[ ! "$monitoring_data_root" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Invalid MONITORING_DATA_ROOT." >&2
  exit 1
fi
if [[ ! "$ingest_bind_address" =~ ^[0-9A-Fa-f:.]+$ ]]; then
  echo "Invalid INGEST_BIND_ADDRESS." >&2
  exit 1
fi

metric_dir="$monitoring_data_root/alloy/textfile"
metric_file="$metric_dir/telegram-delivery-drill.prom"
evidence_dir="$monitoring_data_root/drills"
evidence_file="$evidence_dir/telegram-delivery.log"
install -d -m 0755 "$metric_dir"
install -d -m 0700 "$evidence_dir"
tmp_file="$(mktemp "$metric_dir/.telegram-delivery-drill.XXXXXX")"
metric_active=false

cleanup() {
  rm -f -- "$tmp_file"
  if [[ "$metric_active" == true ]]; then
    rm -f -- "$metric_file"
  fi
}
trap cleanup EXIT

if [[ -e "$metric_file" ]]; then
  echo "A delivery drill is already active: $metric_file" >&2
  exit 1
fi

./ops/check-stack.sh
./ops/check-telemetry.sh

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo '# HELP telescan_telegram_delivery_drill Operator-triggered end-to-end notification delivery drill.'
  echo '# TYPE telescan_telegram_delivery_drill gauge'
  printf 'telescan_telegram_delivery_drill{drill_id="%s"} 1\n' "$drill_id"
} >"$tmp_file"
chmod 0644 "$tmp_file"
mv -f -- "$tmp_file" "$metric_file"
metric_active=true

wait_for_metric() {
  local expected="$1"
  DRILL_ID="$drill_id" \
  PROMETHEUS_URL="http://$ingest_bind_address:9090" \
  EXPECTED="$expected" \
  python3 <<'PY'
import json
import os
import time
import urllib.parse
import urllib.request

expression = 'telescan_telegram_delivery_drill{drill_id="%s"}' % os.environ["DRILL_ID"]
url = os.environ["PROMETHEUS_URL"] + "/api/v1/query?" + urllib.parse.urlencode({"query": expression})
expected = os.environ["EXPECTED"] == "present"
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            payload = json.load(response)
        present = bool(payload.get("data", {}).get("result", []))
        if present == expected:
            raise SystemExit(0)
    except (OSError, ValueError):
        pass
    time.sleep(5)
raise SystemExit("Prometheus did not observe the expected drill metric state within 90 seconds")
PY
}

wait_for_metric present
echo "Drill $drill_id is visible in Prometheus."
echo "Wait for the Telegram FIRING notification, verify that it contains drill ID '$drill_id',"
if ! read -r -t 600 -p "then type RECEIVED-$drill_id (within 10 minutes): " firing_ack; then
  echo "Timed out waiting for FIRING delivery attestation; the drill failed." >&2
  exit 1
fi
if [[ "$firing_ack" != "RECEIVED-$drill_id" ]]; then
  echo "FIRING delivery was not attested; the drill failed." >&2
  exit 1
fi
firing_received_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

rm -f -- "$metric_file"
metric_active=false
wait_for_metric absent
echo "The drill metric has cleared in Prometheus."
echo "Wait for the Telegram RESOLVED notification for drill '$drill_id',"
if ! read -r -t 600 -p "then type RESOLVED-$drill_id (within 10 minutes): " resolved_ack; then
  echo "Timed out waiting for RESOLVED delivery attestation; the drill failed." >&2
  exit 1
fi
if [[ "$resolved_ack" != "RESOLVED-$drill_id" ]]; then
  echo "RESOLVED delivery was not attested; the drill failed." >&2
  exit 1
fi
resolved_received_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf '{"drill_id":"%s","started_at":"%s","firing_received_at":"%s","resolved_received_at":"%s","operator":"%s"}\n' \
  "$drill_id" "$started_at" "$firing_received_at" "$resolved_received_at" "${SUDO_USER:-root}" \
  >>"$evidence_file"
chmod 0600 "$evidence_file"

echo "Telegram delivery drill $drill_id passed; local evidence was appended to $evidence_file."

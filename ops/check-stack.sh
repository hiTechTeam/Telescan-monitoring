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

check_url() {
  local name="$1"
  local url="$2"

  for _ in {1..10}; do
    if curl --fail --silent --connect-timeout 3 --max-time 5 "$url" >/dev/null 2>&1; then
      printf '%s readiness check passed.\n' "$name"
      return 0
    fi
    sleep 2
  done

  curl --fail --silent --show-error --connect-timeout 3 --max-time 5 "$url" >/dev/null
}

check_url Grafana http://127.0.0.1:3000/api/health
check_url Prometheus "http://$ingest_bind_address:9090/-/ready"
check_url Loki "http://$ingest_bind_address:3100/ready"

sudo docker compose ps

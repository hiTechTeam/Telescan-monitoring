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
  local proxy="${3:-}"
  local -a curl_args=(
    --fail
    --silent
    --connect-timeout 3
    --max-time 8
  )

  if [[ -n "$proxy" ]]; then
    curl_args+=(--proxy "$proxy")
  fi

  for _ in {1..10}; do
    if curl "${curl_args[@]}" "$url" >/dev/null 2>&1; then
      printf '%s readiness check passed.\n' "$name"
      return 0
    fi
    sleep 2
  done

  curl_args+=(--show-error)
  curl "${curl_args[@]}" "$url" >/dev/null
}

check_url Grafana http://127.0.0.1:3000/api/health
check_url Prometheus "http://$ingest_bind_address:9090/-/ready"
check_url Loki "http://$ingest_bind_address:3100/ready"
check_url Telegram-egress https://api.telegram.org \
  "${TELEGRAM_PROXY_URL:-http://10.78.0.3:8888}"

sudo docker compose ps

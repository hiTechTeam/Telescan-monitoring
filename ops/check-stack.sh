#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

check_url() {
  local name="$1"
  local url="$2"

  curl \
    --fail \
    --silent \
    --show-error \
    --retry 10 \
    --retry-all-errors \
    --retry-delay 2 \
    --connect-timeout 3 \
    --max-time 5 \
    "$url" >/dev/null
  printf '%s readiness check passed.\n' "$name"
}

check_url Grafana http://127.0.0.1:3000/api/health
check_url Prometheus http://127.0.0.1:9090/-/ready
check_url Loki http://127.0.0.1:3100/ready

sudo docker compose ps

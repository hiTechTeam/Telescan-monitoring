#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

alloy_image='grafana/alloy:v1.18.1@sha256:0f4434c92b3e6cdac38bb129b344e1790c246f7b6e2eaffcc16a5fa363240e33'

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --pull ) ]]; then
  echo "Usage: $0 [--pull]" >&2
  exit 2
fi
if ! docker image inspect "$alloy_image" >/dev/null 2>&1; then
  if [[ "${1:-}" != --pull ]]; then
    echo "The pinned Alloy image is not local; rerun with --pull to fetch only that image." >&2
    exit 1
  fi
  docker pull "$alloy_image"
fi

docker run --rm \
  --entrypoint /bin/alloy \
  --env TELESCAN_ENVIRONMENT=production \
  --env TELESCAN_HOST=monitoring \
  --volume "$PWD/config/alloy/config.alloy:/etc/alloy/config.alloy:ro" \
  "$alloy_image" \
  validate /etc/alloy/config.alloy

docker run --rm \
  --entrypoint /bin/alloy \
  --env TELESCAN_ENVIRONMENT=production \
  --env TELESCAN_HOST=ci \
  --env PROMETHEUS_REMOTE_WRITE_URL=http://127.0.0.1:9090/api/v1/write \
  --env LOKI_WRITE_URL=http://127.0.0.1:3100/loki/api/v1/push \
  --volume "$PWD/agent/config.alloy:/etc/alloy/config.alloy:ro" \
  "$alloy_image" \
  validate /etc/alloy/config.alloy

echo "Central and agent Alloy configuration validation passed."

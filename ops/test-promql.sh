#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

test_file=tests/prometheus-rules.test.yml
rules_file=config/prometheus/telescan-recording-rules.yml
prometheus_image='prom/prometheus:v3.14.0@sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0'

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --pull ) ]]; then
  echo "Usage: $0 [--pull]" >&2
  exit 2
fi

if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules_file"
  exec promtool test rules "$test_file"
fi

if ! docker image inspect "$prometheus_image" >/dev/null 2>&1; then
  if [[ "${1:-}" != --pull ]]; then
    echo "promtool is unavailable and the pinned Prometheus image is not local." >&2
    echo "Run $0 --pull to explicitly fetch only the pinned image." >&2
    exit 1
  fi
  docker pull "$prometheus_image"
fi

docker run --rm \
  --entrypoint /bin/promtool \
  --volume "$PWD:/workspace:ro" \
  --workdir /workspace \
  "$prometheus_image" \
  check rules "$rules_file"

exec docker run --rm \
  --entrypoint /bin/promtool \
  --volume "$PWD:/workspace:ro" \
  --workdir /workspace \
  "$prometheus_image" \
  test rules "$test_file"

#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

nginx_image='nginx:1.30.4-alpine3.24@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46'

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --pull ) ]]; then
  echo "Usage: $0 [--pull]" >&2
  exit 2
fi

if ! docker image inspect "$nginx_image" >/dev/null 2>&1; then
  if [[ "${1:-}" != --pull ]]; then
    echo "The pinned nginx image is not local; rerun with --pull to fetch only that image." >&2
    exit 1
  fi
  docker pull "$nginx_image"
fi

exec docker run --rm \
  --entrypoint nginx \
  --add-host prometheus:127.0.0.1 \
  --add-host loki:127.0.0.1 \
  --read-only \
  --tmpfs /tmp:size=32m,mode=1777 \
  --user 101:101 \
  --volume "$PWD/ingest/nginx.conf:/etc/nginx/nginx.conf:ro" \
  "$nginx_image" \
  -t

#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

request_status() {
  curl --silent --output /dev/null --write-out '%{http_code}' \
    --noproxy '*' --connect-timeout 3 --max-time 10 "$@" || true
}

test "$(curl --fail --silent --noproxy '*' http://10.78.0.1:19090/health)" = ok
test "$(curl --fail --silent --noproxy '*' http://10.78.0.1:13100/health)" = ok
test "$(request_status http://10.78.0.1:19090/api/v1/query)" = 404
test "$(request_status http://10.78.0.1:13100/loki/api/v1/query)" = 404

# An intentionally invalid protobuf body must reach each upstream and be
# rejected as bad input. A 403 would mean this WireGuard peer is not allowed;
# a 404 would mean the exact write route is absent.
prometheus_status="$(request_status \
  --request POST \
  --header 'Content-Type: application/x-protobuf' \
  --data-binary '' \
  http://10.78.0.1:19090/api/v1/write)"
loki_status="$(request_status \
  --request POST \
  --header 'Content-Type: application/x-protobuf' \
  --data-binary '' \
  http://10.78.0.1:13100/loki/api/v1/push)"

if [[ "$prometheus_status" != 204 && "$prometheus_status" != 400 && \
      "$prometheus_status" != 415 ]]; then
  echo "Prometheus restricted write preflight failed: status=$prometheus_status" >&2
  exit 1
fi
if [[ "$loki_status" != 204 && "$loki_status" != 400 && \
      "$loki_status" != 415 ]]; then
  echo "Loki restricted write preflight failed: status=$loki_status" >&2
  exit 1
fi

echo "Restricted ingest is reachable from this approved WireGuard peer and full query APIs are absent."

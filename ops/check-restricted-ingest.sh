#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

check_status() {
  local expected="$1"
  local url="$2"
  local status
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --noproxy '*' --connect-timeout 3 --max-time 10 "$url" || true)"
  if [[ "$status" != "$expected" ]]; then
    echo "Unexpected response for $url: expected=$expected actual=${status:-unavailable}" >&2
    exit 1
  fi
}

test "$(curl --fail --silent --noproxy '*' http://10.78.0.1:19090/health)" = ok
test "$(curl --fail --silent --noproxy '*' http://10.78.0.1:13100/health)" = ok

# The monitoring host is not in the remote-agent allow-list, so even the two
# write endpoints must reject its source address. Full read/query APIs must be
# absent regardless of source.
check_status 403 http://10.78.0.1:19090/api/v1/write
check_status 403 http://10.78.0.1:13100/loki/api/v1/push
check_status 404 http://10.78.0.1:19090/api/v1/query
check_status 404 http://10.78.0.1:13100/loki/api/v1/query

echo "Restricted ingest listener and deny-boundary checks passed."

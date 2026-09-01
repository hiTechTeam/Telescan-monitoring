#!/bin/sh
set -eu

key_file=/run/secrets/grafana_secret_key
marker_file=/run/secrets/grafana_secret_key_ready

if [ ! -r "$key_file" ] || [ ! -s "$key_file" ]; then
  echo "Grafana secret-key guard: key file is absent or unreadable." >&2
  exit 1
fi
if [ ! -r "$marker_file" ] || ! grep -q '^status=ready$' "$marker_file"; then
  echo "Grafana secret-key guard: migration readiness has not been attested." >&2
  exit 1
fi

key="$(tr -d '\r\n' <"$key_file")"
case "$key" in
  *[!0-9a-fA-F]*|'')
    echo "Grafana secret-key guard: key format is invalid." >&2
    exit 1
    ;;
esac
if [ "${#key}" -ne 64 ]; then
  echo "Grafana secret-key guard: key length is invalid." >&2
  exit 1
fi
unset key

exec /run.sh

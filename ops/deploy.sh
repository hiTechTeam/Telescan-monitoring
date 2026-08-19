#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

sudo ./ops/prepare-host.sh
sudo docker compose config --quiet
sudo docker compose pull
sudo docker compose up -d --remove-orphans

deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  unhealthy="$(
    sudo docker compose ps --format json |
      python3 -c '
import json, sys
rows = [json.loads(line) for line in sys.stdin if line.strip()]
bad = [row["Service"] for row in rows if row.get("Health") not in ("", "healthy")]
print(" ".join(bad))
'
  )"
  running="$(sudo docker compose ps --services --status running | wc -l)"
  if [[ "$running" -eq 4 && -z "$unhealthy" ]]; then
    exec ./ops/check-stack.sh
  fi
  sleep 5
done

sudo docker compose ps
sudo docker compose logs --tail=100
echo "Monitoring stack did not become healthy within 180 seconds" >&2
exit 1

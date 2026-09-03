#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

temporary_root="$(mktemp -d /tmp/telescan-docker-gc-test.XXXXXX)"
trap 'rm -r -- "$temporary_root"' EXIT
config_file="$temporary_root/agent.env"
lock_file="$temporary_root/deploy.lock"
transaction_root="$temporary_root/transactions"
events="$temporary_root/docker.events"
docker_shim="$temporary_root/docker"
flock_shim="$temporary_root/flock"
mkdir -p "$transaction_root"
: >"$lock_file"

printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>%q\n' "$events" >"$docker_shim"
chmod +x "$docker_shim"
printf '#!/usr/bin/env bash\nexit 0\n' >"$flock_shim"
chmod +x "$flock_shim"

run_maintenance() {
  TELESCAN_DOCKER_GC_TEST_MODE=1 \
  TELESCAN_DOCKER_GC_CONFIG_FILE="$config_file" \
  TELESCAN_DOCKER_GC_LOCK_FILE="$lock_file" \
  TELESCAN_DOCKER_GC_TRANSACTION_ROOT="$transaction_root" \
  TELESCAN_DOCKER_GC_DOCKER_BIN="$docker_shim" \
  TELESCAN_DOCKER_GC_FLOCK_BIN="$flock_shim" \
    bash agent/ops/prune-docker-build-cache.sh
}

printf 'TELESCAN_HOST=moscow\n' >"$config_file"
run_maintenance >/dev/null
grep -qx 'builder prune --all --force --filter until=24h' "$events"

: >"$events"
mkdir -p "$transaction_root/Telescan-api"
printf '{}\n' >"$transaction_root/Telescan-api/active.json"
run_maintenance >/dev/null
[[ ! -s "$events" ]]

rm "$transaction_root/Telescan-api/active.json"
printf '#!/usr/bin/env bash\nexit 1\n' >"$flock_shim"
run_maintenance >/dev/null
[[ ! -s "$events" ]]

printf '#!/usr/bin/env bash\nexit 0\n' >"$flock_shim"
printf 'TELESCAN_HOST=eu\n' >"$config_file"
run_maintenance >/dev/null
[[ ! -s "$events" ]]

echo "Docker build-cache maintenance safety gates passed."

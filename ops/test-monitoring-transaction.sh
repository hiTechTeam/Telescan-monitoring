#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
raw_root="$(mktemp -d /tmp/telescan-monitoring-transaction-test.XXXXXX)"
test_root="$(cd "$raw_root" && pwd -P)"
mock_bin="$test_root/mock-bin"
active_root="$test_root/active"
release_root="$test_root/release"
test_log="$test_root/commands.log"
rollback_state="$test_root/rollback-state"
old_ref_state="$test_root/old-ref-state"
cleanup() {
  local status=$?
  trap - EXIT
  chmod -R u+w "$test_root" 2>/dev/null || true
  rm -r -- "$test_root"
  exit "$status"
}
trap cleanup EXIT
install -d -m 0700 "$mock_bin" "$active_root/ops" "$release_root/ops"

write_executable() {
  local path="$1"
  shift
  install -m 0755 /dev/null "$path"
  printf '%s\n' "$@" >"$path"
}

write_executable "$mock_bin/realpath" \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  '[[ $# -eq 1 && -e "$1" ]]' \
  'python3 -c '\''import os,sys; print(os.path.realpath(sys.argv[1]))'\'' "$1"'
write_executable "$mock_bin/flock" \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'mode=block' \
  'if [[ "$1" == --nonblock && "$2" == 9 ]]; then mode=nonblock' \
  'elif [[ "$1" == --exclusive && "$2" == --timeout && "$3" == 1800 && "$4" == 9 ]]; then mode=block' \
  'else exit 2; fi' \
  'python3 -c '\''import fcntl,sys; fcntl.flock(9, fcntl.LOCK_EX | (fcntl.LOCK_NB if sys.argv[1] == "nonblock" else 0))'\'' "$mode"'
write_executable "$mock_bin/sudo" \
  '#!/usr/bin/env bash' \
  'exec "$@"'
write_executable "$mock_bin/timeout" \
  '#!/usr/bin/env bash' \
  '[[ "$1" == --signal=TERM ]]' \
  'shift 2' \
  'exec "$@"'
write_executable "$mock_bin/docker" \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'old_id=sha256:1111111111111111111111111111111111111111111111111111111111111111' \
  'new_id=sha256:2222222222222222222222222222222222222222222222222222222222222222' \
  'old_ref=example/monitoring-old:stable' \
  'new_ref=example/monitoring-new@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'if [[ "$1" == compose ]]; then' \
  '  shift' \
  '  [[ "$1" == --env-file && "$2" == "$TRANSACTION_ACTIVE_ROOT/.env" ]]' \
  '  shift 2' \
  '  [[ "$1" == --project-name && "$2" == telescan-monitoring ]]' \
  '  shift 2' \
  '  case "${1:-}" in' \
  '    config)' \
  '      case "${2:-}" in' \
  '        --services) echo grafana ;;' \
  '        --format) printf "{\"services\":{\"grafana\":{\"image\":\"%s\"}}}\n" "$new_ref" ;;' \
  '        --quiet|"") : ;;' \
  '        *) exit 1 ;;' \
  '      esac' \
  '      ;;' \
  '    pull) echo candidate-pull >>"$TRANSACTION_TEST_LOG" ;;' \
  '    ps)' \
  '      if [[ "${2:-}" == -q && "${3:-}" == grafana ]]; then echo container-grafana; fi' \
  '      ;;' \
  '    up) echo rollback-compose-up >>"$TRANSACTION_TEST_LOG" ;;' \
  '    logs) : ;;' \
  '    *) exit 1 ;;' \
  '  esac' \
  'elif [[ "$1" == inspect && "$2" == --format ]]; then' \
  '  case "$3" in' \
  '    *State.Running*) echo true ;;' \
  '    *Config.Image*) echo "$old_ref" ;;' \
  '    *Image*) echo "$old_id" ;;' \
  '    *) exit 1 ;;' \
  '  esac' \
  'elif [[ "$1 $2" == "image inspect" && "$3" == --format ]]; then' \
  '  target="${5:-}"' \
  '  case "$target" in' \
  '    "$new_ref") echo "$new_id" ;;' \
  '    "$old_ref") cat "$TRANSACTION_OLD_REF_STATE" ;;' \
  '    telescan-monitoring-rollback:*) cat "$TRANSACTION_ROLLBACK_STATE" ;;' \
  '    sha256:*) echo "$target" ;;' \
  '    *) exit 1 ;;' \
  '  esac' \
  'elif [[ "$1 $2" == "image tag" ]]; then' \
  '  source="$3"; target="$4"' \
  '  if [[ "$source" == telescan-monitoring-rollback:* ]]; then source="$(cat "$TRANSACTION_ROLLBACK_STATE")"; fi' \
  '  case "$target" in' \
  '    telescan-monitoring-rollback:*) printf "%s\n" "$source" >"$TRANSACTION_ROLLBACK_STATE"; echo rollback-protected >>"$TRANSACTION_TEST_LOG" ;;' \
  '    "$old_ref") printf "%s\n" "$source" >"$TRANSACTION_OLD_REF_STATE" ;;' \
  '    *) exit 1 ;;' \
  '  esac' \
  'elif [[ "$1 $2" == "image rm" ]]; then' \
  '  : >"$TRANSACTION_ROLLBACK_STATE"' \
  'elif [[ "$1" == update && "$2" == --restart && "$3" == unless-stopped ]]; then' \
  '  echo restart-armed >>"$TRANSACTION_TEST_LOG"' \
  'else' \
  '  printf "Unexpected mocked Docker command: %q " "$@" >&2; echo >&2; exit 1' \
  'fi'

prepare_case() {
  local candidate_status="$1"
  rm -r -- "$active_root" "$release_root"
  install -d -m 0700 "$active_root/ops" "$release_root/ops"
  printf 'runtime-only\n' >"$active_root/.env"
  chmod 0600 "$active_root/.env"
  printf 'name: telescan-monitoring\nservices: {}\n' >"$active_root/compose.yaml"
  printf 'old\n' >"$active_root/version.txt"
  write_executable "$active_root/ops/deploy.sh" '#!/usr/bin/env bash' 'exit 0'
  write_executable "$active_root/ops/check-stack.sh" '#!/usr/bin/env bash' 'exit 0'
  write_executable "$active_root/ops/check-telemetry.sh" '#!/usr/bin/env bash' 'exit 0'

  printf 'name: telescan-monitoring\nservices: {}\n' >"$release_root/compose.yaml"
  printf 'new\n' >"$release_root/version.txt"
  install -m 0755 ops/release-state.py "$release_root/ops/release-state.py"
  install -m 0644 ops/compose-transaction-no-restart.yaml \
    "$release_root/ops/compose-transaction-no-restart.yaml"
  write_executable "$release_root/ops/deploy.sh" \
    '#!/usr/bin/env bash' \
    'echo candidate-deploy >>"$TRANSACTION_TEST_LOG"' \
    'if [[ "${TELESCAN_MONITORING_TRANSACTION_KILLPOINT:-}" == after-recreate ]]; then kill -KILL "$PPID"; exit 137; fi' \
    "exit $candidate_status"
  write_executable "$release_root/ops/check-stack.sh" '#!/usr/bin/env bash' 'exit 1'
  write_executable "$release_root/ops/check-telemetry.sh" '#!/usr/bin/env bash' 'exit 1'
  : >"$test_log"
  printf '%s\n' sha256:1111111111111111111111111111111111111111111111111111111111111111 >"$old_ref_state"
  : >"$rollback_state"
}

invoke() (
  lock_mode="${2:-locked}"
  if [[ "$lock_mode" == locked ]]; then
    exec 9>"$test_root/production.lock"
    "$mock_bin/flock" --exclusive --timeout 1800 9
  fi
  PATH="$mock_bin:$PATH" \
  TRANSACTION_TEST_LOG="$test_log" \
  TRANSACTION_ACTIVE_ROOT="$active_root" \
  TRANSACTION_OLD_REF_STATE="$old_ref_state" \
  TRANSACTION_ROLLBACK_STATE="$rollback_state" \
  TELESCAN_MONITORING_TRANSACTION_TEST_MODE=1 \
  TELESCAN_MONITORING_TRANSACTION_TEST_ROOT="$test_root" \
  TELESCAN_MONITORING_TRANSACTION_KILLPOINT="${1:-}" \
    bash ops/run-release-transaction.sh \
      --apply --confirm DEPLOY_MONITORING_RELEASE_WITH_ROLLBACK \
      --active-root "$active_root" --release-root "$release_root"
)

run_expect() {
  local expected="$1" killpoint="${2:-}" lock_mode="${3:-locked}" output="$test_root/transaction.out" actual
  set +e
  invoke "$killpoint" "$lock_mode" >"$output" 2>&1
  actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    cat "$output" >&2
    echo "Unexpected monitoring transaction status: expected=$expected actual=$actual" >&2
    exit 1
  fi
}

persistent_recover() {
  PATH="$mock_bin:$PATH" \
  TRANSACTION_TEST_LOG="$test_log" \
  TRANSACTION_ACTIVE_ROOT="$active_root" \
  TRANSACTION_OLD_REF_STATE="$old_ref_state" \
  TRANSACTION_ROLLBACK_STATE="$rollback_state" \
  TELESCAN_MONITORING_TRANSACTION_TEST_MODE=1 \
  TELESCAN_MONITORING_TRANSACTION_TEST_ROOT="$test_root" \
    bash "$active_root/.release-state/recovery-controller/ops/run-release-transaction.sh" \
      --apply --confirm RECOVER_MONITORING_RELEASE \
      --active-root "$active_root" --recover-only
}

prepare_case 0
run_expect 1 "" unlocked
[[ ! -e "$active_root/current" ]]

prepare_case 42
run_expect 42
[[ "$(cat "$active_root/current/version.txt")" == old ]]
[[ "$(cat "$active_root/.env")" == runtime-only ]]
[[ -L "$active_root/current/.env" ]]
[[ ! -e "$active_root/.release-state/intent.json" ]]
grep -q '^rollback-protected$' "$test_log"
grep -q '^rollback-compose-up$' "$test_log"

prepare_case 0
run_expect 0
[[ "$(cat "$active_root/current/version.txt")" == new ]]
[[ "$(cat "$active_root/.env")" == runtime-only ]]
[[ -L "$active_root/current/.env" ]]
[[ ! -e "$active_root/.release-state/intent.json" ]]
grep -q '^restart-armed$' "$test_log"

for killpoint in after-intent after-pointer after-recreate; do
  prepare_case 0
  run_expect 1 "$killpoint"
  [[ "$(cat "$active_root/current/version.txt")" == old ]]
  [[ ! -e "$active_root/.release-state/intent.json" ]]
done

prepare_case 0
run_expect 1 after-commit
[[ "$(cat "$active_root/current/version.txt")" == new ]]
[[ ! -e "$active_root/.release-state/intent.json" ]]
grep -q '^restart-armed$' "$test_log"

prepare_case 0
(
  for _ in {1..200}; do
    [[ -f "$active_root/.release-state/intent.json" ]] && break
    sleep 0.02
  done
  [[ -f "$active_root/.release-state/intent.json" ]]
  exec 9>"$test_root/production.lock"
  "$mock_bin/flock" --exclusive --timeout 1800 9
  persistent_recover >"$test_root/path-recovery.out" 2>&1
) &
watcher_pid=$!
run_expect 137 outer-after-intent
wait "$watcher_pid"
[[ "$(cat "$active_root/current/version.txt")" == old ]]
[[ ! -e "$active_root/.release-state/intent.json" ]]

echo "Monitoring immutable transaction passed rollback/success, child SIGKILL, and outer-session path-watcher recovery fixtures."

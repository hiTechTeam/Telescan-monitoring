#!/usr/bin/env bash
set -Eeuo pipefail

mode=deploy
if [[ $# -eq 7 && "$1" == --apply && "$2" == --confirm && \
      "$3" == DEPLOY_MONITORING_RELEASE_WITH_ROLLBACK && \
      "$4" == --active-root && "$6" == --release-root ]]; then
  active_input="$5"
elif [[ $# -eq 6 && "$1" == --apply && "$2" == --confirm && \
        "$3" == RECOVER_MONITORING_RELEASE && \
        "$4" == --active-root && "$6" == --recover-only ]]; then
  mode=recover
  active_input="$5"
else
  echo "Deploy: $0 --apply --confirm DEPLOY_MONITORING_RELEASE_WITH_ROLLBACK --active-root /home/ubuntu/telescan-monitoring --release-root /home/ubuntu/.telescan-monitoring-release.SUFFIX" >&2
  echo "Recover: $0 --apply --confirm RECOVER_MONITORING_RELEASE --active-root /home/ubuntu/telescan-monitoring --recover-only" >&2
  exit 2
fi
active_root="$(realpath "$active_input")"
ops_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller="$ops_root/deploy-release-with-rollback.sh"

if ! { : >&9; } 2>/dev/null || ! flock --nonblock 9; then
  echo "The monitoring release supervisor requires inherited production lock FD 9." >&2
  exit 1
fi

if [[ "$mode" == recover ]]; then
  exec bash "$controller" "$@"
fi

intent="$active_root/.release-state/intent.json"
if [[ -f "$intent" ]]; then
  bash "$controller" --apply --confirm RECOVER_MONITORING_RELEASE \
    --active-root "$active_root" --recover-only
fi

controller_name="controller-$(date -u +%Y%m%dT%H%M%SZ)-$$"
controller_root="$active_root/.release-state/controllers/$controller_name"
controller_store="$controller_root/ops"
install -d -m 0700 "$controller_store"
for file in deploy-release-with-rollback.sh run-release-transaction.sh \
    release-state.py compose-transaction-no-restart.yaml; do
  install -m 0755 "$ops_root/$file" "$controller_store/$file"
done
chmod 0644 "$controller_store/compose-transaction-no-restart.yaml"
python3 "$controller_store/release-state.py" sync-tree --path "$controller_root"
python3 "$controller_store/release-state.py" sync-dir --path "$active_root"
python3 "$controller_store/release-state.py" switch-path \
  --root "$active_root/.release-state" --link recovery-controller \
  --target "controllers/$controller_name"

set +e
bash "$controller" "$@"
child_status=$?
set -e
if [[ -f "$intent" ]]; then
  echo "Monitoring child exited with durable intent; supervisor is recovering before returning." >&2
  if ! bash "$controller" --apply --confirm RECOVER_MONITORING_RELEASE \
      --active-root "$active_root" --recover-only; then
    echo "CRITICAL: monitoring supervisor recovery failed; intent remains at $intent." >&2
    exit 1
  fi
fi
if [[ "$child_status" -ne 0 ]]; then
  [[ "$child_status" -lt 128 ]] || exit 1
  exit "$child_status"
fi
echo "Monitoring release supervisor verified that no durable transaction intent remains."

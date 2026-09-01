#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Deploy: $0 --apply --confirm DEPLOY_MONITORING_RELEASE_WITH_ROLLBACK --active-root /home/ubuntu/telescan-monitoring --release-root /home/ubuntu/.telescan-monitoring-release.SUFFIX" >&2
  echo "Recover: $0 --apply --confirm RECOVER_MONITORING_RELEASE --active-root /home/ubuntu/telescan-monitoring --recover-only" >&2
  exit 2
}

mode=deploy
if [[ $# -eq 7 && "$1" == --apply && "$2" == --confirm && \
      "$3" == DEPLOY_MONITORING_RELEASE_WITH_ROLLBACK && \
      "$4" == --active-root && "$6" == --release-root ]]; then
  active_input="$5"
  release_input="$7"
elif [[ $# -eq 6 && "$1" == --apply && "$2" == --confirm && \
        "$3" == RECOVER_MONITORING_RELEASE && \
        "$4" == --active-root && "$6" == --recover-only ]]; then
  mode=recover
  active_input="$5"
  release_input=""
else
  usage
fi
[[ -d "$active_input" ]] || usage
[[ "$mode" == recover || -d "$release_input" ]] || usage

active_root="$(realpath "$active_input")"
release_root=""
[[ "$mode" == recover ]] || release_root="$(realpath "$release_input")"
controller_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_tool="$controller_root/ops/release-state.py"
transaction_test_mode="${TELESCAN_MONITORING_TRANSACTION_TEST_MODE:-0}"
if [[ "$transaction_test_mode" == 1 ]]; then
  test_root="$(realpath "${TELESCAN_MONITORING_TRANSACTION_TEST_ROOT:?}")"
  case "$test_root" in
    /tmp/telescan-monitoring-transaction-test.*|/private/tmp/telescan-monitoring-transaction-test.*) ;;
    *) usage ;;
  esac
  [[ "$active_root" == "$test_root/active" ]] || usage
  [[ "$mode" == recover || "$release_root" == "$test_root/release" ]] || usage
  restart_override="$controller_root/ops/compose-transaction-no-restart.yaml"
else
  [[ "$transaction_test_mode" == 0 ]] || usage
  [[ "$active_root" == /home/ubuntu/telescan-monitoring ]] || usage
  [[ "$mode" == recover || "$release_root" == /home/ubuntu/.telescan-monitoring-release.* ]] || usage
  [[ -z "${TELESCAN_MONITORING_TRANSACTION_KILLPOINT:-}" ]] || usage
  restart_override="$active_root/.release-state/recovery-controller/ops/compose-transaction-no-restart.yaml"
fi
[[ -f "$state_tool" ]] || usage

if ! { : >&9; } 2>/dev/null || ! flock --nonblock 9; then
  echo "The monitoring release transaction requires inherited production lock FD 9." >&2
  exit 1
fi
if [[ ! -s "$active_root/.env" ]]; then
  echo "The preserved host-owned monitoring .env must exist." >&2
  exit 1
fi
if [[ "$transaction_test_mode" != 1 && "$(stat -c '%a' "$active_root/.env")" != 600 ]]; then
  echo "The preserved host-owned monitoring .env must have mode 0600." >&2
  exit 1
fi

state_root="$active_root/.release-state"
intent="$state_root/intent.json"
releases_root="$active_root/releases"
manifests_root="$state_root/manifests"
install -d -m 0700 "$state_root" "$releases_root" "$manifests_root"
python3 "$state_tool" sync-dir --path "$active_root"

compose_at() {
  local root="$1"
  shift
  (cd "$root" && sudo docker compose --env-file "$active_root/.env" \
    --project-name telescan-monitoring "$@")
}

current_release_name() {
  [[ -L "$active_root/current" ]] || return 1
  local resolved
  resolved="$(realpath "$active_root/current")"
  [[ "$(dirname "$resolved")" == "$(realpath "$releases_root")" && -d "$resolved" ]] || return 1
  basename "$resolved"
}

sync_release() { python3 "$state_tool" sync-tree --path "$1"; }
switch_release() { python3 "$state_tool" switch --active-root "$active_root" --release "$1"; }
intent_field() { python3 "$state_tool" get --intent "$intent" --field "$1"; }

bootstrap_layout() {
  if [[ -L "$active_root/current" ]]; then
    current_release_name >/dev/null || {
      echo "The monitoring current release pointer is invalid." >&2
      return 1
    }
    return 0
  fi
  [[ ! -e "$active_root/current" ]] || return 1
  local name="bootstrap-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local target="$releases_root/$name"
  install -d -m 0755 "$target"
  rsync --archive --checksum \
    --exclude='.env' --exclude='.git/' --exclude='data/' \
    --exclude='releases/' --exclude='current' --exclude='.release-state/' \
    "$active_root/" "$target/"
  for required in compose.yaml ops/deploy.sh ops/check-stack.sh ops/check-telemetry.sh; do
    [[ -f "$target/$required" ]] || {
      echo "Legacy monitoring tree cannot be bootstrapped: missing $required." >&2
      return 1
    }
  done
  chmod +x "$target"/ops/*.sh
  ln -s ../../.env "$target/.env"
  sync_release "$target"
  switch_release "$name"
  echo "Bootstrapped immutable monitoring release: $name"
}

wait_full_health() {
  local release="$1"
  local deadline=$((SECONDS + 420))
  local remaining
  while (( SECONDS < deadline )); do
    remaining=$((deadline - SECONDS))
    if timeout --signal=TERM "$remaining" \
        bash -c 'cd "$1" && ./ops/check-stack.sh && ./ops/check-telemetry.sh' \
        monitoring-health "$release"; then
      return 0
    fi
    remaining=$((deadline - SECONDS))
    (( remaining <= 10 )) || sleep 10
  done
  compose_at "$release" ps || true
  compose_at "$release" logs --tail=100 || true
  return 1
}

cleanup_rollback_tags() {
  local manifest="$1"
  local service image_id configured rollback_ref
  while IFS=$'\t' read -r service image_id configured rollback_ref; do
    [[ -n "$rollback_ref" ]] || return 1
    sudo docker image rm "$rollback_ref" >/dev/null 2>&1 || true
  done <"$manifest"
}

arm_restart_policy() {
  local release="$1"
  local manifest="$2"
  local service image_id configured extra container
  while IFS=$'\t' read -r service image_id configured extra; do
    [[ -n "$service" ]] || return 1
    container="$(compose_at "$release" ps -q "$service")"
    [[ -n "$container" ]]
    sudo docker update --restart unless-stopped "$container" >/dev/null
  done <"$manifest"
}

recover_incomplete() {
  [[ -f "$intent" ]] || return 0
  local phase old_name new_name old_manifest_name new_manifest_name target_name
  local old_manifest new_manifest service image_id configured rollback_ref actual
  phase="$(intent_field phase)"
  old_name="$(intent_field old_release)"
  new_name="$(intent_field new_release)"
  old_manifest_name="$(intent_field old_images_manifest)"
  new_manifest_name="$(intent_field new_images_manifest)"
  old_manifest="$manifests_root/$old_manifest_name"
  new_manifest="$manifests_root/$new_manifest_name"
  [[ -s "$old_manifest" && -s "$new_manifest" ]]

  if [[ "$phase" == committed ]]; then
    target_name="$new_name"
    while IFS=$'\t' read -r service image_id configured extra; do
      [[ "$(sudo docker image inspect --format '{{.Id}}' "$configured")" == "$image_id" ]] || return 1
    done <"$new_manifest"
    switch_release "$target_name"
    TELESCAN_MONITORING_RESTART_OVERRIDE="$restart_override" \
      "$active_root/current/ops/deploy.sh"
    arm_restart_policy "$active_root/current" "$new_manifest"
  else
    target_name="$old_name"
    while IFS=$'\t' read -r service image_id configured rollback_ref; do
      [[ "$(sudo docker image inspect --format '{{.Id}}' "$rollback_ref")" == "$image_id" ]] || return 1
      if [[ "$configured" == *@sha256:* ]]; then
        [[ "$(sudo docker image inspect --format '{{.Id}}' "$configured")" == "$image_id" ]] || return 1
      else
        sudo docker image tag "$rollback_ref" "$configured"
      fi
    done <"$old_manifest"
    switch_release "$target_name"
    compose_at "$active_root/current" config --quiet </dev/null
    compose_at "$active_root/current" up -d --no-build --remove-orphans </dev/null
    wait_full_health "$active_root/current"
  fi
  python3 "$state_tool" clear --intent "$intent"
  cleanup_rollback_tags "$old_manifest"
  echo "Monitoring deterministic recovery passed: phase=$phase release=$target_name"
}

bootstrap_layout
recover_incomplete
if [[ "$mode" == recover ]]; then
  echo "Monitoring release state is coherent; no incomplete intent remains."
  exit 0
fi

if find "$release_root" -type f -name .env -print -quit | grep -q .; then
  echo "Incoming monitoring release unexpectedly contains .env." >&2
  exit 1
fi
for required in compose.yaml ops/deploy.sh ops/check-stack.sh ops/check-telemetry.sh \
    ops/release-state.py ops/compose-transaction-no-restart.yaml; do
  [[ -f "$release_root/$required" ]] || {
    echo "Incoming monitoring release is missing $required." >&2
    exit 1
  }
done

old_name="$(current_release_name)"
old_release="$releases_root/$old_name"
new_name="release-$(date -u +%Y%m%dT%H%M%SZ)-$$"
new_release="$releases_root/$new_name"
install -d -m 0755 "$new_release"
rsync --archive --checksum --delete \
  --exclude='.env' --exclude='.git/' --exclude='data/' \
  "$release_root/" "$new_release/"
chmod +x "$new_release"/ops/*.sh
ln -s ../../.env "$new_release/.env"
sync_release "$new_release"

compose_at "$old_release" config --quiet </dev/null
compose_at "$new_release" config --quiet </dev/null

old_manifest_name="old-images-$new_name.tsv"
new_manifest_name="new-images-$new_name.tsv"
old_manifest="$manifests_root/$old_manifest_name"
new_manifest="$manifests_root/$new_manifest_name"
install -m 0600 /dev/null "$old_manifest"
install -m 0600 /dev/null "$new_manifest"

while IFS= read -r service; do
  [[ -n "$service" ]] || continue
  container="$(compose_at "$old_release" ps -q "$service")"
  [[ -n "$container" ]]
  [[ "$(sudo docker inspect --format '{{.State.Running}}' "$container")" == true ]]
  image_id="$(sudo docker inspect --format '{{.Image}}' "$container")"
  configured="$(sudo docker inspect --format '{{.Config.Image}}' "$container")"
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ && -n "$configured" && \
     "$configured" != *$'\t'* && "$configured" != *$'\n'* ]]
  rollback_ref="telescan-monitoring-rollback:${new_name}-${service}"
  sudo docker image tag "$image_id" "$rollback_ref"
  [[ "$(sudo docker image inspect --format '{{.Id}}' "$rollback_ref")" == "$image_id" ]]
  printf '%s\t%s\t%s\t%s\n' "$service" "$image_id" "$configured" "$rollback_ref" >>"$old_manifest"
done < <(compose_at "$old_release" config --services)

compose_at "$new_release" pull </dev/null
while IFS= read -r service; do
  [[ -n "$service" ]] || continue
  configured="$(compose_at "$new_release" config --format json | python3 -c '
import json, sys
service = sys.argv[1]
value = json.load(sys.stdin).get("services", {}).get(service, {}).get("image", "")
if not isinstance(value, str) or not value:
    raise SystemExit(f"missing image for {service}")
print(value)
' "$service")"
  image_id="$(sudo docker image inspect --format '{{.Id}}' "$configured")"
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ && "$configured" != *$'\t'* ]]
  printf '%s\t%s\t%s\n' "$service" "$image_id" "$configured" >>"$new_manifest"
done < <(compose_at "$new_release" config --services)

[[ -s "$old_manifest" && -s "$new_manifest" ]]
python3 "$state_tool" sync-tree --path "$manifests_root"
python3 "$state_tool" write-intent \
  --intent "$intent" --kind monitoring --phase prepared \
  --old-release "$old_name" --new-release "$new_name" \
  --old-images-manifest "$old_manifest_name" \
  --new-images-manifest "$new_manifest_name"
transaction_started=true
transaction_complete=false

transaction_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$transaction_started" == true && "$transaction_complete" != true && -f "$intent" ]]; then
    echo "Interrupted or failed monitoring transaction; running durable recovery." >&2
    if ! recover_incomplete; then
      echo "CRITICAL: monitoring intent retained at $intent for deterministic retry." >&2
      status=1
    fi
  fi
  exit "$status"
}
trap transaction_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

killpoint() {
  if [[ "$transaction_test_mode" == 1 && "$1" == after-intent && \
        "${TELESCAN_MONITORING_TRANSACTION_KILLPOINT:-}" == outer-after-intent ]]; then
    kill -KILL "$PPID"
    kill -KILL "$$"
  fi
  if [[ "$transaction_test_mode" == 1 && \
        "${TELESCAN_MONITORING_TRANSACTION_KILLPOINT:-}" == "$1" ]]; then
    kill -KILL "$$"
  fi
}

killpoint after-intent
switch_release "$new_name"
killpoint after-pointer
python3 "$state_tool" update-intent --intent "$intent" --phase promoted
TELESCAN_MONITORING_RESTART_OVERRIDE="$restart_override" \
  "$active_root/current/ops/deploy.sh"

python3 "$state_tool" update-intent --intent "$intent" --phase committed
killpoint after-commit
arm_restart_policy "$active_root/current" "$new_manifest"
python3 "$state_tool" clear --intent "$intent"
cleanup_rollback_tags "$old_manifest"
transaction_complete=true
echo "Monitoring immutable release rollout and full telemetry verification passed: release=$new_name"

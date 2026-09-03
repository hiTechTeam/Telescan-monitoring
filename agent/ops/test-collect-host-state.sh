#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

temporary_root="$(mktemp -d)"
cleanup() {
  rm -r -- "$temporary_root"
}
trap cleanup EXIT

fake_bin="$temporary_root/bin"
output_dir="$temporary_root/output"
config_file="$temporary_root/agent.conf"
mkdir -p "$fake_bin" "$output_dir"

cat >"$config_file" <<'EOF'
TELESCAN_HOST=moscow
EXPECTED_CONTAINERS=
MONITORED_TIMERS=telescan-mongodb-backup.timer
MONITORED_SERVICES=telescan-mongodb-backup.service
MONITORED_WIREGUARD_INTERFACES=
EOF

cat >"$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == ps ]]; then
  exit 0
fi
exit 1
EOF

cat >"$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == is-active && "${3:-}" == telescan-mongodb-backup.timer ]]; then
  exit 0
fi
if [[ "${1:-}" != show ]]; then
  exit 1
fi
case "$*" in
  *telescan-mongodb-backup.timer*LastTriggerUSec*)
    printf 'Thu 2026-09-03 01:39:16 UTC\n'
    ;;
  *telescan-mongodb-backup.service*Result*)
    printf 'success\n'
    ;;
  *telescan-mongodb-backup.service*ExecMainExitTimestamp*)
    printf '\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"$fake_bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == +%s ]]; then
  printf '1788462000\n'
elif [[ "${1:-}" == '--date=Thu 2026-09-03 01:39:16 UTC' && "${2:-}" == +%s ]]; then
  printf '1788399556\n'
else
  exit 1
fi
EOF

cat >"$fake_bin/wg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$fake_bin"/*

PATH="$fake_bin:$PATH" \
TELESCAN_MONITORING_STATE_CONFIG_FILE="$config_file" \
TELESCAN_MONITORING_STATE_OUTPUT_DIR="$output_dir" \
  bash agent/ops/collect-host-state.sh

metrics="$output_dir/host-state.prom"
grep -q 'telescan_systemd_timer_active{unit="telescan-mongodb-backup.timer"} 1' "$metrics"
grep -q 'telescan_systemd_timer_last_trigger_timestamp_seconds{unit="telescan-mongodb-backup.timer"} 1788399556' "$metrics"
grep -q 'telescan_systemd_service_success{unit="telescan-mongodb-backup.service"} 1' "$metrics"
grep -q 'telescan_systemd_service_last_exit_timestamp_seconds{unit="telescan-mongodb-backup.service"} 0' "$metrics"

echo "Host-state timer timestamp collection passed."

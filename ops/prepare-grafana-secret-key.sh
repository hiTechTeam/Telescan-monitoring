#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat >&2 <<'EOF'
Fresh database:
  sudo ./ops/prepare-grafana-secret-key.sh --apply --confirm CREATE_GRAFANA_SECRET_KEY --fresh-install

Existing database, phase 1 (Grafana stopped and a consistent backup already made):
  sudo ./ops/prepare-grafana-secret-key.sh --apply --confirm PREPARE_GRAFANA_SECRET_MIGRATION --existing-install --backup /absolute/backup/grafana.db --acknowledge BACKUP_VERIFIED

Existing database, phase 2 (only after the pinned-version migration procedure succeeds):
  sudo ./ops/prepare-grafana-secret-key.sh --apply --confirm ATTEST_GRAFANA_SECRET_MIGRATION --existing-install --backup /absolute/backup/grafana.db --acknowledge BACKUP_VERIFIED
EOF
  exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

data_root="${MONITORING_DATA_ROOT:-}"
if [[ -z "$data_root" && -r "$repo_root/.env" ]]; then
  while IFS='=' read -r key value; do
    if [[ "$key" == MONITORING_DATA_ROOT ]]; then
      data_root="${value%$'\r'}"
      break
    fi
  done <"$repo_root/.env"
fi
data_root="${data_root:-/var/lib/telescan-monitoring}"
database="$data_root/grafana/grafana.db"
secret_dir="$data_root/secrets"
key_file="$secret_dir/grafana_secret_key"
marker_file="$secret_dir/grafana_secret_key_ready"

if [[ ! "$data_root" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Invalid MONITORING_DATA_ROOT." >&2
  exit 1
fi
if ! mountpoint -q "$data_root"; then
  echo "Monitoring data disk is not mounted at $data_root." >&2
  exit 1
fi

create_key() {
  if [[ -e "$key_file" ]]; then
    echo "Refusing to overwrite the existing Grafana secret key." >&2
    exit 1
  fi
  local tmp_key
  tmp_key="$(mktemp "$secret_dir/.grafana-secret-key.XXXXXX")"
  trap 'rm -f -- "$tmp_key"' RETURN
  openssl rand -hex 32 >"$tmp_key"
  install -o 472 -g 472 -m 0400 "$tmp_key" "$key_file"
  rm -f -- "$tmp_key"
  trap - RETURN
}

write_ready_marker() {
  local tmp_marker
  tmp_marker="$(mktemp "$secret_dir/.grafana-secret-key-ready.XXXXXX")"
  trap 'rm -f -- "$tmp_marker"' RETURN
  echo 'status=ready' >"$tmp_marker"
  install -o root -g root -m 0444 "$tmp_marker" "$marker_file"
  rm -f -- "$tmp_marker"
  trap - RETURN
}

install -d -o root -g root -m 0700 "$secret_dir"

if [[ $# -eq 4 && "$1" == --apply && "$2" == --confirm && \
      "$3" == CREATE_GRAFANA_SECRET_KEY && "$4" == --fresh-install ]]; then
  if [[ -s "$database" ]]; then
    echo "Existing Grafana database detected; the fresh-install path is forbidden." >&2
    exit 1
  fi
  create_key
  write_ready_marker
  "$repo_root/ops/check-grafana-secret-key.sh"
  echo "Fresh-install Grafana secret key is ready. The key was not printed."
  exit 0
fi

if [[ $# -eq 8 && "$1" == --apply && "$2" == --confirm && \
      "$4" == --existing-install && "$5" == --backup && \
      "$7" == --acknowledge ]]; then
  action="$3"
  backup="$6"
  # Require an exact acknowledgement, so accidental
  # invocations cannot prepare or attest an existing encrypted database.
  acknowledgement="$8"
  if [[ "$acknowledgement" != BACKUP_VERIFIED ]]; then
    usage
  fi
  if [[ ! "$backup" =~ ^/[A-Za-z0-9._/-]+$ || ! -f "$backup" || ! -s "$backup" ]]; then
    echo "A non-empty absolute Grafana database backup is required." >&2
    exit 1
  fi
  if [[ ! -s "$database" ]]; then
    echo "The existing-install path requires a non-empty live Grafana database." >&2
    exit 1
  fi
  if [[ "$backup" -ef "$database" ]]; then
    echo "The backup must not be the live Grafana database." >&2
    exit 1
  fi
  if docker inspect --format '{{.State.Running}}' telescan_grafana 2>/dev/null | grep -qx true; then
    echo "Stop Grafana before preparing or attesting database-key migration." >&2
    exit 1
  fi

  case "$action" in
    PREPARE_GRAFANA_SECRET_MIGRATION)
      create_key
      rm -f -- "$marker_file"
      echo "New key prepared, but the runtime guard remains closed. Follow the migration runbook."
      ;;
    ATTEST_GRAFANA_SECRET_MIGRATION)
      if [[ ! -s "$key_file" ]]; then
        echo "Prepared Grafana secret key is absent." >&2
        exit 1
      fi
      write_ready_marker
      "$repo_root/ops/check-grafana-secret-key.sh"
      echo "Migration readiness attested. Start Grafana with the guarded override, verify contact points, then run the Telegram drill."
      ;;
    *) usage ;;
  esac
  exit 0
fi

usage

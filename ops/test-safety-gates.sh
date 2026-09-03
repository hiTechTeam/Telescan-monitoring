#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

expect_rejected() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "Safety gate accepted an incomplete invocation: $name" >&2
    exit 1
  fi
}

expect_rejected telegram-drill bash ops/run-telegram-delivery-drill.sh
expect_rejected production-attestation bash ops/collect-production-attestation.sh
expect_rejected production-attestation-missing-exact-dns \
  bash ops/collect-production-attestation.sh \
    --read-only --confirm COLLECT_TELESCAN_PRODUCTION_ATTESTATION \
    --role monitoring
expect_rejected central-state-install bash ops/install-central-state-collector.sh
expect_rejected grafana-key-prepare bash ops/prepare-grafana-secret-key.sh
expect_rejected transactional-deploy bash ops/deploy-release-with-rollback.sh
expect_rejected release-supervisor bash ops/run-release-transaction.sh
expect_rejected release-recovery-install bash ops/install-release-recovery.sh
grep -q 'systemctl reset-failed' ops/install-release-recovery.sh
expect_rejected production-fixture-bypass \
  python3 ops/check-attestation-inventory.py \
    --role monitoring \
    --expected-api-ip 203.0.113.10 \
    --expected-main-ip 203.0.113.20 \
    --fixture tests/attestation/valid-monitoring.json
expect_rejected promql-pull-argument bash ops/test-promql.sh --unexpected
expect_rejected alloy-pull-argument bash ops/test-alloy-config.sh --unexpected
expect_rejected ingest-pull-argument bash ops/test-ingest-config.sh --unexpected
grep -q -- '--add-host prometheus:127.0.0.1' ops/test-ingest-config.sh
grep -q -- '--add-host loki:127.0.0.1' ops/test-ingest-config.sh
grep -q '^  group: monitoring-production$' .github/workflows/monitoring.yml
grep -q "github.ref == 'refs/heads/main'" .github/workflows/monitoring.yml
grep -q 'flock --exclusive --timeout 1800' .github/workflows/monitoring.yml
grep -q 'exec 9>/tmp/telescan-production-deploy.lock' .github/workflows/monitoring.yml
grep -q 'tar --extract --gzip --file=- --directory "$release_root"' \
  .github/workflows/monitoring.yml
grep -q 'run-release-transaction.sh' .github/workflows/monitoring.yml
if grep -Eq 'Upload configuration|rsync' .github/workflows/monitoring.yml; then
  echo "Monitoring workflow still mutates active configuration outside its transaction." >&2
  exit 1
fi
lock_line="$(grep -n 'flock --exclusive --timeout 1800 9' \
  .github/workflows/monitoring.yml | cut -d: -f1)"
extract_line="$(grep -n 'tar --extract --gzip --file=- --directory' \
  .github/workflows/monitoring.yml | cut -d: -f1)"
transaction_line="$(grep -n '"\$release_root/ops/run-release-transaction.sh"' \
  .github/workflows/monitoring.yml | cut -d: -f1)"
if [[ ! "$lock_line" =~ ^[0-9]+$ || ! "$extract_line" =~ ^[0-9]+$ || \
      ! "$transaction_line" =~ ^[0-9]+$ || \
      "$lock_line" -ge "$extract_line" || "$extract_line" -ge "$transaction_line" ]]; then
  echo "Monitoring lock must precede upload extraction and the release transaction." >&2
  exit 1
fi
grep -q 'rsync --archive --checksum --delete' ops/deploy-release-with-rollback.sh
grep -q 'trap transaction_exit EXIT' ops/deploy-release-with-rollback.sh
grep -q "trap 'exit 129' HUP" ops/deploy-release-with-rollback.sh
grep -q 'timeout --signal=TERM "$remaining"' ops/deploy-release-with-rollback.sh
grep -q './ops/check-telemetry.sh' ops/deploy-release-with-rollback.sh
grep -q 'old-images-' ops/deploy-release-with-rollback.sh
grep -q 'new-images-' ops/deploy-release-with-rollback.sh
grep -q 'telescan-monitoring-rollback:' ops/deploy-release-with-rollback.sh
grep -q 'switch_release "$new_name"' ops/deploy-release-with-rollback.sh
grep -q 'fsync_directory(root.parent)' ops/release-state.py
grep -q 'recovery-controller' ops/run-release-transaction.sh
grep -q 'PathExists=.*/intent.json' systemd/telescan-monitoring-release-recovery.path
grep -q '"$flock_bin" --nonblock 9' agent/ops/prune-docker-build-cache.sh
grep -q 'find "$transaction_root" -maxdepth 3 -type f -name active.json' \
  agent/ops/prune-docker-build-cache.sh
grep -q 'builder prune --all --force --filter until=24h' \
  agent/ops/prune-docker-build-cache.sh
grep -q 'OnUnitActiveSec=24h' \
  agent/systemd/telescan-docker-build-cache-prune.timer
grep -q 'ReadWritePaths=/run/docker.sock /tmp' \
  agent/systemd/telescan-docker-build-cache-prune.service

bash ops/test-attestation-inventory.sh >/dev/null
grep -q 'failures.extend(validate_container_bindings(containers, role))' \
  ops/check-attestation-inventory.py
grep -q 'extra-specific-public-listener' tests/attestation/negative-cases.json
grep -q 'extra-container-specific-public-binding' tests/attestation/negative-cases.json
grep -q 'remapped-sensitive-container-port' tests/attestation/negative-cases.json
grep -q 'unexpected-unbound-api-container' tests/attestation/negative-cases.json
bash ops/test-monitoring-transaction.sh >/dev/null
bash ops/test-recovery-unit-lock.sh >/dev/null

# Prove that a parseable certificate is not enough: the endpoint helper must
# reject a self-signed chain even when hostname and certificate CN match.
temporary_root="$(mktemp -d)"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -r -- "$temporary_root"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes \
  -subj '/CN=invalid.test' \
  -days 1 \
  -keyout "$temporary_root/key.pem" \
  -out "$temporary_root/cert.pem" \
  >/dev/null 2>&1
openssl s_server -quiet \
  -accept 19443 \
  -cert "$temporary_root/cert.pem" \
  -key "$temporary_root/key.pem" \
  >"$temporary_root/server.log" 2>&1 &
server_pid=$!
sleep 1
if ! kill -0 "$server_pid" 2>/dev/null; then
  echo "Could not start the local negative TLS fixture." >&2
  sed -n '1,20p' "$temporary_root/server.log" >&2
  exit 1
fi
expect_rejected self-signed-tls \
  bash ops/check-tls-endpoint.sh invalid.test 19443 127.0.0.1

echo "Runtime confirmation gates and negative TLS verification passed."

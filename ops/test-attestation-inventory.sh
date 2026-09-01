#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

checker=ops/check-attestation-inventory.py
fixture_dir=tests/attestation
expected_api_ip=203.0.113.10
expected_main_ip=203.0.113.20
temporary_root="$(mktemp -d)"
trap 'rm -r -- "$temporary_root"' EXIT

run_fixture() {
  local role="$1"
  local fixture="$2"
  shift 2
  TELESCAN_ATTESTATION_TEST_MODE=1 python3 "$checker" \
    --role "$role" \
    --expected-api-ip "$expected_api_ip" \
    --expected-main-ip "$expected_main_ip" \
    --fixture "$fixture" \
    "$@"
}

moscow_expected_ids=(
  --expected-image-id telescan-nginx=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --expected-image-id telescan_api=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  --expected-image-id mongo_db=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  --expected-image-id telescan_admin_bot=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  --expected-image-id service/telescan-bot-app=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
)
eu_expected_ids=(
  --expected-image-id telescan_relay=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
)

run_fixture monitoring "$fixture_dir/valid-monitoring.json" >/dev/null
run_fixture moscow "$fixture_dir/valid-moscow.json" "${moscow_expected_ids[@]}" >/dev/null
run_fixture eu "$fixture_dir/valid-eu.json" "${eu_expected_ids[@]}" >/dev/null

if TELESCAN_ATTESTATION_TEST_MODE=1 python3 "$checker" \
    --role monitoring \
    --expected-api-ip "$expected_api_ip" \
    --expected-main-ip "$expected_main_ip" \
    --fixture "$fixture_dir/valid-monitoring.json" \
    --expected-image-id unexpected=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >/dev/null 2>&1; then
  echo "Monitoring inventory accepted an unexpected image identity." >&2
  exit 1
fi

manifest="$(python3 "$fixture_dir/materialize-negative-fixtures.py" \
  "$fixture_dir" "$temporary_root")"
while IFS=$'\t' read -r name role fixture; do
  output_file="$temporary_root/$name.out"
  case "$role" in
    eu)
      if run_fixture "$role" "$fixture" "${eu_expected_ids[@]}" >"$output_file" 2>&1; then
        echo "Negative attestation fixture unexpectedly passed: $name" >&2
        exit 1
      fi
      ;;
    moscow)
      if run_fixture "$role" "$fixture" "${moscow_expected_ids[@]}" >"$output_file" 2>&1; then
        echo "Negative attestation fixture unexpectedly passed: $name" >&2
        exit 1
      fi
      ;;
    monitoring)
      if run_fixture "$role" "$fixture" >"$output_file" 2>&1; then
        echo "Negative attestation fixture unexpectedly passed: $name" >&2
        exit 1
      fi
      ;;
    *)
      echo "Unknown negative attestation fixture role: $role" >&2
      exit 1
      ;;
  esac
  case "$name" in
    extra-specific-public-listener)
      grep -q 'sensitive listener is outside the moscow allowlist' "$output_file"
      ;;
    extra-container-specific-public-binding)
      grep -q 'Docker port binding is outside the exact moscow allowlist' "$output_file"
      ;;
    remapped-sensitive-container-port)
      grep -q 'container=27017/tcp host=0.0.0.0:12345' "$output_file"
      ;;
    unexpected-unbound-api-container)
      grep -q 'unexpected running container outside the exact moscow inventory' "$output_file"
      ;;
  esac
  printf 'Negative attestation fixture rejected: %s\n' "$name"
done < <(
  MANIFEST="$manifest" python3 -c '
import json, os
for item in json.loads(os.environ["MANIFEST"]):
    print(item["name"], item["role"], item["path"], sep="\t")
'
)

echo "All role inventories passed and all negative attestation fixtures were rejected."

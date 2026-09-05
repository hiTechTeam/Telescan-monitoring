# Production attestation

Run the read-only collector separately on monitoring, Moscow and EU:

```sh
sudo ./ops/collect-production-attestation.sh \
  --read-only --confirm COLLECT_TELESCAN_PRODUCTION_ATTESTATION \
  --role ROLE \
  --expected-api-ip EU_IPV4 \
  --expected-main-ip MOSCOW_IPV4 >attestation-ROLE.txt
```

Moscow and EU also require approved `--expected-image-id NAME=SHA256` values
from the release record. Do not copy current host values immediately before the
check; that makes verification circular.

The collector checks exact DNS, listeners, containers, image identities,
firewall, WireGuard, TLS, SSH, mounts and timers without reading secrets or
payloads. Any non-zero result fails attestation. Attach the provider firewall
export because guest checks cannot prove cloud-edge policy.

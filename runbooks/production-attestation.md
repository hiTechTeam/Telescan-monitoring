# Production attestation

`ops/collect-production-attestation.sh` is a read-only, root-level evidence
collector. It never reads `.env`, container environments, WireGuard private
keys, certificate private keys, application payloads, or Grafana secrets. Its
stdout is suitable for redirecting to an access-controlled audit artifact.

Run it independently on each production host, substituting the approved IPs
and locally built image IDs from the approved release record. DNS comparison
is exact: a missing or additional A record fails.

```sh
sudo ./ops/collect-production-attestation.sh \
  --read-only --confirm COLLECT_TELESCAN_PRODUCTION_ATTESTATION \
  --role monitoring \
  --expected-api-ip <EU_PUBLIC_IPV4> \
  --expected-main-ip <MOSCOW_PUBLIC_IPV4> \
  >attestation-monitoring.txt
```

Repeat with `--role moscow` and `--role eu`. Store all three artifacts with
the same UTC change/evidence ID. A non-zero exit is a failed attestation, not a
warning to waive silently.

The monitoring role uses pinned repository digests and therefore needs no
`--expected-image-id`. Moscow additionally requires the exact release-record
IDs for `telescan-nginx`, `telescan_api`, `mongo_db`, `telescan_admin_bot`, and
the Compose service `telescan-bot-app`:

```sh
sudo ./ops/collect-production-attestation.sh \
  --read-only --confirm COLLECT_TELESCAN_PRODUCTION_ATTESTATION \
  --role moscow \
  --expected-api-ip <EU_PUBLIC_IPV4> \
  --expected-main-ip <MOSCOW_PUBLIC_IPV4> \
  --expected-image-id telescan-nginx=<RELEASE_SHA256_ID> \
  --expected-image-id telescan_api=<RELEASE_SHA256_ID> \
  --expected-image-id mongo_db=<RELEASE_SHA256_ID> \
  --expected-image-id telescan_admin_bot=<RELEASE_SHA256_ID> \
  --expected-image-id service/telescan-bot-app=<RELEASE_SHA256_ID>
```

EU additionally requires
`--expected-image-id telescan_relay=<RELEASE_SHA256_ID>`. Obtain these values
from signed or approved deploy evidence, not by copying the current value from
the host immediately before attestation; the latter would make the comparison
circular.

The evidence includes exact DNS A records, interface/listener state, UFW plus
nftables/iptables policy, Docker port publication, mandatory role containers,
configured image references, immutable image IDs and pinned repository
digests, WireGuard public peer state and handshakes, externally verified TLS
certificates, effective `sshd -T` policy, mount/capacity/inode state, and
Telescan timers. For ports 3000, 8000, 8081, 9090, 3100, 19090, 13100, 27017,
and 8888 it enforces the exact role-specific address/protocol allowlist—not
only a wildcard check. Every `ss` listener and every port binding from every
running Docker container is checked, including containers outside the required
inventory. A specific public-IP bind therefore fails even when the required
loopback/private bind is also present or Docker userland-proxy is disabled.
The running-container inventory is also exact: every container must match one
approved role/name/service/image identity. An unbound rogue container, including
a second API process on the Moscow Docker network, fails attestation.

Before accepting the evidence, compare it with the approved topology:

- EU: public TCP 80/443, private `10.78.0.3:8888`, WireGuard UDP 51820,
  `telescan_relay` plus the pinned Alloy agent, `wg0` and `wg-monitor`; no
  telemetry/database/API port on a public address.
- Moscow: public TCP 80/443, private `10.77.0.1:8081`, loopback API 8000 and
  MongoDB 27017, the edge/API/database/two bot/Alloy containers, `wg0` and
  `wg-monitor`; no private service on a wildcard address.
- Monitoring: loopback Grafana 3000; full Prometheus/Loki APIs on loopback
  after the staged migration; write-only ingress on `10.78.0.1:19090` and
  `10.78.0.1:13100`; WireGuard UDP 51821; five pinned stack containers; only
  `wg-monitor` is required.

The script cannot prove a cloud security group that is not represented in the
guest firewall. Attach a provider-side security-group export or screenshot to
the same evidence ID.

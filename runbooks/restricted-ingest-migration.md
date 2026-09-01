# Restrict Prometheus and Loki ingestion APIs

The target state exposes only two write routes to the two production peers:

- `10.78.0.1:19090/api/v1/write` -> Prometheus;
- `10.78.0.1:13100/loki/api/v1/push` -> Loki.

The nginx gateway permits source addresses `10.78.0.2` and `10.78.0.3`, permits
only `POST` on the exact paths, and returns `404` for query, admin, lifecycle,
label, and all other APIs. Prometheus and Loki themselves then bind to loopback.

This is deliberately staged. Do not combine the phases in one change window.

## Phase 0: evidence and rollback inputs

1. Save the current `.env` permissions and the values of only
   `COMPOSE_PROFILES` and `INGEST_BIND_ADDRESS`; do not copy the whole file into
   a ticket.
2. Run `ops/check-stack.sh`, `ops/check-telemetry.sh`, and the production
   attestation on all three hosts.
3. Confirm both agent repositories and their previous `.env` files are locally
   recoverable on the hosts.

## Phase 1: parallel write-only ingress

Set `COMPOSE_PROFILES=restricted-ingest` while leaving
`INGEST_BIND_ADDRESS=10.78.0.1`, then run `ops/deploy.sh`. Verify:

```sh
./ops/check-restricted-ingest.sh
./ops/check-telemetry.sh
```

At this point the legacy direct ports and the new gateway coexist. Rollback is
only removing `restricted-ingest` from `COMPOSE_PROFILES` and redeploying.

## Phase 2: canary agents

On one production peer, run its existing install command with `restricted` as
the seventh argument. The installer first proves that the full query APIs are
absent and that invalid write payloads reach (and are rejected by) both
upstreams. Wait at least ten minutes and run the central full telemetry check.
Then repeat for the second peer.

Example shape (retain the host's approved lists exactly):

```sh
sudo ./agent/ops/install.sh \
  HOST EXPECTED_CONTAINERS MONITORED_TIMERS MONITORED_SERVICES \
  MONITORED_WIREGUARD_INTERFACES 224m restricted
```

Rollback an agent by rerunning the same command with `legacy`.

## Phase 3: close the full APIs

Only after both peers have remained healthy, set
`INGEST_BIND_ADDRESS=127.0.0.1` and keep
`COMPOSE_PROFILES=restricted-ingest`. Run `ops/deploy.sh`; it must complete its
full telemetry check. From each peer, verify the old ports 9090/3100 are no
longer reachable and rerun `agent/ops/check-restricted-ingest.sh`.

Collect three-host attestations. The central evidence must show loopback-only
9090/3100 and `10.78.0.1`-only 19090/13100. Retain provider firewall rules as a
second layer; do not expose any telemetry port on the public interface.

Rollback in reverse order: restore `INGEST_BIND_ADDRESS=10.78.0.1`, deploy,
switch both agents to `legacy`, verify full telemetry, and only then disable
the gateway profile.

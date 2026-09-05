# Restricted telemetry ingestion

Target write-only routes are `10.78.0.1:19090/api/v1/write` and
`10.78.0.1:13100/loki/api/v1/push`, available only to EU and Moscow.

1. Save current non-secret mode values and run stack, telemetry and host
   attestations.
2. Enable `COMPOSE_PROFILES=restricted-ingest` while leaving legacy ingest
   bound to `10.78.0.1`; deploy and verify both paths.
3. Move one agent to `restricted`, observe for ten minutes, then move the other.
4. Bind legacy Prometheus/Loki APIs to `127.0.0.1`, deploy, confirm old peer
   ports are closed and collect attestations.

Rollback in reverse: restore the legacy bind, deploy, return both agents to
`legacy`, verify telemetry, then disable the gateway profile.

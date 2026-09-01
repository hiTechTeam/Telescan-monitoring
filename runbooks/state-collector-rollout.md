# State-collector freshness rollout

Every successful `collect-host-state.sh` run now emits
`telescan_monitoring_state_last_success_timestamp_seconds`. The recording rule
alerts when an emitted timestamp is older than 180 seconds. Missing-series
alerts are staged behind `REQUIRE_STATE_FRESHNESS_METRICS` so repository deploy
order cannot create a false incident.

1. Update the Moscow and EU agents with their existing `agent/ops/install.sh`
   arguments. Use `legacy` or `restricted` according to the ingress migration
   phase.
2. On the central host, install its collector from an interactive maintenance
   session:

```sh
sudo ./ops/install-central-state-collector.sh \
  --apply --confirm INSTALL_CENTRAL_STATE_COLLECTOR
```

3. Query
   `max by (host) (telescan_monitoring_state_last_success_timestamp_seconds)`
   and require exactly `monitoring`, `moscow`, and `eu`, all less than three
   minutes old.
4. Set `REQUIRE_STATE_FRESHNESS_METRICS=true` in the central host `.env` and run
   `ops/deploy.sh`. This writes the enforcement control metric atomically and
   makes both full telemetry verification and missing-series alerts fail
   closed.

`true` is a mandatory handoff condition, not an optional steady-state choice.
The default `false` exists only to make the two-agent and central-collector
rollout order safe; while it remains false, a missing collector series can be
masked by an otherwise healthy Alloy process.

Rollback is setting the flag to `false` and redeploying. Stale timestamps that
already exist remain alertable; the flag suppresses only missing-series alerts
during a controlled rollout.

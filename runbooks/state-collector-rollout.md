# State-collector freshness rollout

1. Update EU and Moscow agents with their existing installer arguments.
2. Install the central collector:

```sh
sudo ./ops/install-central-state-collector.sh \
  --apply --confirm INSTALL_CENTRAL_STATE_COLLECTOR
```

3. Require fresh `telescan_monitoring_state_last_success_timestamp_seconds` for
   `monitoring`, `moscow` and `eu`.
4. Set `REQUIRE_STATE_FRESHNESS_METRICS=true` and deploy the central stack.

Use `false` only during a controlled rollout; it can hide a missing collector.

# Telegram alert-delivery drill

This drill proves the complete path, not merely HTTPS reachability:

`Alloy textfile -> Prometheus -> Grafana rule -> notification policy -> EU
domain-restricted proxy -> Telegram -> operator`, followed by the resolved
notification on the same path.

Prerequisites:

- `ops/deploy.sh` and `ops/check-telemetry.sh` pass;
- the host-managed `telegram-telescan` contact point is healthy;
- the operator can view the intended Telegram chat;
- no other drill metric file exists.

Run from an interactive maintenance session with a unique change/evidence ID:

```sh
sudo ./ops/run-telegram-delivery-drill.sh \
  --apply --confirm SEND_TELESCAN_TELEGRAM_DRILL \
  --drill-id CHG-YYYYMMDD-NNN
```

The script never reads the bot token or chat ID. It verifies the metric appears
and disappears in Prometheus, and requires the operator to type exact
attestations after observing both the FIRING and RESOLVED Telegram messages
with the same drill ID. It then appends timestamps and the local operator name
to `/var/lib/telescan-monitoring/drills/telegram-delivery.log` with mode 0600.
Each operator acknowledgement is bounded to ten minutes; timeout or disconnect
fails the drill and removes the synthetic metric.

An interrupt removes the drill metric. Absence of either Telegram message is a
failed drill; capture Grafana logs and the EU proxy status, but do not record a
successful evidence entry manually.

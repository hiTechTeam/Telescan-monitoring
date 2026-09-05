# Telegram alert-delivery drill

After stack and telemetry checks pass, run from an interactive session:

```sh
sudo ./ops/run-telegram-delivery-drill.sh \
  --apply --confirm SEND_TELESCAN_TELEGRAM_DRILL \
  --drill-id CHG-YYYYMMDD-NNN
```

Confirm both FIRING and RESOLVED messages with the same ID. The script does not
read the bot token/chat ID and removes its synthetic metric on failure or
interrupt. Missing either message is a failed drill.

# Grafana secret-key migration

Never change `GF_SECURITY_SECRET_KEY` directly on an existing Grafana database.
It can make encrypted data unreadable.

For a fresh database:

```sh
sudo ./ops/prepare-grafana-secret-key.sh \
  --apply --confirm CREATE_GRAFANA_SECRET_KEY --fresh-install
```

For an existing database: stop Grafana, take and checksum a consistent offline
`grafana.db` backup, rehearse the pinned Grafana migration against a copy, then
run the guarded `PREPARE_GRAFANA_SECRET_MIGRATION` and
`ATTEST_GRAFANA_SECRET_MIGRATION` modes with the verified backup path. Enable
`compose.grafana-secret-key.yaml`, deploy, verify login/contact points and run
the Telegram delivery drill.

Rollback by stopping Grafana and restoring the previous database, key and
Compose selection. Keep the backup until the observation window ends.

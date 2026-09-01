# Grafana secret-key guard and migration

`compose.grafana-secret-key.yaml` is opt-in. The default deployment is left
unchanged so an existing encrypted Grafana database cannot be made unreadable
by an ordinary deploy. When enabled, Grafana refuses to start unless both a
strictly permissioned 64-hex-character key and a root-owned readiness marker
are mounted.

## Fresh database

Before Grafana creates `grafana.db`, run:

```sh
sudo ./ops/prepare-grafana-secret-key.sh \
  --apply --confirm CREATE_GRAFANA_SECRET_KEY --fresh-install
```

Then set `COMPOSE_FILE=compose.yaml:compose.grafana-secret-key.yaml`, run
`ops/deploy.sh`, configure the Telegram contact point, and complete the full
delivery drill. The command never prints key material.

## Existing database

Changing `GF_SECURITY_SECRET_KEY` directly can make encrypted contact-point and
data-source fields unreadable. Treat this as a database migration:

1. Schedule maintenance and capture a passing telemetry/drill baseline.
2. Stop Grafana and take a consistent offline copy of `grafana.db` outside the
   live data path. Record its checksum in the restricted change record.
3. Rehearse the pinned Grafana version against a copy of the database. Follow
   Grafana's version-matched database-encryption procedure; validate the exact
   `grafana cli admin secrets-migration` subcommands in the pinned image before
   using them. Do not guess a key-rotation command on production.
4. With Grafana still stopped and the verified backup present, prepare the new
   host key (the runtime marker remains closed):

```sh
sudo ./ops/prepare-grafana-secret-key.sh \
  --apply --confirm PREPARE_GRAFANA_SECRET_MIGRATION \
  --existing-install --backup /absolute/backup/grafana.db \
  --acknowledge BACKUP_VERIFIED
```

5. Perform the rehearsed migration or a reviewed clean-database rebuild. Test
   decryption/contact-point behavior against the copy first. Only after the
   production database step succeeds, attest readiness while Grafana remains
   stopped:

```sh
sudo ./ops/prepare-grafana-secret-key.sh \
  --apply --confirm ATTEST_GRAFANA_SECRET_MIGRATION \
  --existing-install --backup /absolute/backup/grafana.db \
  --acknowledge BACKUP_VERIFIED
```

6. Add the override to `COMPOSE_FILE`, run `ops/deploy.sh`, verify login and all
   contact points, and run the Telegram firing/resolved drill.

Rollback means stopping Grafana, restoring the consistent database backup,
restoring the previous Compose-file selection and previous key configuration,
then starting and verifying Grafana. Do not delete the new key or the backup
until the observation window and audit handoff are complete.

The relevant upstream operational guidance is
<https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-database-encryption/>
and the SQLite backup requirement is
<https://grafana.com/docs/grafana/latest/administration/back-up-grafana/>.

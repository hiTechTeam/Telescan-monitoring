# Telescan Monitoring

Private Grafana, Prometheus, Loki and Alloy stack. Runtime secrets and telemetry
stay on the hosts; container images are digest-pinned.

## Layout

- Central host: Grafana/Prometheus/Loki/Alloy and data at
  `/var/lib/telescan-monitoring`.
- EU and Moscow: lightweight Alloy agents over `wg-monitor`.
- Telegram alerts: restricted Tinyproxy on EU.
- Grafana is loopback-only and accessed through SSH port forwarding.

## Deploy and check

```sh
./ops/deploy.sh
./ops/check-stack.sh
./ops/check-telemetry.sh
```

Protected `main` deploys immutable releases with rollback. Host `.env`, data and
WireGuard keys remain outside releases.

Install/update a production agent with its existing host-specific lists:

```sh
sudo ./agent/ops/install.sh \
  HOST 'EXPECTED_CONTAINERS' 'MONITORED_TIMERS' 'MONITORED_SERVICES' \
  'MONITORED_WIREGUARD_INTERFACES' 224m legacy
```

Change `legacy` only through the staged ingest runbook. Procedures live in
[`runbooks/`](runbooks/).

## Grafana access

```sh
ssh -N -L 3000:127.0.0.1:3000 ubuntu@monitoring-host
```

Open `http://127.0.0.1:3000`; the admin password stays on the data disk.

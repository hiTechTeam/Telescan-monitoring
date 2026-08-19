# Telescan Monitoring

Private infrastructure-as-code for the Telescan observability stack.

The MVP stack runs Grafana, Prometheus, monolithic Loki, and Grafana Alloy on
a dedicated Yandex Cloud VM. Runtime secrets and telemetry data are owned by
the host and are never committed to Git.

## Architecture

- Grafana provides dashboards and alerting.
- Prometheus stores metrics for 15 days, capped at 10 GB.
- Loki stores logs for 7 days.
- Alloy collects central-host metrics, Docker logs, and external HTTP probes.
- Grafana binds to loopback. Prometheus and Loki bind only to the private
  monitoring interface; none of the three is a public service.
- Production hosts send telemetry over a dedicated `wg-monitor` WireGuard
  network. Ingestion ports bind only to `10.78.0.1` and are not public.
- A lightweight Alloy agent on each production host exports host metrics,
  Docker logs, expected-container state, systemd timer results, and WireGuard
  handshake timestamps. Application containers are not modified.

All container images are pinned by both release tag and immutable SHA-256
digest in `compose.yaml`.

## Central host

The data disk is mounted at `/var/lib/telescan-monitoring`. The repository is
deployed to `/home/ubuntu/telescan-monitoring`.

Initial bootstrap:

```sh
sudo ./ops/bootstrap-storage.sh /dev/disk/by-id/<data-disk>
sudo ./ops/bootstrap-docker.sh
./ops/deploy.sh
```

`bootstrap-storage.sh` intentionally refuses to format a mounted disk, a disk
with an existing filesystem or signature, or a disk smaller than 60 GiB.

## Access Grafana

Create an SSH tunnel from an administrator workstation:

```sh
ssh -N -L 3000:127.0.0.1:3000 ubuntu@monitoring-host
```

Then open `http://127.0.0.1:3000`. The initial user is `admin`; its generated
password exists only on the host at:

```text
/var/lib/telescan-monitoring/secrets/grafana_admin_password
```

Do not copy that file into the repository.

## CI/CD

Pull requests and pushes to `main` validate shell, YAML, JSON, and Docker
Compose syntax. A manual `workflow_dispatch` runs the same validation and then
deploys through SSH. The repository must define these Actions secrets:

- `MONITORING_SSH_KEY`
- `MONITORING_KNOWN_HOSTS`

And these Actions variables:

- `MONITORING_HOST`
- `MONITORING_USER`

The deploy key is independent from an administrator's local SSH key.

Until both Actions secrets are configured, validation runs automatically but
production deployment remains an explicit administrator operation. Never put
a private SSH key in the repository.

## Production agents

The monitoring network uses addresses documented in `network/README.md`:

- central monitoring: `10.78.0.1`;
- Moscow origin: `10.78.0.2`;
- EU relay: `10.78.0.3`.

Install or update an agent from the repository root on the relevant host:

```sh
sudo ./agent/ops/install.sh \
  HOST \
  'EXPECTED_CONTAINERS' \
  'MONITORED_TIMERS' \
  'MONITORED_SERVICES' \
  'MONITORED_WIREGUARD_INTERFACES' \
  224m
```

The final argument is the Alloy memory limit. Runtime `.env` files and all
WireGuard private keys remain host-owned and ignored by Git.

## Dashboards and alerting

Grafana provisions two read-only dashboards:

- `Telescan Overview` for public endpoint status, response times, and logs;
- `Telescan Infrastructure` for production host, container, timer, backup,
  disk, memory, CPU, and WireGuard state.

Core alert rules are provisioned from Git and evaluated inside Grafana. They
cover endpoint failures, missing telemetry, stopped or unhealthy containers,
inactive timers, failed or stale MongoDB backups, stale WireGuard handshakes,
and host resource pressure. A notification contact point is intentionally a
host-side secret and must be configured separately.

## Verification

Run the idempotent deploy and readiness checks:

```sh
./ops/deploy.sh
./ops/check-stack.sh
./ops/check-telemetry.sh
```

Expected result: Grafana, Prometheus, and Loki pass readiness; Alloy remains
running; all central targets show `up = 1`; external probes show
`probe_success = 1`; and Docker logs are queryable in Loki.

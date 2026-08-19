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
- Grafana, Prometheus, and Loki bind to loopback and are not public services.
- Production hosts will send telemetry over a dedicated private WireGuard
  network; their ingestion ports must not be opened to the public internet.

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

## Verification

Run the idempotent deploy and readiness checks:

```sh
./ops/deploy.sh
./ops/check-stack.sh
```

Expected result: Grafana, Prometheus, and Loki pass readiness; Alloy remains
running; all central targets show `up = 1`; external probes show
`probe_success = 1`; and Docker logs are queryable in Loki.

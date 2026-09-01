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
  monitoring interface during the staged migration and then to loopback; none
  of the three is a public service. The target remote-write path is an
  allow-listed nginx gateway exposing only the two exact write endpoints.
- Production hosts send telemetry over a dedicated `wg-monitor` WireGuard
  network. Ingestion ports bind only to `10.78.0.1` and are not public.
- A lightweight Alloy agent on each production host exports host metrics,
  Docker logs, expected-container state, systemd timer results, and WireGuard
  handshake timestamps. Application containers are not modified.
- Grafana reaches Telegram through a domain-restricted HTTPS proxy on the EU
  host because the Telegram Bot API is unreachable from the Yandex network.

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
Before enabling CI rollout, install the boot and online release-recovery units
from an interactive maintenance session:

```sh
bash ops/install-release-recovery.sh \
  --apply --confirm APPLY_MONITORING_RELEASE_RECOVERY_UNIT
```

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

Pull requests and pushes to `main` validate shell, YAML, JSON, Docker Compose,
Prometheus rules, restricted-ingress nginx, and both Alloy configurations.
After validation succeeds, every push to `main` streams the release to the
central host only after the host production lock is held. The remote transaction
creates a fully-fsynced immutable release and old/new image manifests, protects
all previous images, and promotes one atomic `current` pointer. Candidate
containers use `restart: no` until full stack and production telemetry checks
pass and the commit is durable. Failure restores the previous pointer/image set
and performs a bounded full-health check; an online path watcher recovers even
if the outer SSH session disappears. A manual `workflow_dispatch` can repeat
the same deployment without a new commit. See
`runbooks/transactional-deploy.md`.

The `production` GitHub environment defines these Actions secrets:

- `MONITORING_SSH_KEY`
- `MONITORING_KNOWN_HOSTS`

The repository defines these Actions variables:

- `MONITORING_HOST`
- `MONITORING_USER`

The deploy key is independent from an administrator's local SSH key and exists
only in the GitHub environment secret and the host's `authorized_keys`. Never
put a private SSH key in the repository.

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

The sixth argument is the Alloy memory limit. An optional seventh argument is
`legacy` or `restricted`; use only the staged procedure in
`runbooks/restricted-ingest-migration.md` to change it. Runtime `.env` files and
all WireGuard private keys remain host-owned and ignored by Git.

## Dashboards and alerting

Grafana provisions two read-only dashboards:

- `Telescan Overview` for public endpoint status, response times, and logs;
- `Telescan Infrastructure` for production host, container, timer, backup,
  disk, memory, CPU, and WireGuard state.

Core alert rules are provisioned from Git and evaluated inside Grafana. They
cover endpoint failures, missing telemetry, stopped or unhealthy containers,
inactive timers, failed or stale MongoDB backups, stale WireGuard handshakes,
state-collector freshness, the monitoring data disk and inodes, Loki ingestion
growth, and host resource pressure. The missing-host recording rule has unit
cases for all, one, two, and all three hosts missing. A notification contact
point is intentionally a host-side secret and must be configured separately.

The provisioned notification policy routes alerts labeled `service=telescan`
to the host-managed contact point named `telegram-telescan`. Its Bot API token
and chat ID are stored only in Grafana's encrypted database on the data disk.

Use `runbooks/telegram-delivery-drill.md` for a verifiable firing/resolved
delivery test. Grafana secret-key adoption is opt-in and guarded by
`runbooks/grafana-secret-key-migration.md`; never enable its Compose override
directly against an existing database.

## Telegram egress

The EU host runs Tinyproxy on `10.78.0.3:8888`. It accepts clients only from
the central monitoring address `10.78.0.1`, permits only HTTPS CONNECT to port
443, and whitelists only `api.telegram.org`. UFW does not expose the proxy on
the public interface.

Install or update it on the EU host:

```sh
sudo ./egress/ops/install.sh
```

Grafana receives the proxy address through `HTTPS_PROXY`; internal Prometheus,
Loki, loopback, and monitoring-network traffic is excluded with `NO_PROXY`.

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

Operational rollout and evidence procedures live under `runbooks/`, including
state freshness, restricted ingestion, Telegram delivery, Grafana encryption,
and three-host read-only production attestation.

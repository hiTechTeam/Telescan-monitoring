# Transactional monitoring deployment

The GitHub workflow streams a secret-free archive over SSH. The remote shell
first acquires inherited FD 9 on `/tmp/telescan-production-deploy.lock` with an
1800-second timeout, then extracts the archive to a unique path under
`/home/ubuntu`. No active release is changed outside that lock.

CI invokes the external supervisor:

```sh
"$release_root/ops/run-release-transaction.sh" \
  --apply --confirm DEPLOY_MONITORING_RELEASE_WITH_ROLLBACK \
  --active-root /home/ubuntu/telescan-monitoring \
  --release-root "$release_root"
```

## Durable host layout

- `/home/ubuntu/telescan-monitoring/.env` is host-owned, mode `0600`, and never
  copied into a release; each release has a relative symlink to it.
- `releases/<release-id>` contains immutable, fully-fsynced repository content.
- `current` is atomically replaced and always resolves to one release.
- `.release-state/intent.json` records the phase and old/new release plus image
  manifest names.
- `.release-state/manifests/` contains fsynced exact service, configured
  reference, immutable image ID, and protected rollback-reference records.
- `.release-state/recovery-controller` atomically selects a fully-fsynced,
  versioned controller that does not depend on partially uploaded active files.

Before publishing intent, the transaction requires every enabled old service to
have a running container and protects each old image as
`telescan-monitoring-rollback:<release>-<service>`. It pulls the candidate's
digest-pinned images and records their exact IDs. Only after both manifests and
the immutable release are durable is intent published.

`current` then switches once. `ops/deploy.sh` receives the guarded restart
override, so candidate containers cannot restart automatically while
uncommitted. It must complete stack health and the full
`ops/check-telemetry.sh` gate. After a durable committed phase, restart policies
are armed to `unless-stopped`; intent is durably cleared before rollback tags
are removed.

## Failure and independent recovery

For every non-committed phase, recovery verifies the protected old-image IDs,
restores any mutable configured references, switches `current` to the prior
release, recreates with `--no-build`, and requires bounded stack plus full
telemetry health. A committed-but-interrupted phase instead verifies the exact
candidate manifest, finishes the candidate, and arms restart policies. Missing
images, a bad pointer, or failed health leaves the durable intent for manual
diagnosis; never delete it or prune rollback tags by hand.

The external supervisor recovers a killed child before returning. If the whole
SSH/session supervisor dies, `telescan-monitoring-release-recovery.path`
observes the intent and starts the recovery service. The service opens its own
FD 9, fails closed if `flock` fails, waits at most 1800 seconds for the lock, and
uses the durable controller. The boot-enabled service provides the same path
after restart.

Install these units before CI is enabled:

```sh
bash ops/install-release-recovery.sh \
  --apply --confirm APPLY_MONITORING_RELEASE_RECOVERY_UNIT
```

The installer refuses an existing intent, preserves previous unit files on
failure, and requires both units enabled with the path watcher active. CI
compares the installed files byte-for-byte and refuses deployment on drift.

Acceptance evidence must include successful candidate and candidate-failure
rollback runs, SIGKILL before/after pointer promotion and after recreation,
outer-session loss recovered by a watcher with an independently opened lock,
and the negative unit fixture proving controller non-execution on `flock`
failure.

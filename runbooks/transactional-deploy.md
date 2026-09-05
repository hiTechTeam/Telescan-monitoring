# Transactional monitoring deployment

The workflow holds `/tmp/telescan-production-deploy.lock`, uploads a secret-free
immutable release and atomically changes `current`. The host `.env` and data
remain outside releases.

Before promotion it records the old/new image manifests, protects previous
images and writes a durable intent. Candidate containers stay `restart: no`
until stack and telemetry checks pass. A committed release is then armed with
the normal restart policy and the intent is cleared.

Failure before commit restores the previous pointer and images. A committed
but interrupted release is completed. Recovery is handled by the external
supervisor plus systemd boot/path units under the same lock.

Install recovery units once before CI deployment:

```sh
bash ops/install-release-recovery.sh \
  --apply --confirm APPLY_MONITORING_RELEASE_RECOVERY_UNIT
```

Never delete a retained intent or rollback image manually; investigate the
failed gate first.

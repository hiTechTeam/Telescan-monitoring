# P0 handoff readiness

Infrastructure P0 is ready for handoff only when every item below has dated
evidence. Repository merge alone is not completion.

- CI passes shell/YAML/Compose, PromQL rule, Alloy, restricted-ingress nginx,
  frozen-attestation fixtures, transactional rollback, and safety-gate tests on
  pinned versions/digests.
- On all three hosts, `current` resolves inside the expected `releases/`
  directory; no `.release-state/intent.json` remains; the versioned
  `recovery-controller` resolves; recovery `.service` and `.path` units match
  Git, are enabled, and the path watcher is active. No protected rollback tag
  remains after a committed release.
- Failure injection proves old-or-new coherence for SIGKILL before/after
  pointer promotion and after container recreation, plus automatic recovery
  when the entire SSH/session supervisor disappears. Unit tests prove a failed
  `flock` never executes the recovery controller.
- EU relay and Moscow nginx have each completed a healthy deployment showing
  previous and current image IDs. Rollback behavior has been exercised on a
  non-production clone or in an approved failure-injection window.
- The shared Moscow host lock
  `/tmp/telescan-production-deploy.lock` is used by nginx, API, database, and
  bot workflows with the same 1800-second acquisition timeout.
- Moscow maintenance runtime resolves
  `/run/telescan-api-maintenance` to its durable backing directory. Neither
  `api-deploy` nor `nginx-release` is present at handoff. API and nginx each
  publish durable intent and arm an online watcher before taking their own
  marker; the nginx watcher cannot clear `api-deploy`.
- Effective `sshd -T` output passes on all three hosts; a second independent
  key login and provider-console recovery path have been demonstrated after
  any policy change.
- Central, Moscow, and EU state collectors emit fresh timestamps, and
  `REQUIRE_STATE_FRESHNESS_METRICS=true` is present in the central runtime
  configuration.
- The dedicated data mount is exactly `/var/lib/telescan-monitoring`; disk,
  inode, Loki self-metric, and all production health recording-rule checks are
  green.
- Both agents use the restricted write gateway, Prometheus/Loki full APIs bind
  to loopback, old ports fail from both peers, and the three-host attestation
  matches exact DNS, exact role listeners/containers, approved local image
  IDs and pinned digests, firewall, WireGuard, TLS, SSH, and the exact sensitive
  socket allowlist across all listeners and all running-container bindings.
  Unexpected unbound containers and a second API process are rejected.
- A monitoring rollout has retained immutable old/new releases and image
  manifests under the production lock; a failure-injection rehearsal restored
  the prior pointer and protected images and completed the bounded stack plus
  full-telemetry verification documented in `transactional-deploy.md`.
- A unique Telegram drill ID has both FIRING and RESOLVED messages plus the
  host-side evidence record.
- If the Grafana secret-key override is enabled, the consistent database
  backup, rehearsed migration evidence, guarded marker, successful login and
  Telegram drill are attached. Otherwise the migration remains an explicitly
  owned open P0 item; the override must stay disabled.
- The provider firewall/security-group export is attached because guest-only
  evidence cannot attest cloud-edge policy.
- The read-only Docker socket used by Alloy is recorded as a host-root trust
  boundary (read-only does not make the Docker API low privilege), with an
  owner and follow-up plan for a filtered socket proxy or non-Docker log path.

Sync the evidence IDs, actual execution dates, residual Docker-socket risk,
Grafana migration state, and rollback outcomes into the private threat model,
control matrix, operations handoff, and audit evidence index. Public legal or
product claims should change only if the executed state materially changes a
published security/data-processing statement; do not claim a staged control as
active before the runtime attestations pass.

# Production handoff checklist

Handoff requires dated evidence that:

- CI, transactional rollback and safety tests pass.
- Every `current` pointer resolves to a release and no intent remains.
- Recovery services/path watchers and shared host locks are active.
- EU, Moscow and monitoring containers, listeners and image IDs match the
  approved inventory.
- SSH, firewall, WireGuard, DNS/TLS and provider security groups are verified.
- State metrics are fresh on all three hosts and freshness enforcement is on.
- Prometheus/Loki use restricted private write endpoints.
- Backup/restore, rollback and Telegram firing/resolved drills pass.
- Grafana key migration is either verified or explicitly deferred.

Store evidence and residual risks in the private audit repository. Do not claim
a staged control as active before runtime verification.

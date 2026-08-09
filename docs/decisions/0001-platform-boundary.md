# ADR 0001: Platform repository boundary

Status: accepted bootstrap candidate

## Decision

This repository owns provider and infrastructure mechanics, not product semantics.

Platform owns:

- GitHub workflow/provider plumbing;
- project-scoped bootstrap and tool acquisition;
- local container and Kubernetes mechanics;
- infrastructure policy/security checks;
- release, rollback, and operational runbook mechanics;
- future remote infrastructure only after an explicit decision.

Flare and Poker repositories own their application dependencies, build logic, test logic, runtime
configuration semantics, and canonical verification commands.

Provider workflows call repository commands. They do not recreate those commands in YAML.

## Non-goals

No cloud account, remote cluster, GitOps controller, service mesh, Vault-like subsystem, monitoring stack,
or generic CI engine is introduced in this slice.

Cross-project abstraction requires two real consumers proving the same invariant. Until then, Flare and
Poker integrations remain explicit boundaries under `integrations/`.

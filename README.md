# Flare Platform Infrastructure

Platform-owned infrastructure and delivery plumbing for Flare and future reference workloads.

This repository owns reproducible tooling, GitHub CI adapters, local Kubernetes, container plumbing,
platform security checks, release/rollback mechanics, and customer deployment runbooks.

It does **not** own Flare or Poker build/test/runtime semantics. Product repositories remain the source
of truth for their canonical `build`, `test`, `check`, and `verify` commands; CI invokes those commands
instead of reimplementing them.

## Current scope

- Linux amd64 developer/CI bootstrap.
- Project-local tool state under `.platform/`.
- GitHub-first CI with immutable action references and least-privilege permissions.
- Disposable `kind` cluster with an isolated project kubeconfig.
- Deterministic reference workload built locally as `FROM scratch` and loaded into `kind`.
- Static infrastructure/security checks with intentional RED fixtures.
- Integration contracts for Flare and Poker without cross-repository writes.

Remote infrastructure, production Kubernetes, GitOps, cloud provisioning, and Poker-specific runtime
integration are intentionally out of scope until separately authorized.

## Entry points

```bash
make doctor
make bootstrap
make bootstrap       # must remain idempotent
make hooks
make check-fast
make check
make verify
```

`make bootstrap` needs outbound HTTPS for first-time tool acquisition. `make verify` additionally needs
a working Docker daemon. Tool and runtime state is kept under `.platform/` and is safe to delete.

## Local Kubernetes

```bash
make kind-up
make kind-smoke
make kind-negative
make kind-down
```

All Kubernetes commands use `.platform/kubeconfig` and require the exact context
`kind-flare-platform-dev`. The scripts refuse to mutate any other context.

## Gate maturity

The repository implements the candidate gates and their negative fixtures, but a gate is not declared
proven on a machine until `make prove-gates` actually demonstrates its RED case. See
`docs/decisions/0002-quality-security-profile.md` and the bootstrap evidence document.

# Flare Platform Infrastructure

Platform-owned infrastructure and delivery plumbing for Flare and future reference workloads.

This repository owns reproducible tooling, GitHub CI adapters, local Kubernetes, container plumbing,
platform security checks, release/rollback mechanics, and customer deployment runbooks.

It does **not** own Flare or Poker build/test/runtime semantics. Product repositories remain the source
of truth for their canonical `build`, `test`, `check`, and `verify` commands; CI invokes those commands
instead of reimplementing them.

## Current scope

- Linux amd64 developer/CI bootstrap.
- Project-local tool state under a guarded, non-symlink `.platform/` directory.
- GitHub-first CI with immutable action references and least-privilege permissions.
- Disposable `kind` cluster with an isolated project kubeconfig.
- Deterministic reference workload built locally as `FROM scratch` and loaded into `kind`.
- Static infrastructure/security checks with intentional RED fixtures.
- Deterministic review artifacts with checksum, canonical-byte, resource, and portable-path bounds.
- Integration contracts for Flare and Poker without cross-repository writes.

Remote infrastructure, production Kubernetes, GitOps, cloud provisioning, and Poker-specific runtime
integration are intentionally out of scope until separately authorized.

## Entry points

```bash
make doctor
make bootstrap       # ordinary install from the committed checksum lock
make hooks
make prove-local
make check-fast
make check
make verify
```

`make tool-lock` is not part of ordinary bootstrap. A trusted maintainer runs it
only while intentionally changing pinned tool versions, reviews the resulting
`aqua.yaml` and `aqua-checksums.json` diff together, and then repeats
`make bootstrap` and `CI=true make bootstrap`.

`make bootstrap` needs outbound HTTPS for first-time tool acquisition. CI
refuses an unlocked Aqua configuration. `make verify` additionally needs a
working Docker daemon. Tool and runtime state is kept under `.platform/`;
writers reject symlinked directory and file targets before mutation. Use
`make diagnose` for a bounded deterministic evidence ZIP.

## Local Kubernetes

```bash
make verify-runtime
# or inspect individual boundaries:
make kind-up
make kind-smoke
make kind-negative
make kind-down
```

All Kubernetes commands use `.platform/kubeconfig`, require the exact context
`kind-flare-platform-dev`, and prove ownership before reuse or deletion. Runtime
operations and diagnostics are bounded; unsafe kubeconfig output paths are
rejected before writes; namespace and cluster absence are explicitly verified. See `docs/runbooks/local-kubernetes.md`.

## Gate enforcement

The quality and security lanes used by `make check-fast`, `make check`,
`make prove-gates`, and CI are blocking: a tool error, positive-target finding,
or failed RED proof makes the canonical command non-zero. `BLOCKING` describes
that enforcement contract; it does not assert that an arbitrary checkout or
the current promotion candidate has completed its required replay.

Workflow security uses `zizmor --offline` against checked-in files. This keeps
the canonical local gate deterministic and blocks on enabled offline findings,
but zizmor explicitly disables its online audit rules in this mode. Live
repository settings and hosted GitHub behavior therefore require separate
authorization and evidence. Local promotion for implementation
`42e877c489afe8347e4f5a797d453838c95a59c0` passed both the integrated and clean
replacement-worker matrices. See `docs/decisions/0002-quality-security-profile.md`
and `docs/evidence/PLATFORM-PROMOTION-CLOSURE-002__20260810.md`.

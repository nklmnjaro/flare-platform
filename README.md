# Flare Platform Infrastructure

Platform-owned infrastructure and delivery plumbing for Flare and future reference workloads.

This repository owns reproducible tooling, GitHub CI adapters, local Kubernetes, container plumbing,
platform security checks, release/rollback mechanics, and customer deployment runbooks.

It does **not** own Flare or Poker build/test/runtime semantics. Product repositories remain the source
of truth for their canonical `build`, `test`, `check`, and `verify` commands; CI invokes those commands
instead of reimplementing them.

## Current scope

- Capability-verified Linux x86_64 local developer environment; exact host
  package versions are not a support proxy.
- Project-local tool state under a guarded, non-symlink `.platform/` directory.
- Host-owned prerequisites admitted as canonical absolute executables outside
  the checkout and every `.platform` generated-state path.
- Sealed, non-installing normal Aqua execution; bootstrap and maintainer-only
  tool locking remain the explicit installation/update boundaries.
- One invocation-frozen local Unix Docker target shared by Docker, BuildKit,
  and kind consumers.
- GitHub-first CI with immutable action references and least-privilege permissions.
- Disposable `kind` cluster with an isolated project kubeconfig.
- Reference workload with a reproducible host executable and deterministic
  client-side Docker input, built locally as `FROM scratch` and loaded into `kind`.
- Static infrastructure/security checks with intentional RED fixtures.
- Deterministic review artifacts with checksum, canonical-byte, resource, and portable-path bounds.
- Integration contracts for Flare and Poker without cross-repository writes.

Remote Docker/BuildKit endpoints are unsupported and rejected before runtime
mutation. Other remote infrastructure, production Kubernetes, GitOps, cloud
provisioning, and Poker-specific runtime integration are intentionally out of
scope until separately authorized.
Hosted CI adapters are defined, but their external runner behavior has not yet
been replayed and is not claimed by the local capability profile.

The prior local promotion records remain historical evidence. Independent
review first revoked promotion for `f2107559` and later revoked acceptance of
the verification-environment candidate `51af7e0` because host-command, Aqua,
local-Docker, and pristine-proof boundaries were incomplete. Closure-006
continues from that exact candidate; its final live runtime matrix and fresh
plain-clone replay remain pending, so promotion is not claimed.

## Entry points

```bash
make doctor
make bootstrap       # ordinary install from the committed checksum lock
make environment-evidence
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

`make doctor` is a fast, non-destructive capability observation. It separates
host prerequisites, read-only local-Docker reachability, and project bootstrap
state. It may create owned temporary scratch and removes it before returning;
it does not build or pull an image, inspect or remove a workload image, operate
a cluster, bootstrap tools, or mutate repository state. After bootstrap,
`make environment-evidence` emits the exact ordered 35-record
`flare-platform-environment-v2` result without raw workstation paths,
credentials, Docker configuration, or broad environment data. `make bootstrap`
needs outbound HTTPS for first-time tool acquisition. CI refuses an unlocked
Aqua configuration. Actual BuildKit execution, local image mutation, and the
disposable-kind journeys remain owned by `make verify-runtime`. Persistent
project state is kept under `.platform/`; bounded per-call scratch is removed
after use. Writers reject symlinked directory and file targets before mutation.
Use `make diagnose` for a bounded deterministic evidence ZIP.

Aqua-managed commands are admitted only from the guarded project state below
`.platform/aqua`; same-named external PATH tools are never a fallback. This
includes Go/gofmt, quality/security tools, kind/kubectl, and `prek`. Every
normal invocation revalidates the pinned Aqua binary/version, proxy digest, and
managed link, clears inherited exported `AQUA_*` controls, and exports exactly
`AQUA_ROOT_DIR=<project .platform/aqua>`, `AQUA_CONFIG=<project aqua.yaml>`, and
`AQUA_DISABLE_LAZY_INSTALL=true` as Aqua controls on the host-only PATH. A
missing package fails instead of being installed implicitly.

Host-owned means outside this checkout and any `.platform` generated state,
enforced by canonical absolute-path admission rather than PATH ordering.
Aliases, functions, non-file command types, repository-resolved targets, and
same-named project-state executables are rejected. This boundary does not claim
root ownership, package-manager provenance, or a digest for every host binary.

## Local Kubernetes

```bash
make verify-runtime
# or inspect individual boundaries:
make kind-up
make kind-smoke
make kind-negative
make kind-down
```

All Kubernetes commands use `.platform/kubeconfig` and require the exact context
`kind-flare-platform-dev`. Cluster reuse and deletion require the exact Platform
ownership marker; namespace deletion is context-guarded but does not yet claim
a namespace ownership proof. Runtime operations and diagnostics are bounded;
unsafe kubeconfig output paths are rejected before writes; namespace and cluster
absence are explicitly verified.
Before any Docker or kind mutation, the runtime admits one external local Unix
socket and freezes a fingerprint over the canonical Docker executable,
canonical endpoint, and socket device/inode. Docker children use the exact
endpoint with empty per-call Docker/Buildx configuration and
`DOCKER_BUILDKIT=1`; builds require `--builder default`, and kind receives the
same frozen target. TCP, SSH, HTTP(S), npipe, conflicting selectors, and
inherited remote Buildx/BuildKit controls fail closed before mutation.
The reference server reports the SHA-256 of its own running executable, and the
runtime proof rejects loaded image A when same-tag expectation B differs before
running the positive and startup-failure journeys. The accepted positive build
is materialized from an exact clean Git commit/tree snapshot and passes a
deterministic two-file tar through a hashing tee into `docker build`. See
`docs/runbooks/local-kubernetes.md` and
`docs/evidence/PLATFORM-RUNTIME-IDENTITY-003__20260811.md`.

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
authorization and evidence. Implementation
`42e877c489afe8347e4f5a797d453838c95a59c0` historically passed both the
integrated and clean replacement-worker matrices; that record does not override
the later promotion revocation for `f2107559`. See
`docs/decisions/0002-quality-security-profile.md` and
`docs/evidence/PLATFORM-PROMOTION-CLOSURE-002__20260810.md`.

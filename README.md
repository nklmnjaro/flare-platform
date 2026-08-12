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
- One host-local, project-and-cluster-scoped lifecycle lease that makes all
  same-user checkouts rendezvous before they mutate the shared kind cluster.
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
- Fresh, pre-write-sanitized Platform diagnostics with one explicit current run
  identity and checkout-authorized Kubernetes reads.
- Full-history repository recovery capsules that bind one clean named branch,
  commit, tree, object format, and exact three-file payload.
- Integration contracts for Flare and Poker without cross-repository writes.

Remote Docker/BuildKit endpoints are unsupported and rejected before runtime
mutation. Other remote infrastructure, production Kubernetes, GitOps, cloud
provisioning, and Poker-specific runtime integration are intentionally out of
scope until separately authorized.
Hosted CI adapters are defined, but their external runner behavior has not yet
been replayed and is not claimed by the local capability profile.

The prior local promotion records remain historical evidence. Independent
review first revoked promotion for `f2107559` and later revoked acceptance of
the verification-environment candidate `51af7e0`. Closures 006/007 repaired the
host-command, Aqua, local-Docker, ownership, and lifecycle boundaries. Their
final integration baseline is commit
`eb6d0f0c027202e78b2b5b35e18473b0079a28dc`, tree
`95f40069a4d2776494cea35921fa55e32f9ead99`, after integrated, live
two-checkout, bounded-concurrency, direct-clone, bundle-clone, and repeated
runtime replay. Task 008 semantically ports diagnostics and repository recovery
over that baseline. Its final live and clean-clone replay remains pending, so
promotion is not claimed.

## Entry points

```bash
make doctor
make bootstrap       # ordinary install from the committed checksum lock
make environment-evidence
make hooks
make prove-diagnostics
make prove-recovery
make prove-local
make check-fast
make check
make diagnose
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
checkout state is kept under `.platform/`; the only host-local exception is the
deterministic lifecycle rendezvous below `/tmp`, which normally remains as an
exact free lock-only directory. Bounded per-call scratch is removed after use.
Writers reject symlinked directory and file targets before mutation. Use
`make diagnose` for one bounded, fresh, checksum-verifiable observation. Live
Kubernetes archives are identified by structure, manifest, and run identity;
changing events and timestamps mean two live ZIPs need not have equal bytes.
See `docs/contracts/platform-diagnostics-v2.md` and
`docs/runbooks/diagnostics.md`.

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

## Repository recovery

```bash
make prove-recovery
make recovery-pack OUTPUT=.platform/recovery/capsule
make recovery-verify CAPSULE=.platform/recovery/capsule
```

The capsule contains exactly `MANIFEST.sha256`, `RECOVERY.json`, and
`repository.bundle`. It captures one clean named branch with explicit `HEAD`,
full history, commit, tree, and object format. Packing rejects dirty or hidden
index state, shallow/partial/promisor history, replace/graft state, submodule
gitlinks, Git LFS attributes or pointer blobs anywhere in reachable history,
object alternates/common-directory indirection, unsafe fsck configuration, and
source races. Verification performs a direct special-path clone and full strict
object-graph check; bundle verification alone is insufficient.

Clean-source admission does not delegate physical truth to `git status` or
repository clean/smudge configuration. It requires the exact `HEAD` tree and
stage-zero index to agree, then reads the pinned physical worktree without
following links and compares raw Git-blob bytes, executable state, and symlink
targets. Tracked regular files and symlinks must each have one hard link. At the
worktree root only the pinned non-symlink `.git` directory and, when present, an
effective-user-owned mode-0700 non-symlink `.platform` directory are exempt from
that raw tree walk; every other extra entry is rejected even when Git would
ignore it. Any effective `filter.*` configuration is rejected before an
attribute-consuming command can run it, and repository config includes are
unsupported.

Source parent/root/`.git`, private `/tmp` workspaces, the output parent, and the
private stage are descriptor-pinned and identity-rechecked. Bundle stdout may
write at most 64 MiB to the stage; overflow is drained but rejected. Each
capsule member must be a one-link regular file, and atomic same-parent
no-replace publication never overwrites an existing destination.

Git is resolved only through the canonical absolute host-command boundary.
Each bounded Git child leads an isolated, PID/start-time-bound process group;
timeout or surviving-descendant cleanup uses TERM, poll, KILL, reap, and
two-sample absence proof. The bundle restores reachable committed bytes verbatim,
including any committed secret. It does not separately copy local/uncommitted
credential stores, source `.git/config` remotes/auth, `.platform`, Docker/kind
state, or uncommitted workstation files. See
`docs/decisions/0008-repository-continuity.md` and
`docs/runbooks/repository-recovery.md`.

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
`kind-flare-platform-dev`. Cluster reuse, namespace deletion, and cluster
deletion require an exact four-key ownership marker bound to the current
checkout; the exact 12-line ConfigMap snapshot is rechecked immediately before
mutation. A checkout digest is accidental-safety evidence, not authentication.
Runtime operations and diagnostics are bounded; unsafe kubeconfig output paths
are rejected before writes; namespace and cluster absence are explicitly
verified.
Every lifecycle entrypoint either acquires the deterministic host-local lease
for the Platform project and cluster name or validates the inherited descriptor
and token. A contender that finds the canonical kernel lock busy exits `75`
before Docker, kind, or kubectl mutation; an encountered unsafe or malformed
lease boundary exits `76`. Successful root release removes the holder record
and leaves the shared root as exact free lock-only state.

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
`docs/runbooks/local-kubernetes.md`,
`docs/evidence/PLATFORM-LOCAL-RUNTIME-ISOLATION-AND-CONCURRENCY-007__20260811.md`,
and `docs/evidence/PLATFORM-RUNTIME-IDENTITY-003__20260811.md`.

## Gate enforcement

The quality and security lanes used by `make check-fast`, `make check`,
`make prove-gates`, and CI fail closed: a tool error, positive-target finding,
or failed RED proof makes the canonical command non-zero. Failure propagation
alone does not set gate maturity. Signals move to `BLOCKING` only under
`docs/decisions/0002-quality-security-profile.md`; the new Task 008 diagnostics
and recovery signals remain `ADVISORY` until their integrated positive, exact
RED, and clean-clone replay is retained. Previously matured signals remain
blocking, but no maturity label asserts that the current candidate completed its
required replay.

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

# Local platform development

## Prerequisites

The currently implemented environment is Linux x86_64, but OS identity alone
does not establish support. The host must satisfy the bounded command, GNU tar,
GNU timeout, `flock`, `/proc`, Docker, and project-toolchain capabilities checked by
`make doctor`. Docker must resolve through the admitted external host-command
boundary to a reachable Linux amd64 daemon on a local Unix socket. System,
rootless, and Docker Desktop socket paths are accepted by capability rather than
by one hardcoded pathname. Remote Docker/BuildKit targets are unsupported.

## Bootstrap

```bash
make doctor
make bootstrap
make environment-evidence
make hooks
```

`make doctor` does not build or pull images, create clusters, or install tools.
On a pristine checkout it reports project bootstrap as ready to perform rather
than treating absent project tools as a host failure. Run `make bootstrap` to
install the locked project tools; the strict machine evidence command requires
that ready toolchain and then emits the exact ordered 35-record
`flare-platform-environment-v2` snapshot including admitted tool identities and
an invocation-specific local-Docker fingerprint. The fingerprint and complete
output digest describe that invocation and are not stable cross-host
identities. Actual Docker build/image mutation and kind behavior remain owned
by `make verify-runtime`.

Ordinary bootstrap uses the committed required checksums. The trusted maintainer
workflow for deliberately updating pinned tools is documented only in
`docs/runbooks/tool-updates.md`.

Normal managed-tool execution never falls back to PATH and is not an install
operation. It revalidates Aqua and its proxy, clears inherited exported
`AQUA_*` controls, exports only `AQUA_ROOT_DIR=<project .platform/aqua>`,
`AQUA_CONFIG=<project aqua.yaml>`, and `AQUA_DISABLE_LAZY_INSTALL=true` as Aqua
controls, and runs on the host-only PATH. If an installed package is absent, the
command fails; do not enable lazy installation to repair it. Run the ordinary
checksum-enforced `make bootstrap` instead.

## Local feedback and gate ownership

```bash
make check-fast
make prove-local
make prove-gates
```

Use `make check-fast` before commits. It runs cheap positive static/unit checks;
the recovery module contributes only its explicit `TestRecoveryFast` class.
`make prove-local` runs offline-capable RED fixtures and proves the recovery
class boundary with an active closure sentinel, but does not execute the full
adversarial recovery suite. `make prove-gates` is the full gate proof: its Make
prerequisite runs `make prove-recovery` once, then its script runs the local and
external-tool RED fixtures. Direct `make prove-local` does not acquire that Make
prerequisite.

The runtime record below includes the integrated implementation replay before
the final documentation amendment, retained for commit
`72f3f1ad22c1f2ebdf4063e587a4f71390ec8ef5`. The final docs-bearing candidate's
clean-clone replay remains pending. A measurement is a planning input, never
permission for a silent skip, stale success cache, reduced assertion set, or
`|| true`.

| Command or class | Unique signal and recovery ownership | Retained wall time |
| --- | --- | --- |
| recovery fast class | deterministic unit/classification; fast recovery only | `0.027-0.029s` after R3 |
| `make check-fast` | cheap positive source/tool checks; fast recovery only | focused `12.723s`; integrated `14s` |
| `make prove-local` | offline RED plus active recovery class boundary; no full recovery | integrated `203s` |
| `make prove-gates` | one full recovery prerequisite plus local/external RED | integrated `448s` |
| `make check` | `check-fast` plus positive Hadolint, Trivy, schema, and policy targets | integrated `15s` |
| `make prove-recovery` | sole full non-race recovery owner | integrated `237s`; old `356.296s` |
| `make verify` | check, admitted recursive `make prove-gates`, and disposable runtime | integrated `642s`, then `659s` |
| `make prove-recovery-race` | separate race-enabled closure lane | not in matrix; old `646.395s` |

The old timings are comparison evidence, not repaired-candidate acceptance.
The clean-clone replay must record every canonical command's measured duration
and stay within its runner budgets without dropping a signal.
The two pre-fix direct-clone literal-path REDs and their distinct recovery and
diagnostics repairs are retained in the Task 008 integration evidence; neither
failed attempt counts as clean-clone acceptance.

## Full local proof

```bash
make verify
```

This runs static/security checks, proves intentional RED fixtures, executes the
full non-race recovery closure exactly once through the admitted recursive
`make prove-gates`, admits and freezes one external local Unix Docker target,
creates a disposable kind cluster on that same target, runs positive and
negative workloads, captures bounded diagnostics for the negative path, and
tears the cluster down. Builds use the exact admitted Docker executable and
endpoint with empty per-call Docker/Buildx configuration,
`DOCKER_BUILDKIT=1`, and `--builder default`.
The outer verification command holds the shared project-and-cluster lifecycle
lease; its nested lifecycle commands validate the inherited token and descriptor
instead of locking again.

Persistent generated checkout state is under `.platform/`. The lifecycle
rendezvous is the single host-local exception: a deterministic directory below
`/tmp` normally persists as an exact free lock file with no holder. Owned
observation and Docker child scratch may be created under the trusted temporary
root and is removed before the command returns. The project root, Aqua
executable-directory chain, and every project path used for a write or reset
must be real directories or regular files, not symlinks. Remove ordinary
generated state with `make clean`; that command holds the lifecycle lease while
it checks cluster cleanup and removes `.platform`, and it retains the shared
free lock-only rendezvous.

## Lifecycle contention and interruption

Lifecycle commands cover `verify`, `verify-runtime`, `smoke`,
`negative-smoke`, `identity-negative-smoke`, `kind-up`, `kind-down`,
`delete-namespace`, and `clean`. They all rendezvous on the same host-local
lock for the fixed Platform cluster even when started from different checkouts.

`FAIL  lifecycle     another lifecycle action is active` with status `75`
means the canonical kernel lock is busy. The rejected contender has not
attempted Docker, kind, or kubectl mutation, but status `75` alone does not
authenticate or validate the process holding the lock. Wait for the active
operation or inherited descendant to finish, then rerun the entire canonical
command; do not bypass the lease with raw tools. Status `76` means the root,
lock, holder, descriptor, PID/start-time identity, or inherited token failed a
trust check. Preserve the exact diagnostic and inspect the state before any
operator action; do not delete or rewrite a holder merely because its PID text
looks stale.

TERM, HUP, and INT mark the owner interrupted. EXIT cleanup closes the root
owner's descriptor and deliberately skips sibling mutating cleanup, while any
live descendant that inherited the descriptor can keep the kernel lock busy
until it exits. KILL cannot run a trap at all. A later contender recovers an
exact stale holder only after acquiring the kernel lock and proving the recorded
PID/start time absent, terminal, or replaced.

An interruption after kind creates a cluster but before Platform publishes its
ownership marker leaves a present unowned cluster. The next canonical command
must stop without further mutation. Follow the operator validation procedure in
the Kubernetes runbook; this gap is not an automatic adoption or delete path.

Canonical quality, hook, and Kubernetes scripts execute Aqua-managed commands
only through project-local entries below `.platform/aqua/bin`. An external PATH
command with the same name is never an accepted fallback. If a command reports
`project-managed toolchain unavailable or untrusted`, rerun `make bootstrap`
rather than installing an unpinned host copy.

If a command reports `FAIL  state-guard`, inspect the path before changing it:

```bash
ls -ld .platform .platform/aqua .platform/aqua/bin 2>/dev/null || true
find .platform -maxdepth 4 -type l -print 2>/dev/null || true
```

Do not run `rm -rf` on a path that may resolve outside the repository. After confirming a reported entry
is only a generated-state symlink, unlink the symlink itself and rerun the canonical command. If a kind
cluster may still exist, preserve the failure evidence and use `make kind-down` after restoring a real
project-local state directory.

If a command reports `FAIL  docker-target`, do not bypass it with raw Docker or
kind mutation. Check the caller's `DOCKER_HOST`, `DOCKER_CONTEXT`, and external
Docker configuration using read-only Docker context inspection. Remove an
unintended remote selection or inherited `BUILDX_BUILDER`, `BUILDKIT_HOST`, TLS,
or related remote controls in the caller environment, then rerun `make doctor`.
The boundary may inspect local context metadata to classify a target, but it
does not contact a rejected remote endpoint. A target fingerprint mismatch
means the executable or Unix socket identity changed during the canonical run;
start a fresh invocation only after independently understanding that change.

The guard prevents accidental and same-user symlink path escape. It is not a sandbox against a hostile
concurrent local user, bind mounts, or a compromised executable already trusted by the repository.

## Failure evidence

```bash
make diagnose
make artifact-verify ARCHIVE=.platform/platform-diagnostics.zip
```

The mutable archive pair represents only the current successful run. A new run
invalidates the old pair before collecting payload. An overall failed diagnostic
run leaves no valid current pair. External output is sanitized before its first
durable write, and Kubernetes payload reads require the exact context and
checkout-bound ownership. Authorization, query, or concurrent-teardown
subfailure discards the whole Kubernetes staging directory, but the parent run
may publish a complete sanitized host/status-only pair.

Live events and timestamps can change. Verify structure, exact manifest, run
identity, freshness, bounds, and consistency instead of requiring two live ZIPs
to have equal bytes. This is a narrow Platform fixture collector, not generic
DLP or a Flare/Poker log collector. Run `make prove-diagnostics` for its exact
RED fixtures and see `docs/runbooks/diagnostics.md`.

## Repository continuity

```bash
make prove-recovery
make prove-recovery-race
make recovery-pack OUTPUT=.platform/recovery/capsule
make recovery-verify CAPSULE=.platform/recovery/capsule
```

Create a capsule only from the final clean committed named branch. The Make
targets resolve only a file-type `git` from the exact caller PATH captured before
project environment publication. Canonical admission rejects lookup, physical,
or resolved locations inside repository, generated, or lifecycle state and
passes the absolute executable to the helper. This does not claim
package-manager, vendor, or root-ownership provenance. Every Git child leads an
isolated PID/start-time-bound process group; timeout or surviving-descendant
cleanup uses TERM, poll, KILL, reap, and two-sample absence proof.

The exact three-file capsule restores committed history and verifies branch,
commit, tree, object format, clean state, and the full object graph. Clean means
an exact `HEAD`/stage-zero-index match plus pinned raw physical bytes, executable
state, symlink targets, and one-link tracked leaves; every extra entry outside
root `.git` and guarded private `.platform` is rejected even when ignored.
Configured `filter.*` and repository config includes are unsupported. Bundle
output is capped at 64 MiB, capsule members must be one-link regular files, and
publication never replaces an existing destination.

Every reachable committed byte is restored, including any accidentally
committed secret. Local/uncommitted credential stores, source `.git/config`
remotes/auth, caches, uncommitted files, Docker images, and Kubernetes state are
not copied as separate workstation state. See
`docs/runbooks/repository-recovery.md`.

The race command is a separately named closure/maintainer lane and is not part
of `check-fast`, `prove-local`, `prove-gates`, `check`, or ordinary `verify`.
Run it when producing the explicit race evidence required by a closure; never
substitute its previous success for the non-race proof owned by
`make prove-recovery`.

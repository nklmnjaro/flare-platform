# Disposable local Kubernetes runbook

## Prerequisites

Run `make doctor` and the ordinary checksum-enforced `make bootstrap`. Do not run
`make tool-lock` during routine setup; that maintainer-only sequence is reserved
for an intentional pinned-version change and is documented in
`docs/runbooks/tool-updates.md`.

Docker must resolve as the exact host-admitted executable and reach a Linux
amd64 daemon through an external local Unix socket. The socket path is not
hardcoded, so normal system, rootless, and Docker Desktop local sockets can
satisfy the contract. Remote Docker contexts/hosts, remote Buildx/BuildKit
controls, and ambiguous selectors are unsupported and rejected before runtime
mutation or connection to the rejected endpoint.

Canonical positive evidence requires clean Git status at its capture and
publication checkpoints. Commit the intended fixture changes first: the
positive journey captures one exact commit/tree pair, materializes its inputs
from Git objects, and refuses a dirty or changed source identity instead of
silently accepting concurrent worktree edits. The final aggregate validates the
retained positive clean-status record; it does not re-read Git status later.

All lifecycle commands for `flare-platform-dev` use one deterministic
host-local lease shared by normal same-user checkouts. Canonical `/tmp`, the
lease root, lock, holder, descriptor, and PID/start-time identity must pass their exact
trust checks before Docker, kind, or kubectl mutation.

## Normal verification

```bash
make verify-runtime
```

At entry the command acquires the project-and-cluster lifecycle lease, then
admits one local Docker target and freezes a fingerprint
over the canonical Docker executable, canonical endpoint, and socket
device/inode. Every Docker call uses that exact executable and endpoint with
owned empty per-call Docker/Buildx configuration and `DOCKER_BUILDKIT=1`; kind
receives the same frozen target. The fingerprint is invocation-scoped, not a
persistent or cross-host daemon identity.

The command then creates or safely reuses only `flare-platform-dev` and runs, in
order:

1. pure response, context, evidence, and process-cleanup RED proofs;
2. a live stale same-tag RED that loads image A, builds but does not load B,
   and rejects running executable A against expected SHA-256 B;
3. the positive build, load, rollout, exact health, and executable-identity
   journey;
4. the intentional startup-failure and bounded-diagnostics journey;
5. final deletion, an independent absence query, a second idempotent deletion,
   and another absence query.

The command publishes `.platform/runtime-identity/evidence.env` only after all
three journeys, every journey's namespace removal, port-forward cleanup, and
both cluster absence checks succeed. The file is generated evidence and should
not be committed.

Individual boundaries are available for diagnosis:

```bash
make kind-up
make kind-smoke
make kind-negative
make kind-down
```

`make kind-down` refuses a same-name cluster without the exact checkout-bound
ownership marker. Namespace deletion has the same ownership requirement. The
ConfigMap must have exactly the four `checkout-v1` data keys and no binary data;
its bounded 12-line UID/resource-version snapshot must be identical when
rechecked immediately before mutation. Legacy, malformed, foreign, and
other-checkout markers are not adopted or repaired. Do not bypass these guards
with raw deletion commands unless an operator has independently proved
ownership.

The checkout digest deliberately contains no raw path, but it is accidental
safety rather than authentication. A different normal checkout receives a
different digest and cannot reuse the cluster, delete its namespace, or delete
the cluster. The host-local lease additionally prevents the ownership check and
mutation from interleaving across those checkouts.

The runtime also refuses symlinked `.platform` components, kubeconfig outputs,
reference binaries, port-forward logs, and diagnostic reset targets. A guard
failure is not evidence that the cluster is absent; restore a real local state
path and let the ownership checks determine whether deletion is allowed.

The positive probe uses an ephemeral IPv4 loopback port; there is no fixed
`18080` allocation to reserve. It checks exact `ok` plus LF and an exact
65-byte lowercase SHA-256 response. The recorded Docker config digest and Pod
CRI `imageID` intentionally use different identity domains and are marked
non-comparable. The authoritative content bridge is equality between the fresh
host binary SHA-256 and the value computed by the running executable itself.
The builder presents a deterministic two-file tar to `docker build` on stdin.
The build explicitly requires `--builder default`, `--network=none`,
`--pull=false`, `--no-cache`, and plain progress on the frozen local Docker
endpoint. This is a daemon-default BuildKit contract, not a separately
fingerprinted BuildKit binary/version claim. The proof requires its archive
hash, both tee-captured input-stream hashes, and
both exact byte counts to agree before accepting either image build. Immediately
before kind load, the consumer requires build-source commit/tree equality with
the positive source record, independently re-hashes the generated files against
their manifest, and reconstructs that tar to verify the recorded hash and byte
count.

## Failure evidence

```bash
make diagnose
make artifact-verify ARCHIVE=.platform/platform-diagnostics.zip
```

The archive is deterministic, checksum-verifiable, and bounded. Each Kubernetes
capture is capped while the command is running, rather than after an unbounded
temporary dump. Captures are limited to the Platform reference namespace plus
node status. This is not a generic Flare/Poker log collector.

A failed namespace query is not treated as successful deletion. A failed final
cluster teardown also keeps `make verify-runtime` red.
Positive and negative emergency EXIT traps remain armed until full PASS. Their
cleanup is best effort on a failed path and is not evidence of absence; rerun the
guarded absence checks before treating local state as clean.

Status `75` with `another lifecycle action is active` is bounded contention:
the rejected command has not reached Docker, kind, or kubectl mutation. Wait for
the owner and rerun the whole command. Status `76` is a fail-closed lease trust
or state-boundary error, not an ordinary busy result. Preserve the diagnostic;
do not manually rewrite the holder or bypass the lease.

TERM, HUP, and INT mark the owner interrupted and suppress sibling mutating
cleanup. The root owner's EXIT path closes its descriptor, but a live descendant
can keep the kernel lock active until it exits. KILL cannot be trapped. Only a
later owner that first acquires the kernel lock may recover a holder whose exact
PID/start-time identity is proved absent, terminal, or replaced. An interrupted
namespace deletion is retried through the same ownership and lease checks until
absence is explicitly proved.

If admission fails with `FAIL  docker-target`, do not bypass it with raw Docker
or kind mutation. Inspect the caller's Docker host/context and builder controls
read-only, remove an unintended remote selection, and start a new canonical
invocation. A fingerprint mismatch means the admitted Docker executable or Unix
socket identity changed during the run and must not be treated as a warning.

## Incomplete kind creation

If `kind create` returns failure before Platform can install its ownership
marker, or an interrupt lands after creation but before marker publication, the
scripts stop without a sibling cluster deletion. The interrupted path retains
its kubeconfig for diagnosis. They do not assume that a newly visible same-name
cluster is safe to delete, and a retry must reject that unowned cluster without
further mutation.

Inspect Docker container labels, creation timestamps, and the failed command's
bounded diagnostics. Only after independently proving that every node belongs
to this Platform attempt may an operator invoke raw `kind delete cluster` for
`flare-platform-dev`. Never encode that exception into CI or routine cleanup.
This explicit operator action is the irreducible create-to-marker recovery
boundary; it must never become automatic adoption.

## Cleanup

```bash
make kind-down
make clean
```

`make clean` acquires the same lifecycle lease around its guarded `kind-down`
check and `.platform` removal. When kind is absent and no project kubeconfig
exists, it removes only checkout-generated state and reports that no cluster
mutation was attempted. Normal success leaves the deterministic host-local lease
root as exact free lock-only state; that persistent rendezvous is not a leaked
holder and must not be removed by routine cleanup.

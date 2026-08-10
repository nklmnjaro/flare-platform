# Disposable local Kubernetes runbook

## Prerequisites

Run `make doctor`, `make bootstrap`, and the checksum-lock sequence described in
`docs/decisions/0003-tool-bootstrap.md`. Docker must be reachable.

Canonical positive evidence requires clean Git status at its capture and
publication checkpoints. Commit the intended fixture changes first: the
positive journey captures one exact commit/tree pair, materializes its inputs
from Git objects, and refuses a dirty or changed source identity instead of
silently accepting concurrent worktree edits. The final aggregate validates the
retained positive clean-status record; it does not re-read Git status later.

## Normal verification

```bash
make verify-runtime
```

This creates or safely reuses only `flare-platform-dev` and runs, in order:

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

`make kind-down` refuses a same-name cluster without the exact ownership
marker. Do not bypass this guard by invoking raw deletion commands unless an
operator has independently proved ownership.

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
The proof requires its archive hash, both tee-captured input-stream hashes, and
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

## Incomplete kind creation

If `kind create` returns failure before Platform can install its ownership
marker, the scripts remove only their local kubeconfig and stop. They do not
assume that a newly visible same-name cluster is safe to delete.

Inspect Docker container labels, creation timestamps, and the failed command's
bounded diagnostics. Only after independently proving that every node belongs
to this Platform attempt may an operator invoke raw `kind delete cluster` for
`flare-platform-dev`. Never encode that exception into CI or routine cleanup.

## Cleanup

```bash
make kind-down
make clean
```

When kind is absent and no project kubeconfig exists, `make clean` removes only
local generated state and reports that no cluster mutation was attempted.

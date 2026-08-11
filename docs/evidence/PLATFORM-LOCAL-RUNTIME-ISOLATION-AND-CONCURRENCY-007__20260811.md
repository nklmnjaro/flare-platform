# PLATFORM-LOCAL-RUNTIME-ISOLATION-AND-CONCURRENCY-007 evidence

Date: 2026-08-11

Status: `IMPLEMENTED; FINAL LIVE AND CLEAN-CLONE REPLAY PENDING`

Promotion: `NOT CLAIMED`

## Scope and preserved baseline

Closure-007 integrates checkout-bound kind ownership and closes a reproduced
local lifecycle race. It preserves the Closure-006 host-command, sealed Aqua,
local-Docker, BuildKit, runtime-identity, and bounded-evidence boundaries. It
does not authorize remote Docker/BuildKit, remote Kubernetes, registries, cloud
resources, production, hosted-CI behavior, or Flare/Poker product changes.

The immutable Phase-A integration snapshot is:

```text
commit: 219bae9208d9d9f6ec2d00114afef6e926b60c06
tree:   d73f3381e5c1799d3d211ee01941d26aa48a5012
parent: 9baf4508ceed0d7ee7db815a78a8b2d65f280a29
subject: fix(platform): bind kind lifecycle to checkout
```

The lifecycle implementation, tests, documentation commit, final archive, live
combined replay, and fresh clean-clone replay do not yet have immutable
identities in this record. No final candidate or promotion identity is inferred
from the Phase-A commit.

## Phase A: checkout-bound ownership

`tools/common/checkout-identity.sh` is the single identity implementation used
by ownership and lease code. It hashes the effective user ID and canonical
physical checkout root under the `flare-platform-checkout-v1` domain and emits
only `sha256:<64 lowercase hex>`. Raw checkout paths are not stored in
Kubernetes or evidence.

The `kube-system/flare-platform-ownership` ConfigMap must contain exactly four
data keys and no binary data:

```text
contract_version=checkout-v1
owner=flare-platform-infra
cluster_name=flare-platform-dev
checkout_id=sha256:<64 lowercase hex>
```

Admission reads a bounded, exactly 12-line snapshot containing API version,
kind, namespace, name, UID, resource version, data count, binary-data count, and
the four values. Reuse requires that snapshot to belong to the current checkout.
Namespace and cluster deletion require a fresh read to equal the admitted
snapshot immediately before mutation. Legacy, malformed, foreign-contract,
other-cluster, other-checkout, and replaced markers fail without adoption,
rewrite, namespace deletion, or kind deletion.

This digest prevents accidental mutation by another normal checkout. It is not
authentication against a hostile same-user process, and digest knowledge alone
does not grant ownership.

A bounded live two-checkout Phase-A exercise was observed against the immutable
integration snapshot, and its final cluster was absent. This draft has not been
given an immutable transcript index or checksum for that observation, so it is
not promoted as final combined acceptance and must be repeated after the lease
and documentation commits are immutable.

## Phase B decision: the race required a lease

The mechanized pre-lease adapter retains the unsafe interleaving:

```text
kind-up ownership snapshot captured
kind-down deletes the cluster
kind-up ownership snapshot returns and can report a false PASS
```

The leased GREEN ordering requires:

```text
kind-up ownership snapshot captured
kind-up ownership snapshot returns and completes its boundary
kind-down deletes only on an independently admitted retry
```

This is the decision evidence required by N-04/N-05: ownership markers alone
do not serialize a check-then-mutate sequence. The repository therefore adds a
lease for this exact host-local lifecycle race. The RED remains a no-op-lease
fixture rather than a production bypass.

## Why the rendezvous is host-local

The task proposed project-local lease storage, but the resource being protected
is one host-local kind cluster name shared by multiple same-user checkouts. Two
independent `.platform` locks cannot see each other and therefore cannot satisfy
the required cross-checkout race. The smallest correct implementation uses one
deterministic `/tmp/flare-platform-lifecycle-lease-<sha256>` directory derived from a
versioned Platform project-and-cluster contract. The path contains no raw
checkout, home, or username value; checkout identity remains in the bounded
holder record.

This correction changes storage location, not scope: the lease protects only the
fixed local Platform project and cluster lifecycle. It is not a scheduler,
daemon, database, distributed lock, generic workflow engine, or authorization
service.

## Lease boundary

The production module enforces:

- canonical root-owned mode-1777 `/tmp`;
- an EUID-owned mode-0700 lease root with exact directory link count two;
- EUID-owned mode-0600, single-link regular lock and holder files;
- pinned directory, path, descriptor, device, and inode equality around
  creation, acquisition, holder publication, assertion, and cleanup;
- one non-blocking exclusive kernel `flock` owner;
- a maximum 1024-byte exact holder grammar containing schema, PID, Linux process
  start time, checkout digest, root action, and random-derived token;
- nested commands admitted only by the inherited open descriptor, schema, token,
  and exact live holder identity; and
- exact stale recovery only while holding the kernel lock and after the shared
  process classifier proves the recorded PID/start time absent, terminal, or
  replaced.

An active contender exits `75` with no Docker, kind, or kubectl mutation. An
unsafe, changed, or malformed lease boundary exits `76`. The holder is removed
on successful release. The deterministic directory and free lock file remain as
exact lock-only state so later checkouts still rendezvous on the same inode.
`make clean` acquires this lease around guarded cluster cleanup and `.platform`
removal; it intentionally does not erase the shared rendezvous.

Public lifecycle failures use bounded fixed reasons. They do not echo the holder
record, token, raw checkout path, username, or home path.

Host-command admission rejects executables resolved from either repository state
or a deterministic lifecycle-lease root. Doctor and environment proofs admit the
exact external `flock` behavior used by production; shell functions and
generated-state substitutes are RED cases.

## Interruption and retry semantics

TERM, HUP, and INT set the interrupted state. Entrypoint EXIT cleanup closes the
root owner's descriptor and skips sibling mutating cleanup. A live descendant
that inherited the open description can keep the kernel lock busy until it
exits. KILL cannot be trapped; the same inherited-descriptor rule applies, and
the next owner may recover the exact stale holder only after the lock becomes
available and process identity is no longer live.

A pre-mutation interruption permits a clean canonical retry. An interrupted
namespace deletion is retried through the same lease, ownership snapshot, and
explicit absence proof. No signal handler claims that best-effort cleanup proves
absence.

There is one irreducible boundary between successful `kind create` and ownership
marker publication. If interruption lands there, the cluster is present and
unowned. Automatic retry must reject it before further mutation; it cannot adopt
or delete it. A human operator must validate container provenance and explicitly
remove the fixture cluster before canonical retry.

## Mechanized coverage

The source candidate contains bounded fixtures for:

- exact checkout identity and foreign, legacy, malformed, extra-key,
  binary-data, and replaced-marker rejection;
- the retained pre-lease ownership/delete RED and leased ordering GREEN;
- two same-checkout `kind-up` contenders;
- `verify-runtime` racing `kind-down`, followed by an ordered retry;
- two different checkouts racing for one cluster name;
- pre-mutation TERM and retry;
- post-create/pre-marker interruption, mutation-free rejection, and explicit
  operator recovery;
- interrupted cluster deletion and idempotent guarded retry;
- active, stale, zombie, absent, PID-replaced, malformed, and symlinked lease
  state;
- valid nested inheritance, wrong token, forked release, descriptor retention,
  directory replacement, and cleanup replacement attacks; and
- final proof-process, namespace, cluster, and holder absence, with every fixed
  bounded proof root retained as exact free lock-only state.

These fixtures define the required source behavior. This draft deliberately
does not attach mutable working-tree command output or fabricate final
transcript checksums.

## Final acceptance still pending

Promotion requires evidence from the final immutable implementation and
documentation commits, including:

- the complete Closure-006 canonical matrix with explicit bounds;
- common lease proof and lifecycle concurrency fixtures on the exact candidate;
- the live two-checkout ownership journey on one admitted local Docker daemon;
- a bounded live concurrency replay where practical;
- live `make verify-runtime`, repeated `make verify`, final namespace/cluster
  absence, no surviving owned processes or holder, and every registered lease
  root in exact free lock-only state;
- the same sequence from a pristine direct clone, including the required
  special-character checkout path;
- exact commit/tree identities, clean initial/final status,
  `git diff --check`, and `git fsck --full --no-dangling`; and
- a directly cloneable bundle plus checksum-verified bounded review archive.

Until those exact outputs and checksums are retained against the immutable
candidate, Closure-007 remains `IMPLEMENTED; FINAL LIVE AND CLEAN-CLONE REPLAY
PENDING` and promotion remains `NOT CLAIMED`.

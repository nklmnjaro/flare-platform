# ADR 0004: Disposable local Kubernetes

Status: Closure-007 accepted integration baseline; Task 008 replay required

## Decision

Use `kind` as the first disposable Kubernetes implementation. This proves
Platform mechanics only; it is not a Flare product deployment.

The cluster identity is fixed to `flare-platform-dev`. Every Kubernetes command
uses the isolated `.platform/kubeconfig`, requires the exact
`kind-flare-platform-dev` context, and rejects a symlinked state directory or
kubeconfig before any exporter writes. Reuse, namespace deletion, and cluster
deletion additionally require the exact checkout-bound in-cluster ownership
ConfigMap and a project-and-cluster lifecycle lease.

## Checkout-bound ownership

One shared identity module derives `checkout_id=sha256:<64 lowercase hex>` from
the effective user ID and canonical physical checkout root under the versioned
`flare-platform-checkout-v1` domain. Kubernetes and evidence store only that
digest, never the raw checkout path. The ownership ConfigMap must contain
exactly these four data keys and no binary data:

```text
contract_version=checkout-v1
owner=flare-platform-infra
cluster_name=flare-platform-dev
checkout_id=sha256:<64 lowercase hex>
```

Admission captures one bounded, exactly 12-line snapshot containing the object
type, namespace, name, UID, resource version, data counts, and four values.
Immediately before a namespace or cluster mutation, the consumer reads the
marker again and requires byte-for-byte equality with that admitted snapshot.
Legacy, malformed, foreign-contract, other-cluster, and other-checkout markers
are never rewritten, adopted, or used as delete authority.

The digest is an accidental-safety boundary between normal same-user checkouts.
It is not authentication or protection from a hostile process running as the
same user, and a digest value alone is never deletion authority without the
exact live ConfigMap snapshot and lifecycle lease.

## Host-local lifecycle lease

The named kind cluster is host-local state shared by normal same-user checkouts
on one daemon. A lock stored inside one checkout cannot serialize another, so
the literal project-local storage proposed by the task would leave the
reproduced race open. The minimal correct rendezvous is a deterministic
directory below `/tmp` derived from a versioned Platform project-and-cluster
contract. It contains no
raw checkout path or username and is not a scheduler, service, database,
distributed lock, or authorization system.

The boundary requires canonical root-owned mode-1777 `/tmp`; an EUID-owned
mode-0700 lease directory; and EUID-owned, mode-0600, single-link regular lock
and holder files. It pins and compares directory, path, descriptor, and inode
identity around creation and use. A non-blocking kernel `flock` admits one root
owner. Its bounded holder binds schema, PID, Linux process start time, checkout
digest, root action, and a random-derived token. Nested commands inherit the
open descriptor, schema, and token and validate the exact holder instead of
trying to acquire a second lock.

An active contender returns status `75` before Docker, kind, or kubectl
mutation. Unsafe, changed, or malformed coordination state returns status `76`.
Recovery can remove an exact stale holder only after the kernel lock is held and
the PID/start-time classifier proves the prior owner absent, terminal, or
replaced. Successful release removes the holder but intentionally retains the
shared directory and free lock file as exact lock-only host state; `make clean`
participates in the same lease and does not erase that rendezvous.

## Lifecycle properties

- kind, kubectl, Docker build/load, rollout, and port-forward calls have outer
  time bounds;
- kubectl API calls also use request timeouts where streaming is not required;
- every mutating lifecycle entrypoint acquires or validates the same lease
  before Docker, kind, or kubectl mutation;
- on an ordinary failure, a cluster created by the current `kind-up` run is
  removed only when the exact marker snapshot installed by that run still
  grants cleanup authority;
- a pre-existing same-name cluster is never deleted without ownership proof;
- destroy verifies the cluster is absent and is idempotent when already absent;
- smoke resources stay in the isolated `flare-platform-reference` namespace;
- namespace deletion uses a bounded poll window, proves API-visible absence,
  and does not confuse an API failure with absence;
- positive smoke proves build, local image load, rollout, HTTP health, and
  cleanup;
- positive smoke also requires the running server to return the exact SHA-256
  of its own executable, and rejects a changed mutable tag at the load boundary;
- a separate live RED loads image A, builds different image B under the same
  local tag without loading B, and requires the running A executable to be
  rejected against the expected B SHA-256;
- port-forward selects an ephemeral IPv4 loopback port, tracks its process
  group, and proves that group absent; the stale RED additionally proves its
  selected port is unreachable afterward;
- negative smoke is accepted only after the expected startup-failure marker is
  observed, then captures stream-bounded diagnostics and proves cleanup;
- positive and negative EXIT traps stay armed until full PASS; emergency cleanup
  is best effort and never substitutes for explicit absence evidence;
- TERM/HUP/INT mark the owner interrupted; EXIT cleanup closes the root owner's
  descriptor and skips sibling mutation, while an inherited descendant can keep
  the kernel lock busy until it exits;
- KILL cannot be trapped; an inherited descriptor has the same retention
  behavior, after which exact stale-holder recovery applies;
- runtime verification performs an explicit final cluster teardown whose
  failure changes the command result.

If `kind create` fails before reporting success, or the process is interrupted
after creation but before marker publication, automation does not blindly
delete a newly visible same-name cluster because in-cluster ownership is not yet
provable. The interrupted path retains its kubeconfig for diagnosis. A retry
must reject the present unowned cluster without further mutation. This
create-to-marker gap is irreducible without changing kind itself; recovery
requires an operator to establish container provenance before raw kind cleanup,
as documented in the runbook.

## Diagnostic read boundary

Diagnostic collection validates the exact context and checkout-bound ownership
before the first Kubernetes payload read. A foreign checkout receives a fixed
refusal without workload output. Accepted bytes pass through the bounded
sanitizer before their first durable write.

The read set is limited to node status and the
`flare-platform-reference` namespace. It excludes Secrets, ConfigMaps,
kubeconfig, `describe`, raw object dumps, and arbitrary namespaces. Every run
has a fresh identity; an overall failed run leaves no current mutable archive
pair. Live events and timestamps are validated by structure and run consistency,
not by byte equality between two observations. The normative boundary is
`docs/contracts/platform-diagnostics-v2.md`.

The collector is read-only and does not extend the mutating lifecycle action
grammar. If an owned teardown races a query, the bounded collection fails and
resets the whole Kubernetes staging directory rather than accepting partial
payload. The parent diagnostic run may still publish a complete sanitized
host/status-only pair. Only an overall failed run leaves no current pair.

## Reference fixture

The fixture is a standard-library Go HTTP server built with no third-party
module, `CGO_ENABLED=0`, `-buildvcs=false`, `-trimpath`, and an empty build ID.
Two fresh host builds must produce identical bytes. At startup the server hashes
the file resolved by `os.Executable`; `/identity` returns exactly the resulting
64 lowercase hexadecimal characters followed by LF. The binary is copied into
`scratch`, runs as UID/GID 65532, receives no service-account token, has no added
Linux capabilities, and uses bounded resources plus readiness/liveness probes.

The accepted positive journey requires a clean worktree and captures an exact
Git commit/tree pair before its Docker build and kind image load. It materializes
`Dockerfile` and the server source from that Git object snapshot, rather than
from a concurrently mutable worktree. For each of two Docker builds, the builder
creates an independently guarded staged context and deterministic tar containing
exactly two regular files, `Dockerfile` and `server`. A canonical manifest
outside each staged context binds their paths, modes, sizes, and SHA-256 values,
and an adjacent canary proves that the context boundary excludes unrelated
repository content. Both archive SHA-256 values, both exact tee-captured stdin
SHA-256 values, and both byte counts must agree. This binds the exact bytes
presented to each successful `docker build` command at the tee boundary; it does
not claim an identity for daemon-internal reads or layers. Immediately before
kind load, the consumer requires build-source commit/tree equality with the
positive source record, re-hashes both generated context files against the
manifest, and reconstructs the canonical tar to check the recorded hash and byte
count. BuildKit result IDs are bound to immediate `docker inspect` results. Local
Docker config digests and the CRI-reported Pod image identity are retained with
explicit, non-comparable semantics; neither substitutes for the running
executable hash.

The kind node image is pinned by tag and digest. The fixture image is built
locally with Docker build networking disabled and loaded directly into kind;
no external registry is required for the workload.

## Promotion evidence boundary

The repair implementation at
`42e877c489afe8347e4f5a797d453838c95a59c0` completed the live Docker/kind
journey on 2026-08-10. The positive probe returned exactly `ok` followed by LF;
the negative workload emitted `intentional startup failure requested`; both
journeys proved namespace absence. Final teardown and its idempotent repeat
reported `cluster_after_final_teardown=absent` and
`cluster_after_idempotent_teardown=absent`.

The clean replacement-worker clone of the same implementation repeated the
entire canonical matrix. Its `make verify-runtime` and `make verify` logs each
retained the health response, startup marker, both namespace removals, and both
cluster-absence markers. A later standalone `make kind-down` again confirmed
absence. Initial/final Git status and `git fsck --full` were empty.

The final documentation commit and directly cloneable bundle cannot embed
their own identities without a self-reference. Their exact values are recorded
and verified after commit in the accompanying `identities.env` contract.
Hosted GitHub behavior remains outside the authorized local Docker/kind scope.

The current disposition is recorded in
`docs/evidence/PLATFORM-PROMOTION-CLOSURE-002__20260810.md`. Historical evidence
remains unchanged and continues to describe the environment in which it was
captured.

The runtime-identity implementation at
`38730f9e554c6905dd5f57d739dde64fb9fa6443` completed an integrated
clean-worktree live replay on 2026-08-11. Its exact Git source snapshot and
Docker input stream, stale same-tag RED, positive executable identity, startup
failure, namespace cleanup, and repeated cluster teardown are recorded in
`docs/evidence/PLATFORM-RUNTIME-IDENTITY-003__20260811.md`. That record
supersedes only the runtime-identity boundary; it does not rewrite the earlier
promotion evidence.

Closure-007 preserves those historical runtime results and adds checkout-bound
ownership plus lease-backed lifecycle serialization. Its fixtures retain the
unsafe pre-lease ownership/delete ordering as RED evidence and require the
leased ordering as GREEN evidence. Final commit
`eb6d0f0c027202e78b2b5b35e18473b0079a28dc` and tree
`95f40069a4d2776494cea35921fa55e32f9ead99` completed the integrated,
live two-checkout, bounded-concurrency, direct-clone, bundle-clone, and repeated
runtime replays on 2026-08-12. The earlier candidate record remains historical:
`docs/evidence/PLATFORM-LOCAL-RUNTIME-ISOLATION-AND-CONCURRENCY-007__20260811.md`.

Task 008 changes the diagnostic read/publication boundary and therefore needs a
new final live and clean-clone replay. That replay is not claimed by the
Closure-007 result.

## Non-goals

Helm, Terraform, Ansible, Argo CD, Flux, Vault, service mesh, remote clusters,
and a full observability stack remain out of scope. They solve no property in
this change that the small local foundation cannot prove directly.

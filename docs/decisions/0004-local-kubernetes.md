# ADR 0004: Disposable local Kubernetes

Status: runtime executable and build-input identity proven at `38730f9`

## Decision

Use `kind` as the first disposable Kubernetes implementation. This proves
Platform mechanics only; it is not a Flare product deployment.

The cluster identity is fixed to `flare-platform-dev`. Every Kubernetes command
uses the isolated `.platform/kubeconfig`, requires the exact
`kind-flare-platform-dev` context, and rejects a symlinked state directory or
kubeconfig before any exporter writes. Reuse and deletion additionally require
the in-cluster ownership ConfigMap.

## Lifecycle properties

- kind, kubectl, Docker build/load, rollout, and port-forward calls have outer
  time bounds;
- kubectl API calls also use request timeouts where streaming is not required;
- a cluster successfully created by the current `kind-up` run is removed if a
  later ownership/readiness step fails;
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
- runtime verification performs an explicit final cluster teardown whose
  failure changes the command result.

If `kind create` itself fails before reporting success, automation removes its
local kubeconfig but does not blindly delete a same-name cluster because
in-cluster ownership is not yet provable. This is a deliberate safe stop, not a
cleanup false green. Recovery requires an operator to establish container
provenance before using raw kind cleanup, as documented in the runbook.

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

## Non-goals

Helm, Terraform, Ansible, Argo CD, Flux, Vault, service mesh, remote clusters,
and a full observability stack remain out of scope. They solve no property in
this change that the small local foundation cannot prove directly.

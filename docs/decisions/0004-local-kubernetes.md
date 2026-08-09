# ADR 0004: Disposable local Kubernetes

Status: offline safety contract proven; live Docker/kind replay pending

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
- negative smoke is accepted only after the expected startup-failure marker is
  observed, then captures stream-bounded diagnostics and proves cleanup;
- runtime verification performs an explicit final cluster teardown whose
  failure changes the command result.

If `kind create` itself fails before reporting success, automation removes its
local kubeconfig but does not blindly delete a same-name cluster because
in-cluster ownership is not yet provable. This is a deliberate safe stop, not a
cleanup false green. Recovery requires an operator to establish container
provenance before using raw kind cleanup, as documented in the runbook.

## Reference fixture

The fixture is a standard-library Go HTTP server built with no third-party
module, `CGO_ENABLED=0`, `-buildvcs=false`, `-trimpath`, and an empty build ID. Two local builds
produce identical bytes. The binary is copied into `scratch`, runs as UID/GID
65532, receives no service-account token, has no added Linux capabilities, and
uses bounded resources plus readiness/liveness probes.

The kind node image is pinned by tag and digest. The fixture image is built
locally with Docker build networking disabled and loaded directly into kind;
no external registry is required for the workload.

## Non-goals

Helm, Terraform, Ansible, Argo CD, Flux, Vault, service mesh, remote clusters,
and a full observability stack remain out of scope. They solve no property in
this change that the small local foundation cannot prove directly.

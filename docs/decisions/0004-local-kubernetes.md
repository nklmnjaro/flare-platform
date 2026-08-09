# ADR 0004: Disposable local Kubernetes

Status: accepted bootstrap candidate

## Decision

Use `kind` as the first local Kubernetes implementation.

Safety properties:

- fixed cluster name `flare-platform-dev`;
- fixed isolated kubeconfig `.platform/kubeconfig`;
- exact expected context checked before mutations;
- in-cluster ownership marker required before reuse or deletion;
- pinned kind node image and Kubernetes version;
- bounded waits and diagnostics;
- idempotent namespace cleanup;
- cluster deletion only by exact project cluster name.

The reference workload is intentionally product-neutral. A small Go HTTP server is compiled statically,
packaged with `FROM scratch`, loaded with `kind load docker-image`, deployed, probed by host port-forward,
and removed.

Helm, GitOps, remote clusters, and production topology remain non-goals until real complexity requires
them.

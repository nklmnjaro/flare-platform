# Disposable local Kubernetes runbook

## Prerequisites

Run `make doctor`, `make bootstrap`, and the checksum-lock sequence described in
`docs/decisions/0003-tool-bootstrap.md`. Docker must be reachable.

## Normal verification

```bash
make verify-runtime
```

This creates or safely reuses only `flare-platform-dev`, runs the positive and
negative Platform fixture journeys, proves namespace cleanup, and deletes the
owned cluster.

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

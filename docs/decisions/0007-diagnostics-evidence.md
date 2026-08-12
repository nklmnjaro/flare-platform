# ADR 0007: Fresh and private diagnostic evidence

Status: accepted for the integrated Task 008 candidate; final replay pending.

## Context

The original collector reused `.platform/diagnostics/raw`. An older file could
survive a later successful run and enter its archive. A previous ZIP/checksum
pair could also remain visible when the next current capture failed. Separately,
external diagnostic bytes could reach a durable file before sanitization, and
Kubernetes collection required the expected context but not accepted ownership.

The independent freshness and privacy fronts proposed conflicting failure
semantics. Freshness invalidated the previous mutable pair before collection;
privacy preserved that pair when prepublication failed. Keeping the old pair at
the current names risks presenting stale evidence as the current observation.

## Decision

Freshness wins for the mutable current publication.

One `make diagnose` invocation owns one raw run identity and, only on complete
success, one ZIP/checksum pair. Before reading current payload, the collector
invalidates the previous pair and replaces the raw run directory. Failure leaves
no valid current pair when the overall invocation returns failure. An older
capture may survive only in a future immutable history namespace with a distinct
run identity; this decision adds no such history system.

All external bytes are sanitized and bounded before their first durable write.
Raw files use private same-directory staging and atomic rename. The archive is
built and semantically verified in private staging, then the ZIP is published
before its detached checksum. Only a complete single-run capture is packageable.

Kubernetes payload reads require the exact project kubeconfig and context plus
accepted checkout-bound ownership. The read set is narrow and excludes
Secrets, ConfigMaps, kubeconfig, `describe`, arbitrary object dumps, and
arbitrary namespaces. Refusal occurs before any payload read. A concurrent
owned teardown may fail the read-only collection; that failure resets the whole
Kubernetes staging directory rather than publishing a partial payload. The
parent collector may still complete with the sanitized Platform summary and a
fixed Kubernetes status only.

Controlled fixtures retain deterministic-byte requirements. Live captures are
accepted by canonical structure, exact manifest, explicit run identity,
freshness, and internal consistency. Event and timestamp changes make byte
equality between two live captures an invalid blocking invariant.

The normative details are in
`docs/contracts/platform-diagnostics-v2.md`.

## Preserved boundaries

The integration reuses, rather than bypasses:

- canonical absolute host-command admission;
- sealed project-managed Aqua execution;
- generated-state guards and canonical artifact verification;
- the local-Docker target boundary;
- checkout-bound Kubernetes ownership; and
- the single host-local lifecycle lease for mutating actions from Closure-007.

The read-only diagnostic collector does not join or extend the lifecycle action
grammar. The integration adds no second lease, ambient PATH fallback, unbounded
host command, or separate archive implementation.

## Consequences

A failed overall `make diagnose` invocation deliberately sacrifices mutable-pair
availability for an unambiguous current-evidence meaning. A bounded Kubernetes
subfailure instead produces no Kubernetes payload and may publish only the
host/status subset. Operators must rerun rather than reattach an old checksum or
edit a partial archive.

The sanitizer has a supported grammar and cannot justify broad data collection.
Unknown secret formats and product payloads remain prohibited input. The
archive digest identifies one observation, not a stable runtime state.

## Deliberate exclusions

This decision does not add persistent diagnostic history, generic DLP,
cross-host locking, remote evidence storage, product-specific diagnostics,
power-loss transactions, or a customer support SLA.

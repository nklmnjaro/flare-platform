# PLATFORM-TRUST-TOOLCHAIN-CLOSURE-004 evidence

Date: 2026-08-11

Status: `IMPLEMENTED; FINAL CLEAN-CLONE REPLAY PENDING`

## Boundary

This record starts from reviewed candidate
`f2107559f3acad5cc5468b9e30e537c84add2c20` and preserves its runtime-identity
history. It repairs only the independently reproduced Aqua trust,
project-managed tool identity, Linux process-state, and documentation defects.
It does not authorize merge, production, cloud, registry, remote mutation, or
product-source changes.

## Reproduced pre-repair defects

- a forged, version-compatible `.platform/bootstrap/aqua` executed three times
  during `make tool-lock`, manufactured a checksum file, and returned zero;
- empty project state plus ten marker-writing PATH tools made `make check`
  return zero;
- a killed grandchild could remain in Linux state `Z`, where `kill -0` returned
  true and `make prove-local` reported a false surviving-process failure;
- the ordinary development runbook included the maintainer-only `tool-lock`
  operation.

## Implemented contracts

- one sourceable Aqua module owns the pinned hashes, version, and pre-execution
  verification used by bootstrap and tool-lock;
- one managed-command boundary admits the 13 Aqua-managed command names only
  through validated project-local paths and never through external PATH;
- one Linux `/proc/<pid>/stat` boundary distinguishes live/stopped processes,
  zombies/dead processes, absent PIDs, and live process-group members;
- evidence capture and runtime cleanup share that process-state contract while
  retaining bounded TERM/KILL, direct-child reap, status, and marker semantics;
- ordinary bootstrap no longer invokes `make tool-lock`.

## Focused evidence

The implementation checkout has passed:

- forged and non-executable Aqua exact REDs with unchanged lock/config bytes;
- all 13 fake managed-tool REDs and all five canonical-consumer REDs, with no
  marker execution;
- inherited-function, escaping proxy, and unadapted test-fixture REDs;
- canonical Aqua proxy GREEN and explicit isolated Kubernetes fixture adapter;
- deterministic `kill -0=true` zombie proof;
- live TERM-resistant process-group KILL/reap/absence proof;
- `make check-fast`, `make check`, `make prove-local`, and `make prove-gates`.

The final implementation SHA, plain-clone canonical matrix, `git fsck`, bundle
identity, and clean final status will be appended only after they actually
exist. Until then present promotion remains revoked.

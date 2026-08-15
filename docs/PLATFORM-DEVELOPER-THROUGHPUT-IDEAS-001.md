# Platform Developer Throughput Ideas

Status: reviewed backlog; no new throughput implementation is implied.

Baseline lineage: Task 008R1 source
`74538648b307a36b1cf1b1163c4129664cdafeb8`. Measure the exact current commit
again before selecting an item.

## Rules

Correctness, security, deterministic RED reasons, and bounded cleanup stay
blocking. An optimization is rejected if it skips assertions, reuses stale PASS
state, weakens isolation, or merely moves work into another canonical target.
The repository continues to invoke product-owned Flare/Poker semantics rather
than absorbing them.

## Priority backlog

### PDT-002 — Reproducible time and resource baseline

Add a non-blocking machine-readable benchmark for cold and warm `bootstrap`,
`check-fast`, `prove-gates`, `check`, and `verify-runtime`. Record commit, tool
lock identity, status, wall time, peak RSS, and cache state. Existing wall times
are acceptance evidence, not a repeatable performance benchmark. Select the
three largest measured bottlenecks before changing execution.

### PDT-001 — Additional Ubuntu 26.04 capability lane

Run doctor, cold/cached bootstrap, gates, static/security, artifact, and
disposable-runtime paths in an isolated Ubuntu 26.04 worker. Keep the existing
lane until a support decision is recorded. Do not upgrade the only workstation
to obtain evidence and do not replace capability checks with a broad distro
claim.

### PDT-004 — One bounded cheap-check concurrency budget

After PDT-002, evaluate bounded parallelism for independent Go modules and
linters. One per-invocation input must cap total Go and shell fan-out. Output
must remain deterministic by gate; signal, cleanup, and every failure reason
need RED coverage. Default conservatively for several workers on one laptop.

### PDT-005 — Authenticated immutable download reuse

Only after the state and executable-admission boundaries remain green, evaluate
an optional content cache keyed by the exact checksum lock. Reused bytes must be
authenticated before execution; concurrent publication must be atomic and
bounded; mutable state stays per-worktree. Prefer an adequate native Aqua cache
over a second package manager.

### PDT-007 — CI cache and fan-out

After PDT-002/PDT-005, evaluate immutable CI caches and safe job fan-out. Keys
derive from committed lock bytes, restored content is reauthenticated,
permissions remain least-privilege, results aggregate deterministically, and
runner minutes as well as wall time are measured. Negative proofs are never
removed for speed.

## Already delivered

- PDT-003: shared kind mutations are serialized by a bounded project/cluster
  lifecycle lease, while separate worktrees retain checkout ownership.
- PDT-006 documentation: `kind-up`, `kind-smoke`, `kind-negative`, and
  `kind-down` form the explicit owned iteration surface; `verify-runtime`
  remains the disposable canonical proof. Its performance measurement belongs
  to PDT-002.

## Handoff for any selected item

Return the exact baseline, command and cache preconditions, measurement or RED
before implementation, smallest reviewable diff, focused plus canonical checks,
before/after evidence, unresolved risks, and an explicit accept/reject verdict.

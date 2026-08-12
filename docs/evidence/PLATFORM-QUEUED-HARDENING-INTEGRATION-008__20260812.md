# PLATFORM-QUEUED-HARDENING-INTEGRATION-008 evidence

Date: 2026-08-12

Status: `IMPLEMENTED; CANDIDATE; FINAL LIVE AND CLEAN-CLONE REPLAY PENDING`

Promotion: `NOT CLAIMED`

## Exact integration baseline

The semantic port starts from the final Closure-007 candidate:

```text
branch:   platform/local-runtime-isolation-007
commit:   eb6d0f0c027202e78b2b5b35e18473b0079a28dc
tree:     95f40069a4d2776494cea35921fa55e32f9ead99
worktree: clean before Task 008 integration
```

The Task 008 branch, final commit, and final tree are intentionally not invented
in this source record. They belong to the immutable handoff after the candidate
is committed.

The three independent front histories were treated as semantic inputs, not
blindly cherry-picked:

```text
diagnostics freshness: c90343dc36431dc2ebba80eaa2ec4a6159abe702
                       77d136df2a5474bfdd7057eaebe1e2331c330903
diagnostics privacy:   9b3ad3cb53f50e7a98c6ac65bc46a9306f1c5e9c
                       42f21d534144f157252b6be7496fab34ab88a597
                       c2d21da58090f4eccaad898ee68d55964b4f4677
repository continuity: 02b3a585ee1c88627030f36f00cd2b225a2a95d9
                       57a8af396b119ac6919d87b448953b7ba6eec9ed
                       2f364b42bbcb4ffa3df580f6aff2c3fb20be2ede
```

Input package sidecars, manifests, path/mode policy, and Git bundles were
mechanically verified before the port. Exact package and final review archive
checksums remain handoff evidence rather than self-referential source prose.

## Integrated diagnostic decision

The source fronts disagreed about a failed prepublication run. This integration
chooses fail-closed freshness:

1. the mutable ZIP/SHA pair means only the current successful run;
2. it is invalidated before current payload collection;
3. an overall failed capture leaves no current pair;
4. bounded fresh failure evidence may remain with a non-complete run state; and
5. prior evidence may survive only under a distinct immutable historical run
   identity, which Task 008 does not implement.

The port also combines pre-write sanitization, logical-line and total-payload
bounds, atomic raw publication, private verified archive staging, checksum-last
publication, and ownership-before-Kubernetes-read. Exact RED cases cover stale
raw and pair state, supported secret/path/control canaries, invalid UTF-8, NUL,
partial publication, symlink boundaries, and foreign ownership with no payload
side effect.

A Kubernetes authorization/query subfailure is deliberately narrower than an
overall capture failure: it discards all Kubernetes payload, records a fixed
sanitized status, and may publish a complete host/status-only current pair.

The integrated run identity is `sha256:<64 lowercase hex>` in the exact
five-record `flare-platform-diagnostics-capture-v2` status and is repeated by
the `flare-platform-diagnostics-v3` summary.

Live diagnostic bytes are observations, not reproducible build artifacts.
Synthetic fixtures must be byte-deterministic; live captures are bound by exact
structure, manifest, run identity, freshness, limits, and internal consistency,
not equality between two event/timestamp-bearing archives.

## Integrated recovery decision

One authoritative capsule has exactly:

```text
MANIFEST.sha256
RECOVERY.json
repository.bundle
```

It binds a named branch, explicit `HEAD`, full history, commit, tree, object
format, clean worktree, unsupported-state declarations, and bundle SHA-256.
Clean worktree truth is the exact recorded `HEAD` tree equal to the stage-zero
index plus a descriptor-relative, no-follow read of the physical worktree. Raw
regular-file bytes are Git-blob-hashed for the repository object format;
executable state, symlink targets, and one-link leaf ownership must match. Every
extra entry outside pinned root `.git` and guarded mode-`0700`, effective-user
owned `.platform` is rejected even when ignored. Configured `filter.*` is
rejected before an attribute-consuming command can execute it. The bounded
one-link repository config is content-bound and rechecked; `include` and
`includeIf` paths, worktree config, alternate-ref commands, fsck overrides,
object alternates, and common-directory indirection are unsupported.

Packing also rejects hidden index state, shallow/partial/promisor history,
replace/graft state, submodule gitlinks, Git LFS attributes or pointer blobs
anywhere in reachable history, and a raced source. Source parent/root/`.git`
descriptors and their canonical names are retained and rechecked while Git
children use the held worktree and Git-directory descriptors. Verification uses
direct special-path materialization plus `git fsck --full --strict`; bundle
verification or clone exit status alone is insufficient.

The bundle writer persists at most exactly 64 MiB and rejects any drained
overflow before publication. The three capsule members are exact one-link
regular files. Source, private publication stage, capsule snapshot, Git HOME,
and clone/fsck workspaces retain descriptor-bound identities; cleanup operates
relative to held directories and never recursively removes a substituted path.
Their complete top-level entries are identity-registered. Detected cleanup
identity changes reject the operation, preserve a foreign replacement, and
scrub moved owned bytes. Publication is atomic same-parent no-replace.

Deterministic source/stage/temp swaps at the implemented barriers fail closed.
This does not claim a sandbox against continuous hostile same-UID replacement in
the final name-recheck/unlink micro-window; Linux offers no atomic
inode-conditioned unlink primitive here.

The reachable-history scan is bounded to 250,000 objects, 100,000 trees,
100,000 unique historical `.gitattributes` blobs, and 32 MiB per structural Git
output capture.

Git comes only from the final admitted absolute host-command boundary. Recovery
children inherit no ambient project-state Git choice. Every Git child leads an
isolated group bound to Linux PID/start-time identity. Timeout or any surviving
descendant invokes exact-identity TERM, poll, KILL, reap, bounded-output drain,
and two-sample absence proof; a replaced identity is never signalled.

## Preserved Closure-006/007 boundaries

The port must remain green only if it preserves:

- no project-state entry in process-wide `PATH`;
- canonical absolute host-command admission;
- sealed, non-installing project-managed Aqua execution;
- one frozen local Unix Docker/BuildKit target;
- checkout-bound Kubernetes ownership and snapshot recheck;
- the single host-local lifecycle lease and its exact contention statuses;
- final process-group, zombie, retry, and absence semantics; and
- no unverified network or external-state mutation during checks.

Diagnostics and recovery add no second lease or host-command framework.

## Release and Poker documentation review

The reviewed release/Poker documents are already byte-equivalent to the
accepted source front and remain unchanged. They continue to state:

- build once; promote and roll back without rebuilding;
- source, build input, artifact, and runtime identities are separate;
- a normative release contract is not observed runtime evidence;
- Poker is an external Flare customer, not a Platform-managed workload; and
- no fictional self-deployment procedure exists before an authoritative Flare
  artifact and product contract exist.

## Residual limits and rejected expansion

- Diagnostics has no immutable history service and is not generic DLP.
- Live diagnostic observations are not required to be byte-identical.
- Recovery authenticates no publisher and adds no remote backup, retention,
  object storage, or signing service.
- Task 008 supports direct capsule-directory verification. A wrapper ZIP can be
  packed and verified, but the repository has no checksum-first safe extraction
  command yet; that receiver boundary is deferred to Task 009.
- Reachable committed bytes are restored verbatim, including committed secrets.
  Local/uncommitted credential stores, source `.git/config` remotes/auth, local
  caches, Docker state, Kubernetes state, and product deployment state are not
  copied as separate workstation state.

## Candidate verification state

Targeted implementation and documentation checks may be recorded in the final
handoff as they run. This source record does not convert mutable worktree output
into immutable evidence.

The following acceptance remains explicitly pending on the final committed
Task 008 identity:

- the complete integrated matrix, including repeated `make diagnose` and
  repeated `make verify`;
- live Docker/kind diagnostics and final resource/process absence;
- final recovery capsule restoring the exact final branch, commit, and tree;
- a clean direct-clone replay of that exact commit; and
- a checksum-verifiable final archive and evidence index.

Until those results are bound to the immutable candidate, gate maturity and
promotion do not advance on this document alone.

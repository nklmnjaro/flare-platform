# PLATFORM-QUEUED-HARDENING-INTEGRATION-008 evidence

Date: 2026-08-12

Status: `008R1 INTEGRATED REPLAY PASSED; FINAL CLEAN-CLONE REPLAY PENDING`

Promotion: `NOT CLAIMED`

## Exact integration baseline

The semantic port starts from the final Closure-007 candidate:

```text
branch:   platform/local-runtime-isolation-007
commit:   eb6d0f0c027202e78b2b5b35e18473b0079a28dc
tree:     95f40069a4d2776494cea35921fa55e32f9ead99
worktree: clean before Task 008 integration
```

The exact integrated implementation replay identity before the final
documentation amendment is:

```text
branch: platform/queued-hardening-integration-008
commit: 72f3f1ad22c1f2ebdf4063e587a4f71390ec8ef5
tree:   27544de541b12500c40526a391dbc906a28d492b
```

The final docs-bearing candidate identity belongs to the immutable handoff after
this record is committed. Its clean-clone replay remains pending.

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

Independent review reproduced two diagnostic defects in the first Task 008
candidate. A keyed compound credential could retain the credential token after
its scheme, and a failed version producer could still be rendered as a present
tool identity. Task 008R1 keeps the sanitizer narrow but makes the accepted
compound grammar exact: supported keyed/header or flag values beginning with
case-insensitive `Bearer` or `Basic` preserve the scheme and replace the
credential token; quoted values become quoted `<redacted>`. Unknown unkeyed
credential text remains prohibited and is not claimed as covered.

A tool becomes `present | <identity>` only after successful admission, exact
version-command exit zero, sanitizer exit zero, exact untruncated framing, and a
nonempty bounded first logical line. Single-line sanitization emits only that
line but continues draining the producer. Nonzero status, timeout, sanitizer
failure, empty output, truncation, and malformed or extra framing all map to the
fixed `version-unavailable` value, and their payload cannot become identity.

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

Independent review also measured the full adversarial recovery suite duplicated
inside nominally fast gate paths. Task 008R1 gives every recovery test one
structurally checked `TestRecoveryFast` or `TestRecoveryClosure` class. Exact
allowlists reject new unreviewed tests and disappeared admitted tests. The fast
selector is used by `check-fast`; `prove-local` exercises the class contract and
an active closure-sentinel RED without executing the full suite.

The Make target `prove-gates` depends on `prove-recovery`, whose exact
`^TestRecoveryClosure` selector owns the full non-race process/filesystem proof.
Its script then runs the local and external RED fixtures. `verify` reaches that
target through an admitted recursive `make`, so the full closure has one owner
and executes exactly once per verification. `prove-recovery-race` runs the same
closure selector as a separate closure/maintainer lane and is not nested in
ordinary verification.

## Gate ownership and runtime record

| Command or class | Recovery ownership and unique signal | Retained wall time |
| --- | --- | --- |
| recovery fast class | deterministic unit/classification contract | `0.027-0.029s` after R3 |
| `make check-fast` | cheap positive checks; fast recovery only | focused `12.723s`; integrated `14s` |
| `make prove-local` | offline RED and active class boundary; no full recovery | integrated `203s` |
| `make prove-gates` | one full recovery prerequisite plus local/external RED | integrated `448s` |
| `make check` | fast positives plus Hadolint, Trivy, schema, and policy positives | integrated `15s` |
| `make prove-recovery` | sole full non-race recovery owner | integrated `237s`; pre-repair `356.296s` |
| `make verify` | check, admitted gate proof, one full recovery, and runtime | integrated `642s`, then `659s` |
| `make prove-recovery-race` | separate race-enabled closure lane | not in matrix; pre-repair `646.395s` |

Before R3, raw recovery `go test ./...` measured `358.644s`, and the duplicated
recovery portion of `make prove-local` measured `317.166s`. All pre-repair
figures are comparison and budget inputs, not claims that the repaired immutable
candidate passed. A budget never permits silent skip, stale success reuse,
warning-only loss, or fewer assertions. The clean-clone transcript must retain
current command durations.

## Integrated implementation replay

The exact matrix passed in the required order on the implementation identity
above. Elapsed wall times retained by the replay were:

| Step | Command | Result | Elapsed |
| ---: | --- | --- | ---: |
| 1 | `make doctor` | PASS | `2s` |
| 2 | `make bootstrap` | PASS | `1s` |
| 3 | `CI=true make bootstrap` | PASS | `1s` |
| 4 | `make environment-evidence` | PASS | `3s` |
| 5 | `make prove-environment` | PASS | `23s` |
| 6 | `make prove-diagnostics` | PASS | `39s` |
| 7 | `make prove-recovery` | PASS | `237s` |
| 8 | `make prove-local` | PASS | `203s` |
| 9 | `make prove-gates` | PASS | `448s` |
| 10 | `make check-fast` | PASS | `14s` |
| 11 | `make check` | PASS | `15s` |
| 12 | `make diagnose` | PASS | `42s` |
| 13 | `make artifact-verify ARCHIVE=.platform/platform-diagnostics.zip` | PASS | `0s` |
| 14 | `make verify-runtime` | PASS | `162s` |
| 15 | `make verify` | PASS | `642s` |
| 16 | `make verify` | PASS | `659s` |
| 17 | `make diagnose` | PASS | `41s` |
| 18 | `make artifact-verify ARCHIVE=.platform/platform-diagnostics.zip` | PASS | `1s` |
| 19 | `make kind-down` | PASS | `1s` |

This establishes the integrated implementation result, including repeated
verification and diagnostics. It does not substitute for the exact clean-clone
matrix against the final docs-bearing commit and does not advance maturity or
promotion.

Before that final integrated replay, a direct clean-clone attempt in a checkout
path containing spaces and literal `#[]&` passed steps 1-6, then recorded a real
RED at step 7: `make prove-recovery` returned status `2` after `261s` because the
class sentinel enumerated `*_test.go` files with `filepath.Glob` and treated the
checkout name as a glob pattern. The repair replaced glob expansion with literal
`os.ReadDir` entry enumeration and added a class-contract regression using a
`source #[]&` directory.

The next direct special-path clean-clone attempt passed steps 1-5, then recorded
a second RED at step 6: `make prove-diagnostics` returned status `2` after `91s`.
The immediate message falsely reported the existing HOME sentinel as a managed
Go write because the proof's full-root `find ! -path` operand interpreted the
metacharacter-bearing pathname as a pattern. Investigation also found the
production source digest using full-root `find -path` operands, so `.git` and
`.platform` were not pruned under the same pathname grammar. Sentinel proofs now
inspect only the synthetic directory's top-level entries with literal `! -name`
matching. Production changes directory to the admitted source root before
pruning literal `./.git` and `./.platform` entries and then reconstructs each
absolute entry from its relative name.

The focused diagnostics privacy proof retained 17 positive PASS records, while
the complete `make prove-diagnostics` step retained 24 intentional-RED PASS
records and the same 17 positive records. Its new
`source snapshot prunes literal Git and state paths` assertion uses a
`source [x] #[]&` root: `.git` and `.platform` mutations leave the digest equal,
then a tracked-file mutation changes it. The complete integrated matrix above
ran only after both literal-path repairs. Both earlier REDs are defect-discovery
evidence, not clean-clone acceptance; the exact final docs-bearing clean-clone
matrix remains pending.

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

The integrated implementation matrix, including repeated `make diagnose`,
repeated `make verify`, live Docker/kind execution, and final `make kind-down`,
passed on the identity recorded above.

The following acceptance remains explicitly pending on the final committed
Task 008R1 docs-bearing identity:

- final recovery capsule restoring the exact final branch, commit, and tree;
- a clean direct-clone replay of that exact commit; and
- a checksum-verifiable final archive and evidence index.

Until those results are bound to the immutable candidate, gate maturity and
promotion do not advance on this document alone.

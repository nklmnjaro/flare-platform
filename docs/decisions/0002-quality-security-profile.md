# ADR 0002: Quality and security profile

Status: Task 008R1 integrated implementation replay passed before the final
documentation amendment; final docs-bearing clean-clone replay required

## Decision

Every gate must catch a distinct risk, have an intentional RED case, and remain
bounded. Similar tools are not added merely to increase scanner count.

A gate moves through `PLANNED -> ADVISORY -> BLOCKING` only after its RED proof,
noise, runtime cost, ownership, and failure meaning are understood. A non-zero
result on a canonical Make path is necessary but not sufficient for `BLOCKING`:
the integrated positive, exact RED, and clean-clone replay must also be retained.
This is a repository contract, not an organization-wide policy.

## Enforcement matrix

| Signal | Tool | Risk caught | Unique signal | RED | False-positive risk | Cost | Command | Maturity |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| source limits | policycheck | hidden giant source glue | exact 120/80 policy | long line/function | low | low | check-fast | BLOCKING |
| Go format | gofmt | noncanonical Go source | language-native formatting | unformatted Go | low | low | check-fast | BLOCKING |
| commit contract | repository script | untraceable history | exact Flare grammar | malformed messages | low | low | hook/prove-local | BLOCKING |
| shell correctness | ShellCheck | shell defects | semantic shell analysis | invalid shell | low-medium | low | check-fast | BLOCKING |
| shell format | shfmt | inconsistent shell layout | deterministic formatting | unformatted shell | low | low | check-fast | BLOCKING |
| workflow syntax | actionlint | invalid Actions YAML/expressions | GitHub workflow semantics | invalid workflow | low | low | check-fast | BLOCKING |
| workflow security | zizmor | unsafe checked-in Actions patterns | offline provider-aware security | unsafe workflow | medium | low | check-fast | BLOCKING |
| Dockerfile policy | Hadolint | unsafe/nonportable image recipe | Dockerfile semantics | unsafe Dockerfile | medium | low | check | BLOCKING |
| secret detection | Trivy secret | committed supported secrets | secret-oriented scan | synthetic secret | medium | medium | check | BLOCKING |
| Kubernetes schema | kubeconform | invalid resource shape | versioned schema validation | invalid resource | low | medium | check | BLOCKING |
| Kubernetes policy | KubeLinter | dangerous workload settings | workload security policy | privileged pod | medium | medium | check | BLOCKING |
| context identity | repository guard | mutation of unrelated cluster | exact local identity | unrelated context | low | low | prove-local/runtime | BLOCKING |
| lifecycle ownership | repository fixture | cross-checkout reuse/delete or changed-marker TOCTOU | exact checkout-bound snapshot and absence proof | foreign/legacy/malformed/replaced marker | low | low | prove-local/runtime | BLOCKING |
| lifecycle serialization | kernel `flock` plus repository fixtures | concurrent kind/kubectl mutation | one project-and-cluster lease with captured mutation order | retained pre-lease race, active/stale/malformed holder, interruption | low | low | prove-local/runtime | BLOCKING |
| artifact integrity | repository helper | tamper, hidden bytes, path escape, leak, resource exhaustion | canonical bounded archive boundary | tamper/symlink/path/home/bytes/limits/self-pack | low | low-medium | prove-local | BLOCKING |
| generated state | repository helper | writes or resets escape through symlinks | one path contract for all local state writers | root/nested/file/reset/traversal | low | low | prove-local/all writers | BLOCKING |
| tool checksum admission | bootstrap guard | unchecked CI tool install | fail-closed CI admission | unlocked Aqua config | low | low | bootstrap/prove-local | BLOCKING |
| diagnostic evidence | repository sanitizer and collector | stale/private evidence or false tool identity | one fresh run, bounded compound grammar, strict identity framing | stale/pair/compound/tool/control/path/ownership/partial | low-medium | low-medium | diagnose/prove-diagnostics | ADVISORY |
| recovery class boundary | Go test allowlists and active sentinel RED | slow closure enters fast checks or silently disappears | structural fast/closure ownership | closure-in-fast/unclassified/disappeared | low | low | check-fast/prove-local | ADVISORY |
| repository recovery | recovery capsule helper | incomplete or ambiguous repository handoff | exact three-file full-history recovery | dirty/hidden/shallow/ref/race/tamper/process | low | high | prove-recovery | ADVISORY |

For signals already mature at `BLOCKING` before Task 008, promotion evidence
must still show the exact pinned tools running every RED fixture and the real
positive targets in both the integrated checkout and a clean clone. A missing
candidate replay prevents promotion but does not demote those already-mature
repository contracts. This rule does not pre-promote the new Task 008 rows;
diagnostics and recovery remain `ADVISORY` until their required replay passes.

Implementation `42e877c489afe8347e4f5a797d453838c95a59c0` satisfied that
contract in both its integrated checkout and a clean replacement-worker clone.
The bounded clean-clone index records all 14 commands with status zero, empty
initial/final Git status, and an empty `git fsck --full` result. Exact evidence
identities are retained in the current promotion record and handoff.

Closure-007 adds a mechanized concurrency decision record. The retained
pre-lease adapter reproduces the unsafe order:
`ownership captured -> delete -> ownership returned`. The leased implementation
requires: `ownership captured -> ownership returned -> delete`. Separate
bounded fixtures cover simultaneous same-checkout creation, verification racing
teardown, cross-checkout contention,
TERM/KILL boundaries, stale-holder recovery, and interrupted deletion retry.
Every rejected contender must leave Docker, kind, and kubectl mutation logs
empty. Final commit `eb6d0f0c027202e78b2b5b35e18473b0079a28dc`, tree
`95f40069a4d2776494cea35921fa55e32f9ead99`, passed the integrated, live
two-checkout, bounded-concurrency, direct-clone, bundle-clone, and repeated
runtime replays. Those signals remain blocking for the accepted Closure-007
baseline.

Task 008 preserves that lifecycle contract and adds two candidate signals.
Independent review then reproduced a compound keyed-secret leak, acceptance of
a failed tool probe as a present identity, and duplicate multiminute recovery
execution inside nominally fast gates. Task 008R1 repairs those defects with a
bounded keyed/flagged `Bearer`/`Basic` grammar, producer-and-sanitizer success
framing, and structurally classified recovery tests.

`check-fast` selects only fast recovery tests. `prove-local` owns the active
class-boundary RED but no full closure scenario. The Make target `prove-gates`
depends on `prove-recovery`, then its script runs local and external RED
fixtures. `verify` invokes an admitted recursive `make prove-gates`; therefore
one verification owns exactly one full non-race recovery closure. The separate
`prove-recovery-race` target is a requested closure/maintainer lane, not an
ordinary verification dependency.

The post-split fast selector measured `0.027-0.029s`; focused
`make check-fast` measured `12.723s`. The exact 19-step integrated implementation
replay passed before the final documentation amendment on commit
`72f3f1ad22c1f2ebdf4063e587a4f71390ec8ef5`, tree
`27544de541b12500c40526a391dbc906a28d492b`; its gate timings were `237s` for
`prove-recovery`, `203s` for `prove-local`, `448s` for `prove-gates`, `14s` for
`check-fast`, `15s` for `check`, and `642s` then `659s` for `verify`. Historical
pre-repair measurements were `356.296s` for `make prove-recovery`, `358.644s`
for raw recovery `go test ./...`, `646.395s` for the race suite, and `317.166s`
for the duplicated recovery portion of `make prove-local`. The exact clean-clone
durations for the final docs-bearing candidate remain pending.

A pre-fix direct clean-clone attempt from a path containing spaces and literal
`#[]&` reached step 7 and returned status `2` from `make prove-recovery` after
`261s` because `filepath.Glob` interpreted the checkout pathname as a pattern.
R3 now enumerates `_test.go` entries with `os.ReadDir`, joins each literal name,
and contains a class-contract regression under `source #[]&`.

The next direct special-path clean-clone attempt reached step 6 and returned
status `2` from `make prove-diagnostics` after `91s`. Its immediate failure was
a proof assertion whose full-root `find ! -path` operand interpreted the
metacharacter-bearing sentinel pathname as a pattern. Investigation also found
the production snapshot using full-root `find -path` operands, so `.git` and
`.platform` were not pruned under the same pathname grammar. The proof now uses
a directory-scoped top-level `! -name sentinel.txt` check. Production changes
directory to the admitted root before pruning literal `./.git` and
`./.platform` entries. A `source [x] #[]&` regression proves state-path
mutations are ignored while a tracked-file mutation changes the digest. The
exact integrated matrix ran only after both repairs; the final docs-bearing
clean-clone replay is still pending.

The diagnostics signal owns stale-current confusion, generated-evidence
privacy, strict tool identity, and ownership-before-read. The recovery signal
owns exact committed repository materialization and complete object-graph
verification. Diagnostics, the recovery class boundary, and recovery remain
`ADVISORY` in this record. The integrated implementation matrix passed, but the
exact clean-clone matrix must still pass against the final docs-bearing commit.
A runtime budget never authorizes a skip, stale success file, reduced assertion
level, or warning-only failure.

## Workflow security boundary

The canonical workflow-security command is `zizmor --offline` over checked-in
workflow files. Findings and tool failures from the enabled offline rules are
blocking. According to zizmor's own command contract, `--offline` disables all
online audit rules and prevents remote-repository auditing. It therefore does
not prove live GitHub repository settings, branch protection, runner posture,
or behavior visible only in hosted Actions. Those properties need separately
retained hosted or primary-source evidence; the offline result must not be
described as complete GitHub security validation. Hosted Actions and live
remote settings are outside the authorized local scope of this decision.

## Deliberate exclusions

The following are not added now:

- a second general secret scanner, because no demonstrated detection gap exists;
- generic YAML linting, because actionlint and kubeconform own the current YAML
  semantics and formatting alone is not a blocking product risk;
- `trivy config`, because Hadolint, kubeconform, and KubeLinter already own the
  present Docker/Kubernetes misconfiguration targets;
- image vulnerability scanning, because the temporary fixture image is a local
  static binary on `scratch` and is not a releasable product artifact;
- Helm, Terraform, GitOps, cloud, or observability scanners without such assets;
- duplicate immutable-Action scripts beside zizmor unless a measured gap is
  demonstrated.

The diagnostics signal is distinct from Trivy: Trivy scans committed source,
while the sanitizer owns generated runtime evidence before its first durable
write. Its bounded grammar covers supported keyed/header and flag values,
including keyed or flagged `Bearer`/`Basic` compounds, but not unknown unkeyed
credential text. Strict tool identity additionally requires successful
admission, producer, sanitizer, framing, truncation, and nonempty-payload
conditions. The normative grammar is documented in
`docs/contracts/platform-diagnostics-v2.md`; it is not generic DLP.

Repository recovery is also not a backup platform. It adds no remote storage,
retention scheduler, signing authority, dirty-worktree recovery, or deployment
state capture.

`prek` is only a local adapter that invokes canonical repository commands. It
is not an independent quality signal.

## Trivy boundary

Trivy is a pinned CLI installed through the shared project bootstrap. It scans
repository files only for secrets, skips fixtures/generated state, and keeps
its cache under `.platform/`. It is not invoked through a floating GitHub
Action wrapper.

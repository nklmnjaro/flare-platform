# ADR 0002: Quality and security profile

Status: Closure-007 candidate implemented; final live and clean replay required

## Decision

Every gate must catch a distinct risk, have an intentional RED case, and remain
bounded. Similar tools are not added merely to increase scanner count.

A gate moves through `PLANNED -> ADVISORY -> BLOCKING` only after its RED proof,
noise, runtime cost, ownership, and failure meaning are understood. Every gate
in the matrix below is now on a canonical Make/CI path whose non-zero result is
propagated, so its repository maturity is `BLOCKING`. This is a repository
contract, not an organization-wide policy and not proof that every candidate
has completed its positive and RED replays.

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

Promotion evidence must still show the exact pinned tools running every RED
fixture and the real positive targets in both the integrated checkout and a
clean clone. A missing replay is a promotion failure; it does not weaken the
gate to advisory status.

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
empty. These are blocking source contracts, but the final live and clean-clone
replay for the combined candidate is still pending and promotion is not claimed.

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

`prek` is only a local adapter that invokes canonical repository commands. It
is not an independent quality signal.

## Trivy boundary

Trivy is a pinned CLI installed through the shared project bootstrap. It scans
repository files only for secrets, skips fixtures/generated state, and keeps
its cache under `.platform/`. It is not invoked through a floating GitHub
Action wrapper.

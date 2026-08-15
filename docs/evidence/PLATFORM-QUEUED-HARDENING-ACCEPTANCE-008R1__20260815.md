# Platform 008R1 acceptance and history consolidation

Date: 2026-08-15

Promotion: `NOT_CLAIMED`

## Immutable intake

The selected historical source is the single full-history 008R1 handoff:

```text
archive: SEND_TO_WEB_DEVOPS__PLATFORM_008R1_CANDIDATE_009_PENDING__20260812.zip
sha256:  29e042201754a9333f9015d567d4c09d94ab9dca84a43564dd24f018755be0c0
branch:  platform/queued-hardening-integration-008
commit:  74538648b307a36b1cf1b1163c4129664cdafeb8
tree:    5738783d3e5ce9ce6c55c57da0e5572f3e861f9e
```

The detached checksum matched before ZIP parsing, `unzip -t` passed, and the
included receiver independently returned:

```text
PASS  web-handoff  archive binding manifest scope delta commits transcripts signals privacy tools and recovery verified
```

Reproduction from a private extraction directory:

```bash
sha256sum -c SEND_TO_WEB_DEVOPS__PLATFORM_008R1_CANDIDATE_009_PENDING__20260812.zip.sha256
receiver/VERIFY.sh . ../SEND_TO_WEB_DEVOPS__PLATFORM_008R1_CANDIDATE_009_PENDING__20260812.zip
```

The checksum establishes received-byte integrity. It does not establish a
cryptographic publisher identity.

## Retained clean-clone replay

The handoff binds a clean clone at the exact commit/tree above. Initial and
final `git status` were empty; `git fsck --full` returned zero before and after;
identity was unchanged. All 19 commands returned status zero in 2558 seconds:

| Step | Command | Seconds |
| --- | --- | ---: |
| 1 | `make doctor` | 2 |
| 2 | `make bootstrap` | 26 |
| 3 | `CI=true make bootstrap` | 2 |
| 4 | `make environment-evidence` | 2 |
| 5 | `make prove-environment` | 22 |
| 6 | `make prove-diagnostics` | 40 |
| 7 | `make prove-recovery` | 227 |
| 8 | `make prove-local` | 213 |
| 9 | `make prove-gates` | 458 |
| 10 | `make check-fast` | 15 |
| 11 | `make check` | 18 |
| 12 | first `make diagnose` | 41 |
| 13 | first diagnostic `artifact-verify` | 0 |
| 14 | `make verify-runtime` | 172 |
| 15 | first `make verify` | 649 |
| 16 | second `make verify` | 629 |
| 17 | second `make diagnose` | 41 |
| 18 | second diagnostic `artifact-verify` | 0 |
| 19 | `make kind-down` | 1 |

This retained replay proves the archived source baseline, not later amendments.

## History and Trash disposition

The full-history candidate contains the accepted Closure-007 baseline and the
later diagnostics, recovery, compound-secret, tool-identity, gate-ownership,
and literal-path repairs. Earlier worktrees, bundles, the pre-R1 Task 008
candidate, and revoked promotion candidates are ancestors or superseded; none
was cherry-picked a second time.

The only flare-platform Git repository found in desktop Trash ended at dirty
commit `a30221d` on the older trust-toolchain closure. Later verified history
supersedes it, so it is retained only as forensic evidence. Other Trash entries
were Flare application probes or negative/tamper fixtures and were not imported.

The pre-existing dirty checkout was preserved. Three unexplained Go directive
bumps to `1.26.0` were not imported because they silently raised the minimum Go
language version. Its developer-throughput proposal was retained only after
rebasing the backlog onto the current architecture and marking already-delivered
lifecycle/iteration work.

No implementation of Task 009 existed in Git history, session patches, or
Trash. Only research survived. Task 009 therefore remains a separate release,
checksum-first receiver, offline A/B upgrade/rollback, and identity-chain task;
Tasks 010/011 remain downstream of it.

## Independent review disposition

The first independent security pass returned `REQUEST_CHANGES`, despite the
green archived matrix. It reproduced generic non-zero RED false positives and
admission of an unsafe pre-created state root. It also required explicit vet,
actual CI commit-range validation, and fd-pinned archive race hardening. The
consolidation branch treats those as amendments, not waivers, and adds focused
RED regressions before replaying the canonical gates.

The archive amendment received a separate `ACCEPT` after fd-relative traversal,
stable `fstat` generations, no-replace publication, final pair rechecks, and 16
deterministic TOCTOU scenarios passed repeated unit, vet, race, source-policy,
and Linux cross-build review. The remaining amendments received `ACCEPT` after
reviewers reproduced and then retested two additional blockers: false success
after Aqua descriptor-stat failure and RED rendering under synthetic
`PLATFORM_ROOT`/`HOME`. The fixed regressions require exact status `69`, a
project-local sealed Go renderer, and exact `<REPO>`, `<HOME>`, and `<home>`
payload lines.

The reviewed implementation is:

```text
commit: 90dbe451707a767ebb48eee4d4892ac9d6f8c475
tree:   975c562e3a4666e6986f83a7f708204b99acd5c7
```

Its three amendment commits are:

```text
dd19a7a41d65a94d02402b68d98ea80f75bffda6 fix(artifact): pin archive filesystem identities
2fa47c4ac30edfc34879c5c0aa2ccdfe9d0ee0f2 fix(platform): harden trust and gate evidence
90dbe451707a767ebb48eee4d4892ac9d6f8c475 docs(platform): consolidate 008r1 owner handoff
```

## Post-amendment replay

A `git clone --no-local` into the literal path `source #[]&` started and ended
at the exact implementation above with empty porcelain status and successful
`git fsck --full`. The source/static/recovery portion returned zero:

| Command | Seconds |
| --- | ---: |
| `make doctor` | 1 |
| cold `make bootstrap` | 44 |
| `CI=true make bootstrap` | 2 |
| `make environment-evidence` | 3 |
| `make prove-environment` | 23 |
| `make prove-diagnostics` | 79 |
| `make prove-recovery` | 203 |
| `make prove-local` | 253 |
| `make prove-gates` | 467 |
| `make check-fast` | 16 |
| `make check` | 17 |
| `make diagnose` | 46 |
| diagnostic `artifact-verify` | 0 |
| `make prove-recovery-race` | 306 |

Local `make verify-runtime` then failed twice, after `109s` and `107s`, when
the host Docker published-port path reset every connection immediately after
kind reported Ready. Read-only diagnosis proved the kube-apiserver returned
HTTP 200 inside the node while both its published port and a separate bounded
HTTP-container port probe reset on the host. Each unowned fixture was identified
by exact kind labels and creation time, explicitly deleted, and proven absent;
the probe container was also removed. This is retained as a workstation Docker
dataplane blocker, not rewritten as a Platform PASS.

The same implementation was pushed to the private repository and independently
executed by GitHub Actions run
[`31903265479`](https://github.com/nklmnjaro/flare-platform/actions/runs/31903265479).
The real initial-push range, bootstrap, RED and positive static/security checks
passed in job `static` (`10m04s`). The independent `kind-smoke` job then passed
the complete disposable Kubernetes path and teardown in `5m39s`; failure
diagnostics were not entered. This hosted result separates the repository
runtime implementation from the confirmed local Docker publish failure.

Verdict: `ACCEPTED` for the Platform source baseline and its defined local/CI
fixture contracts. Release promotion remains `NOT_CLAIMED`.

## Boundaries that remain explicit

- No production, cloud, registry, Flare, Poker, or customer deployment is
  claimed.
- Hosted GitHub behavior is bound only to the exact retained run above; every
  later source commit requires its own result.
- `make prove-recovery-race` is a separate maintainer lane.
- Recovery retains exact Git history and its author/committer metadata; it is
  not a sanitized-history transfer.
- Publisher authenticity, hard RSS/disk quotas for hostile Git bundles, and the
  checksum-first extraction receiver remain future boundaries.
- A hostile process with the same UID is outside the shell/path accidental
  safety claim.

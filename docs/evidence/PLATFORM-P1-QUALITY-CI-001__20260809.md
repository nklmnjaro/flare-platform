# PLATFORM-P1-QUALITY-CI-001 evidence

Date: 2026-08-09
Parent Platform SHA: `f04d0d96b40a6f3dc4ef33027e0e4b1de4cdcacf`
Candidate outcome: `READY_AFTER_EXTERNAL_STEP`

This change hardens the existing repository rather than replacing it. The
actual ending SHA is recorded in the generated handoff because embedding a
commit's own SHA in its contents would be self-referential.

## Confirmed locally

| Verification | Status | Evidence |
| --- | --- | --- |
| non-fixture shell syntax | PASS | every repository script passed `bash -n` |
| policycheck unit suite | PASS | oversized token, nested shell brace, Go and shell limits covered |
| source self-scan | PASS | changed source satisfies 120/80 limits |
| artifact helper unit suite | PASS | integrity and detached checksum mutation rejected |
| `make prove-local` | PASS | all offline GREEN/RED cases behaved as required |
| commit policy | PASS | exact types, title/body limits, whitespace and separator enforced |
| missing-final-newline regression | PASS | body without blank line is rejected without relying on `wc -l` |
| Aqua CI admission | PASS | `CI=true make bootstrap` rejects unlocked checksums before download |
| bounded diagnostics packaging | PASS | deterministic ZIP and detached checksum verify |
| workflow structure review | PASS | least privilege, timeouts, concurrency, immutable Action SHAs |
| canonical CI boundary | PASS | workflow invokes Make targets rather than duplicating runtime steps |
| `make doctor` without Docker | RED as expected | reports missing/unreachable Docker |

## Not executed here

| Verification | Status | Reason / risk / next action |
| --- | --- | --- |
| `make bootstrap` online | BLOCKED_EXTERNAL | environment cannot resolve GitHub; run on online Linux amd64 |
| `make tool-lock` with real Aqua | NOT_RUN | requires the successful online bootstrap; lock remains absent |
| external `make prove-gates` | NOT_RUN | pinned external tools are not installed |
| `make check-fast` | NOT_RUN | ShellCheck, shfmt, actionlint, and zizmor unavailable |
| `make check` | NOT_RUN | Hadolint, Trivy, kubeconform, and KubeLinter unavailable |
| GitHub-hosted workflow | NOT_RUN | no remote Platform repository/permission was supplied |

## Security findings and disposition

1. CI previously allowed Aqua package installation while checksum admission was
   not required. CI now fails closed until the lock is committed.
2. The commit regex previously accepted unsupported breaking markers and was
   not end-anchored. The exact accepted grammar is now enforced.
3. The prior separator check could be bypassed by a missing final newline. A
   targeted RED fixture now proves the fix.
4. The shell function counter stopped at the first nested closing brace. The
   parser now tracks nested braces while ignoring quoted braces and comments.
5. CI had runtime orchestration duplicated inline. It now calls one canonical
   `make verify-runtime` boundary and uploads only a deterministic bounded ZIP.

No supported secret was found in the changed repository files. Full Trivy
secret scanning remains pending the online tool bootstrap.

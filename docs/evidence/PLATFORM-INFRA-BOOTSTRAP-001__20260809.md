# PLATFORM-INFRA-BOOTSTRAP-001 verification evidence

Date: 2026-08-09
Candidate outcome: `READY_AFTER_EXTERNAL_STEP`

This record separates checks actually executed in the current environment from checks that require an
online Linux x86_64 host with Docker. `BLOCKED_EXTERNAL` and `NOT_RUN` are not treated as green results.

| Verification | Status | Evidence / reason |
| --- | --- | --- |
| Shell syntax for non-fixture scripts | PASS | `bash -n` completed for repository scripts. |
| Policy checker unit tests | PASS | Host Go executed `go test ./...` successfully. |
| Policy checker self-scan | PASS | Current sources satisfy 120-char line and 80-line function limits. |
| Reference server compile | PASS | Server compiles as a static binary with no third-party Go dependency. |
| YAML parse excluding invalid fixture | PASS | Repository YAML parsed successfully. |
| Real workflow immutable action refs | PASS | Every external `uses:` value is a 40-character commit SHA. |
| Real workflow trigger policy | PASS | No `pull_request_target` trigger is present. |
| Commit-message policy sanity | PASS | Valid message accepted; intentionally invalid title rejected. |
| `doctor.sh --base-only` | PASS | Required base host commands are present. |
| Policy RED: overlong source line | PASS | Intentional fixture is rejected. |
| Policy RED: overlong function | PASS | Intentional fixture is rejected. |
| `make doctor` | BLOCKED_EXTERNAL | Docker CLI is absent in the execution environment. |
| First `make bootstrap` | BLOCKED_EXTERNAL | Execution environment cannot resolve `github.com`. |
| Second `make bootstrap` | NOT_RUN | First bootstrap could not download the pinned toolchain. |
| `make tool-lock` | NOT_RUN | Requires successful online bootstrap. |
| Full `make prove-gates` | NOT_RUN | Blocking CLI tools were unavailable after bootstrap failure. |
| `make check-fast` | NOT_RUN | Blocking CLI tools were unavailable after bootstrap failure. |
| `make check` | NOT_RUN | Blocking CLI tools were unavailable after bootstrap failure. |
| `make verify` | BLOCKED_EXTERNAL | Requires Docker plus the bootstrapped kind/kubectl toolchain. |
| GitHub-hosted workflow | NOT_RUN | No remote Platform repository was supplied or created here. |
| Poker runtime integration | NOT_RUN | No authoritative Poker runtime contract was supplied. |

## Promotion requirements

Before merge/promotion to `READY`, run the following from an online Linux x86_64 host with Docker:

```text
make doctor
make bootstrap
make tool-lock
make bootstrap
make prove-gates
make check-fast
make check
make verify
```

Then run the GitHub workflow from the actual repository and retain its bounded evidence. The initial
`make tool-lock` must produce a committed `aqua-checksums.json` and enable `require_checksum: true`.

Poker integration is intentionally not a promotion blocker for the generic Platform foundation. It remains
an input-gated integration boundary until Poker supplies its canonical runtime/deployment contract.

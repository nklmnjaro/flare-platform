# PLATFORM-P2-LOCAL-KUBERNETES-001 evidence

Date: 2026-08-09
Parent Platform SHA: `de9148f8ca7313e28033406f52567f71434ecebc`
Candidate outcome: `IMPLEMENTED_OFFLINE; PROMOTION_BLOCKED_EXTERNAL`

The exact ending SHA is recorded in the generated handoff to avoid embedding a
commit's own identity inside its contents. P2 source is prepared and its local
safety contract is proven, but promotion remains blocked until P1 obtains the
real Aqua checksum lock and the disposable Docker/kind replay passes.

## Confirmed locally

| Verification | Status | Evidence |
| --- | --- | --- |
| shell syntax | PASS | every non-fixture Platform script passed `bash -n` |
| source policy | PASS | current source satisfies 120-char and 80-line limits |
| Go helper suites | PASS | artifact and policycheck tests passed |
| reference server compile | PASS | Go 1.23-compatible standard-library module compiled |
| reference binary reproducibility | PASS | VCS metadata disabled; two builds were byte-identical |
| create cleanup RED | PASS | post-create readiness failure deletes only the cluster owned by this run |
| partial-create safe stop | PASS | create-command failure removes local kubeconfig without blind deletion |
| local lifecycle proof | PASS | owned delete reaches absence; absent delete is idempotent |
| ownership RED | PASS | unowned same-name cluster is not deleted |
| context RED | PASS | unrelated context and kubeconfig symlink are rejected before export |
| namespace cleanup | PASS | mock API transition reaches proven absence |
| cleanup API RED | PASS | query failure is not mistaken for absence |
| diagnostics bound | PASS | noisy output is stream-capped; no unbounded temporary capture remains |
| `make prove-local` | PASS | integrity, bootstrap, source, commit, and Kubernetes proofs pass |
| diagnostics package | PASS | deterministic ZIP plus detached SHA verify |
| kind node identity | PASS by source review | v1.36.1 image is pinned by exact digest |
| runtime command audit | PASS | mutating/remote calls use bounded wrappers or bounded port-forward |

The deterministic fixture binary SHA-256 from this environment was:

`76b03a1bfdf49d4a44cb20769efc02b9b65400d7a310170734946eebb31d2f71`

## Not executed here

| Verification | Status | Reason / risk / next action |
| --- | --- | --- |
| Docker daemon check | BLOCKED_EXTERNAL | Docker CLI/daemon are absent in this execution environment |
| real kind create/reuse | NOT_RUN | requires Docker plus bootstrapped kind/kubectl |
| real positive smoke | NOT_RUN | requires the disposable cluster runtime |
| real negative smoke | NOT_RUN | requires the disposable cluster runtime |
| real cluster teardown | NOT_RUN | no live project cluster was created here |
| `make verify-runtime` | RED as expected | fails immediately because kind is unavailable |

## Security findings and disposition

1. Several kind, kubectl, Docker, and diagnostic calls had no outer bound. They
   now run through explicit timeout wrappers.
2. Namespace cleanup previously ignored deletion failure and never proved
   absence. It now polls a successful API query until the namespace is absent.
3. An arbitrary rollout failure previously satisfied the negative smoke. The
   test now requires the exact intentional startup marker.
4. Final cluster teardown previously ran only in a best-effort trap. It is now
   an explicit verification step whose failure keeps the result red.
5. Existing same-name clusters remain protected by context and in-cluster
   ownership checks. The local kubeconfig must also be a regular file.
6. Failure diagnostics previously buffered full command output before later
   truncation. Each capture is now stream-capped, leaves no temporary dump,
   and is packaged deterministically.

No remote, paid, production, Flare, or Poker infrastructure was created.

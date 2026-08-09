# ADR 0002: Quality and security profile

Status: candidate gates implemented; runtime proof required before merge

## Gate lifecycle

A gate moves through `PLANNED -> ADVISORY -> BLOCKING` only when it has:

1. a distinct useful signal;
2. an intentional RED case;
3. acceptable noise and false-positive behavior;
4. a clear owner;
5. bounded local and CI execution.

`make prove-gates` is the executable negative-proof contract for the initial static gates.

## Initial signals

| Signal | Tool | RED proof |
| --- | --- | --- |
| shell correctness | ShellCheck | invalid shell fixture |
| shell formatting | shfmt | normal source diff |
| workflow syntax | actionlint | invalid workflow fixture |
| workflow security | zizmor | unsafe workflow fixture |
| Dockerfile policy | Hadolint | unsafe Dockerfile fixture |
| secret detection | Trivy secret scanner | synthetic secret fixture |
| Kubernetes schema | kubeconform | invalid schema fixture |
| Kubernetes policy | KubeLinter | privileged workload fixture |
| commit contract | repository script | invalid Conventional Commit fixture |
| context safety | repository guard | unrelated-context fixture |

The same executable may provide more than one scanner, but each lane must keep a distinct failure
meaning. Expensive cluster checks are not part of the pre-commit path.

## Trivy boundary

Trivy is invoked as a pinned CLI installed through the project tool manager. This repository does not use
floating Trivy GitHub Action tags. The 2026 upstream supply-chain incident is treated as a permanent
reason to keep this boundary explicit and checksum/provenance aware.

A dedicated second secret scanner is not added merely to increase tool count. It should be introduced
only if it demonstrates a useful detection gap against the existing intentional RED corpus.

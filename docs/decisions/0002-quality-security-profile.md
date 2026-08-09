# ADR 0002: Quality and security profile

Status: local foundation proven; external tool lanes pending online replay

## Decision

Every gate must catch a distinct risk, have an intentional RED case, and remain
bounded. Similar tools are not added merely to increase scanner count.

A gate moves through `PLANNED -> ADVISORY -> BLOCKING` only after its RED proof,
noise, runtime cost, ownership, and failure meaning are understood. A command
may already fail closed on a candidate branch without implying that the gate
has been promoted into an organization-wide policy.

## Enforcement matrix

| Signal | Tool | Risk caught | Unique signal | RED | False-positive risk | Cost | Command | Maturity |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| source limits | policycheck | hidden giant source glue | exact 120/80 policy | long line/function | low | low | check-fast | BLOCKING |
| Go format | gofmt | noncanonical Go source | language-native formatting | unformatted Go | low | low | check-fast | BLOCKING |
| commit contract | repository script | untraceable history | exact Flare grammar | malformed messages | low | low | hook/prove-local | BLOCKING |
| shell correctness | ShellCheck | shell defects | semantic shell analysis | invalid shell | low-medium | low | check-fast | ADVISORY |
| shell format | shfmt | inconsistent shell layout | deterministic formatting | unformatted shell | low | low | check-fast | ADVISORY |
| workflow syntax | actionlint | invalid Actions YAML/expressions | GitHub workflow semantics | invalid workflow | low | low | check-fast | ADVISORY |
| workflow security | zizmor | unsafe Actions patterns | provider-aware security | unsafe workflow | medium | low | check-fast | ADVISORY |
| Dockerfile policy | Hadolint | unsafe/nonportable image recipe | Dockerfile semantics | unsafe Dockerfile | medium | low | check | ADVISORY |
| secret detection | Trivy secret | committed supported secrets | secret-oriented scan | synthetic secret | medium | medium | check | ADVISORY |
| Kubernetes schema | kubeconform | invalid resource shape | versioned schema validation | invalid resource | low | medium | check | ADVISORY |
| Kubernetes policy | KubeLinter | dangerous workload settings | workload security policy | privileged pod | medium | medium | check | ADVISORY |
| context identity | repository guard | mutation of unrelated cluster | exact local identity | unrelated context | low | low | prove-local/runtime | BLOCKING |
| lifecycle safety | repository fixture | unsafe delete/cleanup false green | ownership and absence proof | unowned/API failure | low | low | prove-local/runtime | BLOCKING |
| artifact integrity | repository helper | stale/tampered handoff | deterministic manifest boundary | tamper/home path | low | low | prove-local | BLOCKING |
| tool checksum admission | bootstrap guard | unchecked CI tool install | fail-closed CI admission | unlocked Aqua config | low | low | bootstrap/prove-local | BLOCKING |

The external tools remain `ADVISORY` in governance terms until an online Linux
amd64 replay executes every RED fixture and the real positive targets. They are
wired to fail the candidate CI intentionally; this prevents fake-green
promotion before the replay.

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

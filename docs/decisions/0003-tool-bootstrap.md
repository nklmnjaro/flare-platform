# ADR 0003: Project-local tool bootstrap

Status: accepted bootstrap candidate

## Decision

Use one pinned Aqua configuration as the source of truth for project CLI versions. Aqua itself is
bootstrapped as a pinned Linux amd64 release with a hard-coded SHA-256 check before execution.

All Aqua state lives under `.platform/aqua`; no global package-manager changes or `sudo` operations are
performed. The repository supports Linux x86_64 first.

Host prerequisites are deliberately small:

- Bash;
- Git;
- Make;
- curl;
- tar/gzip;
- sha256sum;
- sed;
- Docker for container/Kubernetes verification.

The project does not silently install or reconfigure Docker.

## Checksum admission

The bootstrap candidate keeps Aqua checksum verification enabled while `require_checksum` is temporarily
false only until the initial lock can be generated on an online host. `make tool-lock` generates and prunes
`aqua-checksums.json`, proves all configured packages install with required checksums, and then switches
`require_checksum` to true.

The checksum file and the resulting `aqua.yaml` change must be committed together before this repository is
promoted from `READY_AFTER_EXTERNAL_STEP` to `READY`.

## Network contract

First bootstrap requires outbound HTTPS to fetch pinned tools. Static schema/security checks may refresh
upstream data into `.platform/`. Kubernetes smoke itself does not pull a workload image from an external
registry: the image is built locally from a static Go binary and a `scratch` base.

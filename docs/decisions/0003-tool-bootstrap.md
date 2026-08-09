# ADR 0003: Project-local tool bootstrap

Status: implementation complete; checksum lock generation pending online host

## Decision

Use one pinned Aqua configuration as the source of truth for project CLI
versions. Aqua itself is bootstrapped as a pinned Linux amd64 archive with a
hard-coded SHA-256 check before execution.

All Aqua state lives under `.platform/aqua`; no global package-manager changes
or `sudo` operations are performed. The first supported host is Linux amd64.
The repository never installs or reconfigures Docker.

## Checksum admission

The initial local bootstrap may run with checksum collection enabled while
`require_checksum` is false. This exception exists only to generate the first
lock on a trusted online host.

CI fails before network access whenever `require_checksum` is not true. The
promotion sequence is:

```text
make bootstrap
make tool-lock
make bootstrap
```

`make tool-lock` updates `aqua-checksums.json`, verifies installation with
required checksums, atomically enables `require_checksum`, and verifies again.
On failure it restores the prior config and checksum file. Both files must be
committed together.

## Host prerequisites

`make doctor` verifies the small set of host utilities used by the canonical
scripts. Docker is additionally required only for runtime verification. Tool
versions used by static checks and kind are installed project-locally by Aqua.

## Network contract

The first bootstrap requires outbound HTTPS to fetch pinned assets. Static
schema/security tools may populate caches below `.platform/`. The Kubernetes
smoke image is built locally and loaded directly into kind; it is not pushed to
or pulled from an external registry.

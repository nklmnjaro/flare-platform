# ADR 0003: Project-local tool bootstrap

Status: checksum lock committed; integrated and clean bootstrap verified

## Decision

Use one pinned Aqua configuration as the source of truth for project CLI
versions. Aqua itself is bootstrapped as a pinned Linux amd64 archive. The
archive and extracted binary have separate pinned SHA-256 values, and a cached
binary must match the binary hash before any version or install execution.

All Aqua state lives under `.platform/aqua`; no global package-manager changes
or `sudo` operations are performed. The first supported host is Linux amd64.
The repository never installs or reconfigures Docker.

## Checksum admission

The verified lock is committed in `aqua-checksums.json`, and `aqua.yaml` has
exactly one `require_checksum: true` setting. CI fails before network access if
that setting is absent or false. Ordinary development and CI use only:

```text
make bootstrap
CI=true make bootstrap
```

`make tool-lock` is a trusted maintainer operation, not an ordinary install
step. Run it only after an intentional package-version change:

```text
make tool-lock
git diff -- aqua.yaml aqua-checksums.json
make bootstrap
CI=true make bootstrap
```

`make tool-lock` updates `aqua-checksums.json`, verifies installation with
required checksums, atomically enables `require_checksum`, and verifies again.
On failure it restores the prior config and checksum file. Both files must be
committed together.

The integrated lock baseline is commit
`a863afe410ed905eb75ffc0bc19d2572ce04e27f`. At this decision update, the
committed lock-file identities are:

- `aqua.yaml`:
  `b5289b2c824b6dce88a4fc0ffac93f7442e93f52f2f37fd68fe62edfca4f4a51`;
- `aqua-checksums.json`:
  `76fc0524b91810dae828e960758567a69a39283f310a614143e84f2beb4f7705`.

Both ordinary and `CI=true` bootstrap returned zero in the integrated checkout
and in a clean replacement-worker clone of
`42e877c489afe8347e4f5a797d453838c95a59c0`. The clean replay acquired Aqua and
all locked tools from empty project-local state before running the gates.

## Host prerequisites

`make doctor` verifies the small set of host utilities used by the canonical
scripts. Docker is additionally required only for runtime verification. Tool
versions used by static checks and kind are installed project-locally by Aqua.

## Network contract

The first bootstrap requires outbound HTTPS to fetch pinned assets. Static
schema/security tools may populate caches below `.platform/`. The Kubernetes
smoke image is built locally and loaded directly into kind; it is not pushed to
or pulled from an external registry.

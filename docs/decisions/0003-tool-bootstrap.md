# ADR 0003: Project-local tool bootstrap

Status: trust closure implemented; independent clean replay required

## Decision

Use one pinned Aqua configuration as the source of truth for project CLI
versions. Aqua itself is bootstrapped as a pinned Linux amd64 archive. The
archive and extracted binary have separate pinned SHA-256 values, and a cached
binary must match the binary hash before any version or install execution.

The pinned version, archive hash, binary hash, and exact-version verification
live in one sourceable Aqua trust module. Ordinary bootstrap and the maintainer
`tool-lock` operation use that same boundary. `tool-lock` verifies the cached
Aqua file type, executable mode, binary digest, and exact version before it
creates a backup, changes a tracked file, contacts the network, or executes an
update/install operation.

All persistent project Aqua state lives under `.platform/aqua`; no global
package-manager changes or `sudo` operations are performed. A bounded
environment observation may use a temporary Aqua root and must remove it
before returning. The current implemented OS/architecture pair is Linux
x86_64, admitted together with the exact capabilities in ADR 0006 rather than
by OS identity alone. The repository never installs or reconfigures Docker.

## Managed command admission

The following commands are project-managed and execute only through a validated
project-local entry below `.platform/aqua/bin`:

```text
go gofmt kind kubectl shellcheck shfmt actionlint zizmor
hadolint trivy kubeconform kube-linter prek
```

Admission requires the trusted cached Aqua binary and an executable project
entry whose resolved target remains below `.platform/aqua`. External PATH
entries are not fallbacks. Aqua configuration and checksums remain the source
of package-version truth; the admission boundary does not duplicate versions.

Bash, Git, curl, tar, timeout, Docker, and the small host-utility surface remain
host-owned. `make doctor` checks those prerequisites, including `readlink`,
without installing or changing them. Kubernetes proof fixtures create explicit
project-local mock entries in isolated temporary repositories; production
admission is unchanged.

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

Those statements describe the historical replay. Independent review of
`f2107559f3acad5cc5468b9e30e537c84add2c20` later revoked present promotion
because `tool-lock` and managed-command admission did not yet share these trust
boundaries. Promotion remains unclaimed until the closure receives a new plain
clone replay and independent acceptance.

## Host prerequisites

`make doctor` verifies the bounded host capabilities used by the canonical
scripts, Docker reachability for the normal path, and project bootstrap state
as separate results. It remains non-destructive. Tool versions used by static
checks and kind are installed project-locally by Aqua. See ADR 0006 for the
environment profile and the boundary between doctor and runtime proof.

## Network contract

The first bootstrap requires outbound HTTPS to fetch pinned assets. Static
schema/security tools may populate caches below `.platform/`. The Kubernetes
smoke image is built locally and loaded directly into kind; it is not pushed to
or pulled from an external registry.

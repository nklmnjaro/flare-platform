# Local platform development

## Prerequisites

The currently implemented environment is Linux x86_64, but OS identity alone
does not establish support. The host must satisfy the bounded command, GNU tar,
GNU timeout, `/proc`, Docker, and project-toolchain capabilities checked by
`make doctor`. Docker must resolve through the admitted external host-command
boundary to a reachable Linux amd64 daemon on a local Unix socket. System,
rootless, and Docker Desktop socket paths are accepted by capability rather than
by one hardcoded pathname. Remote Docker/BuildKit targets are unsupported.

## Bootstrap

```bash
make doctor
make bootstrap
make environment-evidence
make hooks
```

`make doctor` does not build or pull images, create clusters, or install tools.
On a pristine checkout it reports project bootstrap as ready to perform rather
than treating absent project tools as a host failure. Run `make bootstrap` to
install the locked project tools; the strict machine evidence command requires
that ready toolchain and then emits the exact ordered 35-record
`flare-platform-environment-v2` snapshot including admitted tool identities and
an invocation-specific local-Docker fingerprint. The fingerprint and complete
output digest describe that invocation and are not stable cross-host
identities. Actual Docker build/image mutation and kind behavior remain owned
by `make verify-runtime`.

Ordinary bootstrap uses the committed required checksums. The trusted maintainer
workflow for deliberately updating pinned tools is documented only in
`docs/runbooks/tool-updates.md`.

Normal managed-tool execution never falls back to PATH and is not an install
operation. It revalidates Aqua and its proxy, clears inherited exported
`AQUA_*` controls, exports only `AQUA_ROOT_DIR=<project .platform/aqua>`,
`AQUA_CONFIG=<project aqua.yaml>`, and `AQUA_DISABLE_LAZY_INSTALL=true` as Aqua
controls, and runs on the host-only PATH. If an installed package is absent, the
command fails; do not enable lazy installation to repair it. Run the ordinary
checksum-enforced `make bootstrap` instead.

## Fast feedback

```bash
make prove-local
make check-fast
```

Use this before commits. It avoids Kubernetes and heavyweight runtime verification.

## Full local proof

```bash
make verify
```

This runs static/security checks, proves intentional RED fixtures, admits and
freezes one external local Unix Docker target, creates a disposable kind
cluster on that same target, runs positive and negative workloads, captures
bounded diagnostics for the negative path, and tears the cluster down. Builds
use the exact admitted Docker executable and endpoint with empty per-call
Docker/Buildx configuration, `DOCKER_BUILDKIT=1`, and `--builder default`.

Persistent generated project state is under `.platform/`. Owned observation and
Docker child scratch may be created under the trusted temporary root and is
removed before the command returns. The project root, Aqua
executable-directory chain, and every project path used for a write or reset
must be real directories or regular files, not symlinks. Remove ordinary
generated state with `make clean`.

Canonical quality, hook, and Kubernetes scripts execute Aqua-managed commands
only through project-local entries below `.platform/aqua/bin`. An external PATH
command with the same name is never an accepted fallback. If a command reports
`project-managed toolchain unavailable or untrusted`, rerun `make bootstrap`
rather than installing an unpinned host copy.

If a command reports `FAIL  state-guard`, inspect the path before changing it:

```bash
ls -ld .platform .platform/aqua .platform/aqua/bin 2>/dev/null || true
find .platform -maxdepth 4 -type l -print 2>/dev/null || true
```

Do not run `rm -rf` on a path that may resolve outside the repository. After confirming a reported entry
is only a generated-state symlink, unlink the symlink itself and rerun the canonical command. If a kind
cluster may still exist, preserve the failure evidence and use `make kind-down` after restoring a real
project-local state directory.

If a command reports `FAIL  docker-target`, do not bypass it with raw Docker or
kind mutation. Check the caller's `DOCKER_HOST`, `DOCKER_CONTEXT`, and external
Docker configuration using read-only Docker context inspection. Remove an
unintended remote selection or inherited `BUILDX_BUILDER`, `BUILDKIT_HOST`, TLS,
or related remote controls in the caller environment, then rerun `make doctor`.
The boundary may inspect local context metadata to classify a target, but it
does not contact a rejected remote endpoint. A target fingerprint mismatch
means the executable or Unix socket identity changed during the canonical run;
start a fresh invocation only after independently understanding that change.

The guard prevents accidental and same-user symlink path escape. It is not a sandbox against a hostile
concurrent local user, bind mounts, or a compromised executable already trusted by the repository.

## Failure evidence

```bash
make diagnose
make artifact-verify ARCHIVE=.platform/platform-diagnostics.zip
```

The archive contains bounded Platform fixture diagnostics only. It is not a
generic product log collector.

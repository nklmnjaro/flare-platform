# Local platform development

## Prerequisites

The currently implemented environment is Linux x86_64, but OS identity alone
does not establish support. The host must satisfy the bounded command, GNU tar,
GNU timeout, `/proc`, Docker, and project-toolchain capabilities checked by
`make doctor`. Docker must be reachable for the normal doctor and Kubernetes
verification paths.

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
install the locked project tools; the strict machine evidence command then
emits a bounded path-safe snapshot including their admitted identities. The
heavier Docker and kind behavior remains owned by `make verify-runtime`.

Ordinary bootstrap uses the committed required checksums. The trusted maintainer
workflow for deliberately updating pinned tools is documented only in
`docs/runbooks/tool-updates.md`.

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

This runs static/security checks, proves intentional RED fixtures, creates a disposable kind cluster,
runs positive and negative workloads, captures bounded diagnostics for the negative path, and tears the
cluster down.

Generated state is under `.platform/`. The root, Aqua executable-directory chain, and every path used
for a write or reset must be real directories or regular files, not symlinks. Remove ordinary generated
state with `make clean`.

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

The guard prevents accidental and same-user symlink path escape. It is not a sandbox against a hostile
concurrent local user, bind mounts, or a compromised executable already trusted by the repository.

## Failure evidence

```bash
make diagnose
make artifact-verify ARCHIVE=.platform/platform-diagnostics.zip
```

The archive contains bounded Platform fixture diagnostics only. It is not a
generic product log collector.

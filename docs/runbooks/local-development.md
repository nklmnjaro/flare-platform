# Local platform development

## Prerequisites

Use a Linux x86_64 host with Git, Make, curl, tar, gzip, sha256sum, and Docker. Docker must be running for
Kubernetes verification.

## Bootstrap

```bash
make doctor
make bootstrap
make tool-lock
make bootstrap
make hooks
```

The second bootstrap is intentional and must succeed with committed required checksums.
`make tool-lock` is needed only when creating or deliberately updating the lock.

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

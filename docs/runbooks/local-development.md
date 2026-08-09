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

Generated state is under `.platform/`. Remove it with `make clean`.

## Failure evidence

```bash
make diagnose
make artifact-verify ARCHIVE=.platform/platform-diagnostics.zip
```

The archive contains bounded Platform fixture diagnostics only. It is not a
generic product log collector.

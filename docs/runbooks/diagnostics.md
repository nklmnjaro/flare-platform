# Collecting Platform diagnostics

Run:

```bash
make diagnose
```

The command creates one current run. It does not append to history or mix files
from multiple invocations.

## Successful capture

Success publishes:

```text
.platform/platform-diagnostics.zip
.platform/platform-diagnostics.zip.sha256
```

Verify the pair before upload or review:

```bash
make artifact-verify ARCHIVE=.platform/platform-diagnostics.zip
```

The packaged `capture-status.txt` must contain exactly five records:

```text
schema=flare-platform-diagnostics-capture-v2
state=complete
run_id=sha256:<64 lowercase hex>
head=<exact source commit>
tree=<exact source tree>
```

`platform.txt` must use `schema=flare-platform-diagnostics-v3` and repeat the
same run ID. Treat those records, the internal manifest, and detached checksum
as one evidence identity.

Live Kubernetes output may change across captures. Do not compare two live ZIP
hashes as a health gate. Verify each capture's structure, manifest, run identity,
freshness, bounds, and internal consistency. Byte equality remains required for
the repository's controlled synthetic determinism fixtures.

## Privacy and Kubernetes scope

External bytes are sanitized before their first durable write. The supported
grammar removes supported keyed authorization/password/secret/token values,
supported workstation paths, ANSI controls, NUL, invalid UTF-8, and other
unsupported control bytes. Logical lines and the complete durable payload are
bounded.

This is a narrow Platform fixture contract, not generic DLP. Never feed it
credentials, kubeconfig, arbitrary binary data, Flare customer payloads, or
Poker test data.

Kubernetes payload collection first requires the exact project context and
checkout-bound ownership. A foreign checkout receives a fixed refusal
before payload reads. The collector is limited to nodes and the
`flare-platform-reference` namespace and does not read Secrets, ConfigMaps,
`describe`, raw object dumps, or arbitrary namespaces.

The collector is read-only and does not acquire the mutating lifecycle lease.
If an owned teardown races a query, collection fails boundedly and resets the
whole Kubernetes staging directory; no partial payload is accepted. The parent
collector may still publish a complete current pair containing the sanitized
Platform summary and a fixed Kubernetes refusal/failure status only.

## Failure behavior

The previous mutable ZIP/SHA pair is removed before new current collection.
A Kubernetes authorization or query subfailure is a supported degraded capture:
it discards the whole Kubernetes payload staging directory, records only a fixed
sanitized status, and may publish a valid host/status-only current pair.

When the overall capture, sanitization, raw publication, packaging,
verification, or final publication fails, no valid current pair remains.
Bounded partial raw evidence may remain with a non-complete state for local
troubleshooting, but it is not review-ready.

Do not restore an older checksum beside a newer ZIP, copy older raw files into
the current run, or edit a partial archive. Fix the reported boundary and rerun
`make diagnose`.

Run the exact intentional RED proof with:

```bash
make prove-diagnostics
```

The proof covers stale-pair invalidation, pre-write sanitization, bounds,
controls, supported path and secret canaries, ownership-before-read, partial
failure cleanup, and synthetic determinism. See
`docs/contracts/platform-diagnostics-v2.md` for the normative contract.

# Platform diagnostics contract v2

Status: Task 008R1 integrated implementation and final special-path clean-clone
replays passed. The clean clone used commit
`74538648b307a36b1cf1b1163c4129664cdafeb8`, tree
`5738783d3e5ce9ce6c55c57da0e5572f3e861f9e`.

## Purpose

This contract governs the compact current diagnostic archive produced by
`make diagnose`. It supports failures of the Platform reference fixture without
turning this repository into a generic log collector, DLP product, or customer
observability system.

The archive may contain bounded repository and tool identity, owned local kind
status, and narrow output from the Platform reference namespace. It must not
contain kubeconfig, credentials, arbitrary environment or namespace dumps,
Secrets, ConfigMaps, Flare payloads, Poker test data, or unrestricted cluster
state.

## One run, one current publication

The mutable pair below means only the current successful invocation:

```text
.platform/platform-diagnostics.zip
.platform/platform-diagnostics.zip.sha256
```

Before a new capture reads diagnostic payload, it invalidates both entries and
replaces the complete raw run directory. An overall failed invocation therefore
leaves no valid current pair. It must not restore or retain an older mutable pair
under the same names.

Each run has a `sha256:<64 lowercase hex>` identity. `capture-status.txt` is an
exact five-record `flare-platform-diagnostics-capture-v2` document containing
schema, state, run ID, source `HEAD`, and source tree. The raw run moves through
`collecting`, `complete`, or `failed`; only `complete` may be packaged.
`platform.txt` uses `flare-platform-diagnostics-v3` and repeats the same run ID.
Raw data from an incomplete run is bounded local troubleshooting material, not
current review evidence. Immutable historical storage could preserve an older
run under a distinct identity, but no history subsystem is introduced here.

## Exact raw layout and source binding

The raw root is the canonical invoking-user-owned directory below project state
with mode `0700`. It has at most eight entries from this exact allowlist:

```text
capture-status.txt
platform.txt
kubernetes-status.txt
kubernetes/
kubernetes/nodes.txt
kubernetes/resources.txt
kubernetes/events.txt
kubernetes/logs.txt
```

Every file is a regular non-symlink file with mode `0600` and link count one.
The optional `kubernetes/` directory has mode `0700`. A collected Kubernetes
status requires all four command files; every other accepted status requires
the directory to be absent or empty. No other raw entry is packageable.

`platform.txt` has exactly 21 records in this order: schema, run ID, source
`HEAD`, source tree, branch, dirty-entry count, OS, architecture, the fixed
privacy declaration, then one record for each of `go`, `docker`, `kind`,
`kubectl`, `shellcheck`, `shfmt`, `actionlint`, `zizmor`, `hadolint`, `trivy`,
`kubeconform`, and `kube-linter`. A tool record has exactly one of these forms:

```text
tool.<name>=missing
tool.<name>=version-unavailable
tool.<name>=present | <identity>
```

`missing` means tool admission did not succeed. `present` requires successful
admission, exit zero from the exact bounded version command, sanitizer exit
zero, exact framing with `sanitizer_truncated=false`, and one nonempty bounded
sanitized first logical line. Single-line mode emits only that line but drains
the rest of producer output. Timeout, nonzero producer status, sanitizer
failure, truncation, empty output, or malformed/extra framing maps to the one
fixed `version-unavailable` value; failure payload is never a valid identity.

`kubernetes-status.txt` has exactly one of these records:

```text
cluster=not-inspected; kind or kubectl missing
cluster=not-inspected; kind query failed
cluster=absent; no Kubernetes payload collected
cluster=present; kubeconfig=absent-or-unsafe
cluster=present; inspection refused or failed; no raw command output retained
cluster=present; owned bounded inspection collected
```

The complete raw file set is capped at 548,864 bytes. `capture-status.txt` and
`kubernetes-status.txt` are each capped at 4 KiB, `platform.txt` at 16 KiB, and
each Kubernetes command file at 128 KiB. A command file starts with exactly a
zero exit-code record and a Boolean truncation record before its sanitized
payload.

Before assigning the run identity, the collector requires its trusted
executable dependency set, including the sanitizer and archive modules, to
match `HEAD`; tracked edits plus untracked or ignored executable source are
rejected. It then takes two equal bounded snapshots over source `HEAD`, tree,
branch, porcelain status, index, and worktree content and modes. The worktree
snapshot runs relative to the admitted physical source root and prunes the
literal relative entries `./.git` and `./.platform`; metacharacters in the
absolute root never enter `find` path matching. The snapshot accepts at most
20,000 entries, 1 MiB of path bytes, 64 MiB per file, and 256 MiB in total.

Those internal status, index, and worktree digests are rechecked before private
snapshotting, immediately before pair publication, and after pair publication.
A mismatch invalidates the pair. Only `HEAD`, tree, branch, and the dirty-entry
count enter the raw summary; the internal digests do not turn uncommitted bytes
into review evidence. The whole checkout need not be clean, but any admitted
non-executable dirty state must remain identical for the complete capture.

Every raw file is published by same-directory atomic rename from private
staging. Packaging occurs in a private directory. The canonical artifact helper
must verify archive structure, internal manifest, limits, and checksum before
the archive is moved to its final path. The detached checksum is published
last. An interrupted or failed run therefore cannot expose a stale or mixed
pair as current evidence.

The underlying artifact helper cannot publish two names in one filesystem
transaction: a checksum-publication failure may leave the newly published ZIP
without a sidecar. That incomplete output is never a current diagnostic pair;
the collector reports failure, and consumers require both names plus successful
pair verification.

This is process-interruption-safe publication. It is not a claim of
power-loss-durable filesystem transactions or multi-host serialization.

## Durable-write privacy boundary

External command bytes pass through the repository sanitizer before their
first durable write. Unsanitized output may exist only in bounded process memory
or a command pipe. It is never a staged fallback file under `.platform/`.

The sanitizer:

- replaces values for case-insensitive assignment/header keys containing
  `authorization`, `password`, `secret`, or `token`, and separated command
  flags containing `password`, `secret`, or `token`;
- replaces the exact checkout and current-home prefixes plus supported terminal
  Unix, macOS, root, and Windows home-directory forms;
- removes ANSI CSI/OSC sequences;
- removes NUL, invalid UTF-8, and remaining unsupported controls while
  preserving printable diagnostic context;
- bounds every logical input line; and
- bounds the complete durable payload, including metadata, without splitting a
  UTF-8 code point, while continuing to drain the bounded producer.

The sanitizer additionally caps every logical input line at 64 KiB. The file
and aggregate limits above include the metadata added after sanitization.

For an ordinary unquoted supported value, one token is replaced by
`<redacted>`. For an unquoted value beginning with case-insensitive `Bearer` or
`Basic`, followed by spaces or tabs and a credential token, the scheme and later
safe context are retained as `<scheme> <redacted>`. For a quoted value, the
quoted value is replaced by quoted `<redacted>`. Unquoted credential boundaries
are whitespace or `,`, `;`, `}`, `]`, and `&`; those boundaries and later safe
context remain readable. The accepted examples are:

```text
api_token: Bearer token-canary visible -> api_token: Bearer <redacted> visible
password: Basic password-canary visible -> password: Basic <redacted> visible
--access-token Bearer flag-canary -> --access-token Bearer <redacted>
{"client_secret":"Basic json-canary"} -> {"client_secret":"<redacted>"}
Authorization: Bearer authorization-canary -> Authorization: Bearer <redacted>
```

The grammar is deliberately narrow. It does not claim coverage for unkeyed
bearer/basic strings, arbitrary encodings, binary attachments, entropy-based
secrets, or unknown product-specific formats. Those inputs remain prohibited;
unknown unkeyed credential text is not silently changed or claimed as covered.

Command captures retain bounded exit and truncation metadata. A Kubernetes
authorization or query subfailure removes the whole Kubernetes payload staging
directory and may leave only a fixed sanitized status in an otherwise complete
current capture. An overall sanitizer, raw-publication, packaging,
verification, or final-publication failure leaves no current pair.

## Kubernetes read boundary

Kubernetes payload collection requires all of the following before the first
payload-producing `kubectl` call:

1. the project kubeconfig is a regular non-symlink file;
2. the context is exactly `kind-flare-platform-dev`;
3. the canonical checkout-bound ownership guard accepts the exact live marker;
4. queries remain limited to nodes and `flare-platform-reference`.

A same-name or same-context cluster without accepted ownership produces only a
fixed refusal status. Its workload output is not read. The allowed payload is
limited to node and namespace resource status, namespace events, and bounded
logs from the Platform reference deployment. It excludes `describe`, raw
object dumps, Secrets, ConfigMaps, kubeconfig, and arbitrary namespaces.

Minimizing reads is mandatory even though all accepted output is sanitized.
Sanitization is not authority to inspect foreign state.

The read-only collector does not acquire the mutating lifecycle lease. A
concurrent owned teardown can make an admitted query fail; that is a bounded
Kubernetes subfailure and resets the whole Kubernetes staging directory. It is
not accepted as partial Kubernetes payload, although the parent collector may
publish a complete host/status-only capture.

## Determinism and evidence identity

Controlled synthetic fixtures must produce deterministic bytes. Live
Kubernetes diagnostics can legitimately change because events, timestamps, and
runtime observations change. Two live captures are therefore not required to
have equal archive bytes.

A live capture is accepted by its canonical structure, exact internal manifest,
run identity, current-run freshness, bounded fields, and internal consistency.
Archive SHA-256 identifies those exact observed bytes; it does not assert that a
later live observation will be byte-identical.

## Verification

`make prove-diagnostics` and its canonical callers must prove at least:

- stale raw data and a stale mutable ZIP/SHA pair cannot become current;
- overall failed capture and failed prepublication leave no current pair;
- every packaged raw file belongs to one complete run identity;
- the raw root, exact allowlist, modes, link counts, schemas, and aggregate
  budget reject any noncanonical input;
- trusted executable source differs from `HEAD` before collection, and a later
  tracked edit or untracked Go-source race leaves no current pair;
- literal state-path pruning remains selective under a source root containing
  spaces and `#[]&`: `.git` or `.platform` mutations leave the digest unchanged,
  while a tracked-file mutation changes it;
- supported simple and compound keyed/flag secret, path, ANSI, NUL, invalid
  UTF-8, and control canaries do not survive stdout, staging, final archive,
  checksum-side metadata, failure evidence, interrupted residue, or another
  durable write while useful context remains;
- failed, timed-out, empty, truncated, sanitizer-failed, or malformed tool
  identity probes cannot become `present`, while successful multiline probes
  publish only the first logical line and are fully drained;
- logical-line and total-payload bounds remain valid UTF-8 and record
  truncation;
- an ownership refusal occurs before Kubernetes payload reads and leaves no
  partial payload;
- symlink, partial, manifest, and checksum failures are exact RED cases; and
- synthetic fixtures are byte-deterministic without imposing that invariant on
  two live observations.

Trivy secret scanning remains a separate signal over committed repository
content. The diagnostics gate owns generated runtime evidence before its first
durable write. Neither signal is generic DLP.

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

Each tool record is `missing`, `version-unavailable`, or `present | <identity>`.
The last form requires successful admission, version-command exit zero,
sanitizer exit zero, exact untruncated framing, and one nonempty bounded first
logical line. Multiline output is drained after that line. A failed or timed-out
producer, sanitizer failure, empty output, truncation, or malformed/extra frame
is reported only as `version-unavailable`; its payload is not tool identity.

Live Kubernetes output may change across captures. Do not compare two live ZIP
hashes as a health gate. Verify each capture's structure, manifest, run identity,
freshness, bounds, and internal consistency. Byte equality remains required for
the repository's controlled synthetic determinism fixtures.

## Privacy and Kubernetes scope

External bytes are sanitized before their first durable write. Case-insensitive
assignment/header keys containing `authorization`, `password`, `secret`, or
`token`, and separated flags containing `password`, `secret`, or `token`, are
supported. An ordinary unquoted value becomes `<redacted>` through its first
whitespace or `,;}]&` boundary. A keyed or flagged unquoted `Bearer`/`Basic`
compound becomes `<scheme> <redacted>` and retains later safe context. A quoted
value becomes quoted `<redacted>`, preserving readable JSON-like delimiters.
Supported workstation paths, ANSI controls, NUL, invalid UTF-8, and other
unsupported control bytes are also removed. Logical lines and the complete
durable payload are bounded, and producer input continues to be drained.

Unknown unkeyed bearer/basic strings, arbitrary encodings, binary attachments,
entropy-based secrets, and product-specific formats are prohibited input. The
sanitizer does not silently claim them as covered.

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

The proof covers stale-pair invalidation, pre-write sanitization, the supported
simple and compound credential grammar, absence of canaries from all durable
surfaces, bounds, controls, ownership-before-read, partial failure cleanup, and
synthetic determinism. Tool-identity RED cases cover producer status `42`,
timeout, sanitizer failure, empty success, malformed/extra framing, successful
multiline draining, and oversized bounded draining. See
`docs/contracts/platform-diagnostics-v2.md` for the normative contract.

Special-root coverage is literal rather than pattern-based. Under a
`source [x] #[]&` fixture, `.git` and `.platform` mutations must leave the source
digest unchanged, while a tracked-file mutation must change it. A pre-fix direct
clean clone reached step 6 and returned status `2` from
`make prove-diagnostics` after `91s`: the immediate failure was a proof assertion
whose full-root `find ! -path` operand misclassified its existing sentinel.
Investigation also found full-root `find -path` operands in the production source
snapshot. The proof now scopes sentinel checks to one synthetic directory;
production changes directory to the admitted source root and prunes literal
`./.git` and `./.platform` entries. The focused privacy proof retained 17 positive PASS
records, including the selective snapshot assertion.

The integrated implementation replay before the final documentation amendment
on `72f3f1ad22c1f2ebdf4063e587a4f71390ec8ef5` retained
`make prove-diagnostics` at `39s`, two fresh `make diagnose` runs at `42s` and
`41s`, and artifact verifications at `0s` then `1s`. The final special-path clean
clone later retained diagnostics at `40s`, two diagnoses at `41s` each, and both
artifact verifications at `0s`. These are local acceptance results, not
production or release promotion.

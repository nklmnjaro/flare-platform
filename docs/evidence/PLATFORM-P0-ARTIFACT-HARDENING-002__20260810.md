# PLATFORM-P0-ARTIFACT-HARDENING-002

Date: 2026-08-10

Starting baseline:
`ddb7366bf140ba1b274bd93d8ca17ce749ac1d76`

Status: implemented and offline-verified

## Confirmed pre-fix defects

The previous helper was exercised before modification. Four behaviors were
reproduced:

1. A binary payload containing NUL bytes and `/home/alice/...` was accepted
   because leakage inspection skipped all non-text payloads.
2. A symlink used as the source directory returned success and emitted an empty
   manifest-only archive instead of packaging or rejecting the target tree.
3. A pre-created `output.zip.tmp` symlink was followed by `O_TRUNC`; its target
   sentinel file was overwritten with ZIP bytes.
4. A correctly checksummed DEFLATE archive was accepted. Verification used
   unbounded `io.ReadAll`, leaving compressed-input resource exhaustion outside
   the claimed bounded-artifact contract.

A fifth functional defect was found during repair: the verifier rejected every
nested file ending in `.zip`, although a self-contained review pack legitimately
needs to carry source/review archives. The outer archive is already excluded by
the output boundary; nested archives are not self-reference.

## Repair

The small Go helper remains the only artifact implementation. It now:

- rejects source, payload, output, checksum, and verification-input symlinks;
- resolves output parents before checking that output is outside the source;
- uses unpredictable temporary files rather than `<output>.tmp`;
- scans raw payload bytes, including binary content, for bounded home-path forms;
- accepts only sorted, uncompressed, normalized ZIP entries;
- validates sorted, newline-terminated manifests and exact lowercase SHA-256;
- streams outer-file hashing instead of loading the complete ZIP into memory;
- bounds entry count, paths, each file, total payload, manifest, and outer ZIP;
- permits nested ZIP evidence while still prohibiting manifest self-reference;
- self-verifies the unpublished archive and the detached checksum.

The former 341-line mixed-responsibility file was split into policy, path,
packing, verification, and checksum units. No generic artifact framework,
registry, compression policy, signing service, or remote store was introduced.

## Intentional RED and positive evidence

The Go suite proves rejection of:

- tampered payloads;
- mutated detached checksums;
- textual and binary home paths;
- symlink source/output/checksum/verification inputs;
- output-parent boundary escape through a symlink;
- DEFLATE entries;
- configured entry, payload, entry-count, and outer-file excess;
- noncanonical ordering and metadata where covered by the verifier.

It also proves:

- deterministic repeated packing;
- no clobber through the historical predictable temporary filename;
- nested ZIP inputs are supported;
- normal pack plus internal and detached verification remains green.

## Checks

Executed locally:

- `go test -race -count=1 ./...` for the archive module;
- `go test ./...` and `go vet ./...` for all three Go modules;
- project source line/function policy;
- `gofmt` diff check;
- Bash syntax check;
- `git diff --check`;
- `make prove-local` after integration.

External scanners and live Docker/kind verification are intentionally unchanged
and remain owned by `PLATFORM-PROMOTION-ONLINE-001`.

## Follow-up

The canonical entry-level repair was subsequently extended by
`PLATFORM-P0-ARTIFACT-CANONICAL-BYTES-004` after independent review found
accepted bytes outside ZIP entries and nonportable path forms. Evidence 004 is
part of the current artifact boundary and does not invalidate the defects or
checks recorded here.

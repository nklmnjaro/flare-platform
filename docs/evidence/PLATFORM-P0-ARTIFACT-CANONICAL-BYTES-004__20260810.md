# PLATFORM-P0-ARTIFACT-CANONICAL-BYTES-004

Date: 2026-08-10

Starting baseline:
`e5b5d7f204ba584c900211fc0d2ed427040d6c7c`

Status: implemented and offline-verified

## Confirmed pre-fix defects

Three independent bypasses were reproduced against the starting baseline.

First, a valid Platform ZIP was prefixed with:

```text
HIDDEN-PREFIX /home/alice
```

The detached checksum was recomputed. `artifact-verify` returned success.
Repeating the experiment with the same bytes appended after the ZIP also
returned success. ZIP readers permit self-extracting prefixes and tolerated
suffixes, while the verifier inspected only parsed entries. Those extra bytes
were not represented by `MANIFEST.sha256` and bypassed the home-path policy.

Second, a Linux source tree containing the literal filename
`..\\escape.txt` packed and verified successfully. Backslash is an ordinary
Linux filename byte but a path separator for common Windows extractors.
`C:/escape.txt` was likewise accepted by the verifier as a drive-prefixed ZIP
path.

Third, payloads ending exactly in `/home/alice` were accepted because the
supported home-path expression required a trailing separator. Equivalent
terminal macOS, root, and Windows home-directory forms had the same gap.

## Repair

The verifier now reconstructs the already bounded, validated entries using the
same normalized writer and compares the complete archive byte stream through a
streaming exact-comparison writer with a fixed 64 KiB buffer. Any prefix, suffix,
gap, alternate metadata encoding, or other byte not emitted by the canonical
writer fails verification.

This adds one bounded O(n) comparison without a second archive-sized memory or
disk copy. It does not add another archive format, signing service, registry, or
remote artifact store. The payload remains within the existing 128 MiB semantic
verification bound.

A shared portable path validator now applies to source packing, ZIP entries,
and manifest entries. It rejects:

- control bytes;
- backslashes;
- absolute and noncanonical slash paths;
- parent traversal;
- Windows drive prefixes.

The supported workstation-home policy now catches terminal `/home/<user>`,
`/Users/<user>`, `/root`, `C:\\Users\\<user>`, and
`C:/Users/<user>` forms while retaining the existing HTTP URL false-positive
guard.

## Intentional RED and positive evidence

The Go suite proves rejection of:

- hidden bytes before and after a valid normalized ZIP;
- a backslash-bearing Linux source filename;
- backslash and drive-prefixed paths in externally supplied ZIPs;
- terminal Unix, macOS, root, and Windows home-directory forms.

Existing deterministic pack, nested archive, manifest, tamper, symlink,
compression, metadata, and resource-limit tests remain green. Direct CLI
replays of all reproduced bypasses now fail with the intended reason.

## Reproducibility boundary

Canonical byte verification uses the repository-pinned Go toolchain and the
repository-owned normalized ZIP writer. The online promotion must therefore
replay artifact packing and verification after the Aqua checksum lock admits
the pinned Go version. A cross-version archive compatibility claim is not made
until that replay is recorded.

Nested ZIP files remain opaque payloads. Their outer bytes and filename are
bounded and hashed, but compressed internal content is not recursively scanned.
Platform-produced nested handoffs must be verified separately before staging.

## Checks

Executed locally:

- focused pre-fix CLI reproductions;
- focused post-fix CLI rejection replays;
- `go test -race -count=1 ./...` for the artifact module;
- `go vet ./...` for the artifact module;
- project source line/function policy;
- `gofmt` diff check;
- `git diff --check`;
- full `make prove-local` regression.

External scanners, the Aqua-pinned Go cross-version replay, and live
Docker/kind verification remain assigned to `PLATFORM-PROMOTION-ONLINE-001`.

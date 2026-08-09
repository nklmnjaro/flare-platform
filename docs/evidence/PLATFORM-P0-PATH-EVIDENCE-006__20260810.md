# PLATFORM-P0-PATH-EVIDENCE-006

Date: 2026-08-10

Starting baseline:
`67236576ec99da352f58ec82b379cb38f1309059`

Status: implemented and offline-verified

## Confirmed pre-fix defect

The artifact command accepted a safe source and correctly produced a canonical
archive, but its success line printed the complete output path. When the output
was placed below a normal developer home directory, the command emitted that
absolute workstation path into terminal and CI evidence.

That output contradicted the artifact policy: copying the otherwise useful log
into a handoff would either leak a username or make the packer reject its own
command evidence.

## Repair

Successful pack and verify commands now report the operation without echoing a
filesystem path. The caller already owns the requested output argument, so the
absolute path had no unique diagnostic value.

Errors retain useful context but pass through the same bounded workstation-home
expression used by artifact admission. Only supported home prefixes are replaced
with `<home>`; this is not a generic log-redaction or DLP subsystem.

## Regression evidence

The Go suite now proves that:

- pack and verify success output is exact and path-free;
- Unix, Windows, and root-account home prefixes are removed from diagnostics;
- suffixes after the redacted prefix remain available for debugging;
- the resulting diagnostic no longer matches artifact home-path admission;
- normal pack, detached checksum, and verify behavior remains unchanged.

## Checks

Executed locally:

- focused pre-fix CLI reproduction below a synthetic developer-home location;
- `go test -race -count=1 ./...` for the artifact module;
- `go vet ./...` for the artifact module;
- `make prove-integrity`;
- full `make prove-local` regression;
- repository source policy, gofmt, Bash syntax, and `git diff --check`.

External scanners and live Docker/kind verification remain assigned to
`PLATFORM-PROMOTION-ONLINE-001`.

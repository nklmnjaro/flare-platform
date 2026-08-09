# PLATFORM-P0-SOURCE-PACKABILITY-005

Date: 2026-08-10

Starting baseline:
`7cbc5c322f25a65c672035b3600da5487e88cbd5`

Status: implemented and offline-verified

## Confirmed pre-fix defect

The artifact scanner correctly rejects supported workstation-home forms, but
several tracked RED tests and evidence documents stored their synthetic canary
as one contiguous literal. Consequently, the Platform repository could not be
packaged through its own canonical artifact boundary even though the tests for
that boundary passed.

A nearby false-positive was also confirmed: the root-account expression treated
a hyphen after the word `root` as a home-path delimiter. Generated safety
fixture names using a `root-...` prefix could therefore be rejected despite not
containing a workstation path.

This was a contract contradiction rather than a reason to weaken scanning.

## Repair

Synthetic workstation-path canaries are now assembled only at test runtime.
Durable source and evidence retain the meaning of each test without embedding a
supported path literal.

The root-account boundary now accepts letters, digits, underscore, dot, and
hyphen as continuations. A terminal root home and a root home followed by a real
path delimiter remain rejected.

`make prove-integrity` now stages the repository's tracked and non-ignored
untracked files from the current working tree, packages them through the same
canonical helper, verifies the result, and removes the temporary artifact. This
prevents future tests or documentation from silently making Platform's own
review handoff impossible.

The proof is deliberately local and small. It is not a generic source exporter,
release packager, or replacement for the final changed-files review archive.

## Intentional RED and positive evidence

Before the repair, packing a stage containing the current tracked source failed
on a stored synthetic home-path canary.

After the repair:

- terminal Unix, macOS, root-account, and Windows home forms remain rejected;
- URL and ordinary `root-...` text do not trigger the bounded policy;
- the current Platform source packages and verifies through its own boundary;
- no `.git` or ignored `.platform` state enters the self-pack proof;
- deleted tracked files are omitted from the current-working-tree stage;
- source symlinks remain rejected by the canonical packer.

## Checks

Executed locally:

- `go test -race -count=1 ./...` for the artifact module;
- `go vet ./...` for the artifact module;
- `make prove-integrity`;
- full `make prove-local` regression;
- deterministic repeated source packaging;
- project source line/function policy;
- `gofmt` and Bash syntax checks;
- `git diff --check`.

External scanners and live Docker/kind verification remain assigned to
`PLATFORM-PROMOTION-ONLINE-001`.

# PLATFORM-P0-BASELINE-INTEGRITY-001 evidence

## Preflight

- Platform starting commit: `a6967d87e3555936ad707ee3c131ae7a205984b6`.
- Branch at intake: `main`; worktree clean.
- History source: the supplied Git bundle, not a reconstructed starter tree.
- Flare integration baseline inspected read-only:
  `19d004da25f0658b3e610899f04f086e3a441628`.
- Flare currently has only a thin `deploy/README.md`; no deployable product
  artifact or runtime contract exists at this baseline.
- No authoritative Poker repository was present in the supplied inputs.

## Reproduced integrity defect

The previous Platform owner pack failed its own `SHA256SUMS` for exactly four
files:

- `00_START_HERE.md`;
- `01_COPY_PASTE_PROMPT.md`;
- `02_CURRENT_FLARE_CONTEXT.md`;
- `PROMPT_TO_NEW_CODEX.txt`.

The remaining listed files verified. This proves the defect was stale pack
metadata after final content changes, not archive corruption in transit.

## Repair

A small standard-library Go packer now creates deterministic ZIP review
artifacts, writes a final-content manifest inside the archive, self-verifies the
result, and only then writes the detached archive checksum. It rejects symlinks,
unsafe paths, textual workstation home paths, non-normalized metadata, missing
or extra manifest entries, and content tampering.

The helper intentionally does not become a release, registry, provenance, or
artifact orchestration framework.

## Promotion rule

A Platform handoff is invalid unless both commands pass:

```text
make artifact-verify ARCHIVE=<handoff.zip>
sha256sum -c <handoff.zip.sha256>
```

# Review and handoff artifacts

Platform review material is staged in a directory and packaged through one
repository-owned command. The source directory must already contain the final
report, changed files, deletion metadata, and nested input archives that the
reviewer needs.

```bash
make artifact-pack SOURCE=/path/to/stage OUTPUT=/path/to/handoff.zip
make artifact-verify ARCHIVE=/path/to/handoff.zip
```

`artifact-pack` creates both `handoff.zip` and `handoff.zip.sha256`.
`artifact-verify` checks the internal manifest and the detached checksum.

## Publication contract

The packer:

- resolves the real source and output-parent boundaries before publication;
- rejects a source-directory symlink, nested symlinks, and special files;
- refuses symlink output and detached-checksum targets;
- uses unpredictable same-directory temporary files and atomic rename;
- accepts only portable forward-slash paths without control bytes or drive prefixes;
- sorts paths and uses fixed ZIP timestamps;
- stores entries without compression so verification cannot inflate a zip bomb;
- normalizes regular and executable modes to `0644` and `0755`;
- writes no owner, group, username, or absolute source-path metadata;
- scans textual and binary payload bytes for supported workstation home paths,
  including terminal home-directory forms without a trailing separator;
- computes `MANIFEST.sha256` only after source content is final;
- excludes the manifest itself and the outer output archive from that manifest;
- allows deliberately nested ZIP inputs when a self-contained handoff needs them;
- verifies the unpublished temporary archive before replacing the target;
- writes and re-verifies the detached checksum after archive publication.

The verifier requires the same canonical entry order, storage method, modes,
timestamps, path rules, manifest format, and resource limits as the packer. It
reconstructs the normalized ZIP into a streaming exact comparator and checks
the entire byte stream, rejecting hidden prefixes, suffixes, gaps, or alternate
ZIP encodings that are not represented by `MANIFEST.sha256`.

## Deliberate resource limits

This command packages compact review material, not container images or data
backups. The current hard limits are:

| Boundary | Limit |
| --- | ---: |
| files | 4096 |
| path length | 1024 bytes |
| one payload file | 64 MiB |
| combined payload | 128 MiB |
| manifest | 8 MiB |
| outer ZIP | 152 MiB |

Exceeding a limit is a failed handoff, not a reason to weaken the guard. Remove
unnecessary generated material or establish a separate approved artifact
contract for genuinely large evidence.

## Negative proof

`make prove-integrity` covers:

- content tampering and stale detached checksums;
- textual and binary workstation-path leakage;
- source and publication symlink boundaries;
- the historical predictable-temporary-file clobber path;
- compressed/noncanonical ZIP rejection and hidden prefix/suffix bytes;
- backslash and Windows drive-prefixed archive paths;
- terminal Unix, macOS, root, and Windows home-directory forms;
- per-entry, total-payload, entry-count, and outer-file limits;
- output boundary resolution through a symlinked parent.
- current tracked and non-ignored source can package through this same boundary.

The staging directory is disposable. Never edit an archive after packaging.
Recreate it from final staged content instead.

## Nested archive boundary

A deliberately nested ZIP is an opaque payload at this boundary. Its bytes and
outer filename are hashed and bounded, but its internal compressed content is
not recursively treated as another Platform handoff. Verify Platform-produced
nested handoffs separately before staging them. Do not use this helper as a
generic malware scanner or secret-management system.

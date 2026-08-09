# Review and handoff artifacts

Platform review material is staged in a directory and packaged through one
repository-owned command. The source directory must already contain the final
report, changed files, and deletion metadata that the reviewer needs.

```bash
make artifact-pack SOURCE=/path/to/stage OUTPUT=/path/to/handoff.zip
make artifact-verify ARCHIVE=/path/to/handoff.zip
```

The packer:

- sorts paths and uses fixed ZIP timestamps;
- normalizes regular and executable modes to `0644` and `0755`;
- writes no owner, group, username, or absolute source path metadata;
- rejects symlinks and textual workstation home paths;
- computes `MANIFEST.sha256` only after source content is final;
- excludes both the manifest itself and the output archive from that manifest;
- verifies the archive before publication;
- writes a detached `<archive>.sha256` after archive creation.

The staging directory is disposable. Never edit an archive after packaging.
Recreate it from final staged content instead. `make prove-integrity` executes
negative mutation tests for checksum mismatch and workstation-path leakage.

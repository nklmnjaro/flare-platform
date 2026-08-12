# ADR 0008: Repository continuity and recovery capsule

Status: accepted for the integrated Task 008 candidate; final replay pending.

## Context

Review ZIPs and independently supplied Git bundles did not establish one
authoritative recovery truth. `git bundle verify` alone is insufficient: a
bundle can omit an explicit usable `HEAD`, or a shallow source can appear
acceptable before direct materialization and full object-graph verification.
Ordinary bundles also do not preserve dirty worktree or hidden index state.

## Decision

Repository recovery uses one canonical directory with exactly three regular,
non-symlink files:

```text
MANIFEST.sha256
RECOVERY.json
repository.bundle
```

`repository.bundle` contains exactly explicit `HEAD` and the recorded named
branch, both resolving to one commit. `RECOVERY.json` binds schema, Git object
format, branch, commit, tree, full-history and clean-worktree claims, unsupported
state declarations, bundle filename, and bundle SHA-256. `MANIFEST.sha256`
binds the final identity and bundle bytes.

A source ZIP is not part of the capsule. Committed source is materialized from
the verified recovered commit, avoiding a parallel recovery truth. A review
archive may transport the capsule but does not replace semantic recovery
verification.

The bundle preserves reachable committed bytes verbatim. Recovery performs no
secret redaction: a credential, key, or token committed anywhere in reachable
history is part of the capsule.

## Source admission

Packing fails closed unless the source has:

- a named local branch whose ref equals `HEAD`;
- an exact stage-zero index equal to the recorded `HEAD` tree by path, object
  ID, and Git mode;
- a physical worktree whose regular-file bytes, executable state, and symlink
  targets reproduce those exact Git blob IDs and modes;
- one hard link for every tracked regular file and symlink;
- no extra physical entry outside the exact tracked tree, except the pinned
  non-symlink root `.git` directory and a root `.platform` directory that, when
  present, is non-symlink, mode `0700`, and owned by the effective user;
  ignored files do not receive another exception;
- no `assume-unchanged` or `skip-worktree` entries;
- no effective `filter.*` configuration, which is rejected before any
  attribute-consuming Git command can execute a configured clean/smudge
  process;
- a stable, bounded, one-link `.git/config` with no `include` or `includeIf`
  path, `extensions.worktreeConfig`, `core.alternateRefsCommand`, or `fsck.*`
  override, so external or weakened configuration cannot enter the source
  decision;
- full non-shallow, non-partial, non-promisor history;
- no `.git/objects/info/alternates` or `.git/commondir` indirection;
- no replace refs or legacy grafts;
- no submodule gitlinks, Git LFS attributes, or Git LFS pointer blobs anywhere
  in reachable history; and
- a green `git fsck --full --strict` before publication.

The raw worktree inspection uses descriptor-relative, no-follow opens and Git
blob framing for the repository object format (`sha1` or `sha256`); it does not
use `git status` as its clean-state authority. File, symlink, directory, and
aggregate observations are metadata-stable across each read and bounded by the
same path/file/tree budgets used for recovered materialization. Repository-local
ignore rules cannot hide an extra entry because the physical tree is walked
directly. `.platform` contents remain generated state outside the capsule, but
the directory itself must retain the project-private boundary above.

The source parent, root, and `.git` directories stay open while packing. Source
Git children receive held root and `.git` descriptors and explicit descriptor
paths for `--work-tree` and `--git-dir`; canonical-path reopens and directory
identities are rechecked. The repository config is read through the held `.git`
descriptor, bounded to 1 MiB, checked for stable metadata and bytes, and
rechecked around configuration-sensitive commands. The packer repeats source
inspection around staging and publication and refuses a changed path binding,
config, branch, commit, tree, clean-state, or supported-boundary observation.
Unsupported or raced state is not silently omitted.

## Git execution boundary

The Make entrypoints obtain Git through the final canonical host-command
admission boundary. That boundary resolves a file-type `git` from the caller
PATH captured before project environment publication, rejects shell and
project-state shadows, canonicalizes it, and passes the admitted absolute
executable to the recovery helper. The helper does not search PATH, accept a
relative or symlinked Git path, or execute a project-state shadow. Admission
does not establish package-manager, vendor, or root-ownership provenance.

Each bounded Git child runs as the leader of its own tracked process group with
sanitized Git, loader, configuration, hook, prompt, protocol, and lazy-fetch
controls. The runner captures Linux PID, process-group ID, and start time. On a
timeout, or when a normally terminal leader left a live descendant, it signals
only the still-owned identity with TERM, polls, escalates to KILL, reaps the
leader, drains bounded output, and requires two absent group observations. A
replaced leader is never signalled, and any descendant makes the Git command
fail even when cleanup succeeds.

The contract is this explicit Git-child boundary. It is not a universal claim
that a generic timeout kills arbitrary resistant descendants after ancestors
exit.

## Verification and publication

Verification requires:

1. the exact three-file capsule set as one-link regular files,
   `RECOVERY.json` at most 16 KiB, and the bundle at most 64 MiB;
2. an exact manifest and matching bundle digest in `RECOVERY.json`;
3. exactly explicit `HEAD` and the recorded branch in the bundle;
4. `git bundle verify` in a fresh bare repository;
5. a direct recovery clone in a special-character path;
6. exact object format, branch, commit, and tree identity;
7. a clean recovered worktree with no hidden or unsupported state;
8. bounded materialization limits; and
9. `git fsck --full --strict` over the recovered graph.

Before worktree materialization, the verifier rejects more than 100,000 files,
paths longer than 4 KiB, any file larger than 16 MiB, or a tree larger than
128 MiB. Reachable-history inspection accepts at most 250,000 objects, 100,000
trees, and 100,000 unique historical `.gitattributes` blobs, with each structural
Git output capped at 32 MiB. These are receiver resource bounds, not a general
repository quota.

Successful `git clone` alone is not recovery proof. Packing requires the output
name to be absent. The capsule is assembled and semantically verified through a
pinned private sibling directory, synchronized, and published with an atomic
same-parent `renameat2(RENAME_NOREPLACE)`. A pre-existing or concurrently
created destination is never replaced. Publication confirms the destination is
the same pinned directory and synchronizes its parent; it does not perform an
in-place update or a second post-rename semantic pass.

The bundle subprocess may continue producing stdout so that process cleanup can
finish normally, but a capped writer persists no more than exactly 64 MiB to the
pinned stage. Any additional byte marks overflow, rejects packing, and leaves no
published capsule. The size check on the completed file remains a second
defence; the limit is not merely a post-hoc rejection after an oversized write.

Verification also avoids reasoning over mutable path lookups. It opens the
non-symlink root and each exact one-link regular member without following links,
records their identities and bounded sizes, and copies those open files into a
private descriptor-pinned snapshot below the fixed root-owned sticky `/tmp`. It
then reopens the member names, requires the same inode and metadata observations
plus the exact file set, and runs manifest, identity, bundle, clone, history,
and object-graph verification against the snapshot.

Git HOME, the snapshot, and clone/fsck workspace are private pinned temporary
directories. Their complete expected top-level entries are identity-registered:
the Git template directory, the snapshot's exact three members, and the clone
workspace's `verify.git` plus restored checkout. Cleanup walks only held
directory descriptors and removes the original temporary name only if it still
resolves to the recorded inode; it does not recursively delete a replacement
path. A detected entry/name/identity mismatch makes the operation fail, preserves
a foreign replacement, and scrubs owned bytes even when their name moved. The
private publication stage uses the same pinned-name discipline. Any concurrent
change to a held source, stage, capsule, member, or registered temp observation
used for the recovery decision fails closed rather than selecting a new path
target.

This is a same-user race-hardening boundary, not a kernel-enforced sandbox from
another process with the same UID. Deterministic replacement at the implemented
inspection and cleanup barriers is rejected and preserves the replacement
victim. Name recheck followed by `unlinkat` is not an atomic
inode-conditioned-delete primitive, so a continuously hostile same-UID swap in
that final micro-window is deliberately not claimed as solved.

A transport ZIP must first pass the artifact boundary and then this semantic
verifier after extraction.

Because the artifact helper reserves root `MANIFEST.sha256`, a transport ZIP
packages a dedicated parent whose only child is the exact capsule directory;
it never passes the capsule itself as the artifact source.

Task 008 does not provide a canonical extraction command. Its supported local
recovery path is a direct capsule directory. A transported ZIP additionally
needs a separately trusted safe extractor until the checksum-first receiver
boundary is implemented in Task 009.

## Deliberate exclusions

This decision does not add a remote backup service, retention scheduler, object
storage, signing or key management, dirty-worktree recovery, submodule or Git
LFS recovery, source `.git/config` remotes/auth, local credential stores,
uncommitted credentials, hooks, `.platform` caches, Docker state, Kubernetes
state, or product deployment state. This exclusion does not remove any secret
already present in reachable committed history.

SHA-256 proves integrity relative to a received digest. Publisher authenticity
remains a separate future boundary.

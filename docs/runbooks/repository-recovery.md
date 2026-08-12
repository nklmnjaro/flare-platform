# Recovering the Platform repository

## Create and verify a capsule

Start from the final clean committed named branch after normal bootstrap:

```bash
make recovery-pack OUTPUT=.platform/recovery/capsule
make recovery-verify CAPSULE=.platform/recovery/capsule
```

The Make targets capture the caller PATH before publishing any project
environment, resolve only a file-type `git` from that exact captured path, and
pass it through the canonical host-command admission boundary. Admission rejects
shell aliases/functions and lookup, physical, or resolved locations inside the
repository, generated `.platform` state, or lifecycle state. It passes the
canonical absolute executable to the recovery helper. The helper revalidates a
canonical, symlink-free regular executable and never performs its own PATH
fallback.

For the documented in-state output, Make admits and creates the guarded
`.platform/recovery` parent. The helper requires every output parent to already
exist and does not create arbitrary parents.

This proves the executable boundary used by the invocation. It does not prove
root ownership, operating-system package provenance, or vendor authenticity.

Packing rejects detached HEAD, a `HEAD` tree/index mismatch, raw tracked bytes or
Git modes that do not match the index, tracked hardlinks, every extra worktree
entry outside root `.git` and guarded `.platform` (including ignored files),
hidden index flags, repository config includes, and any effective `filter.*`
configuration. The root `.git` must be the pinned non-symlink Git directory;
when `.platform` exists it must be a non-symlink mode-`0700` directory owned by
the effective user. Packing also rejects
shallow/partial/promisor history, replace/graft state, submodule gitlinks
anywhere in reachable history, current tracked paths whose cached `filter`
attribute is `lfs`, reachable historical Git LFS attributes or pointer blobs, a
source race, and an unsafe output boundary. Normalize the repository and create
a new committed candidate instead of weakening these checks.

Repository object alternates, common-directory indirection,
`extensions.worktreeConfig`, `core.alternateRefsCommand`, and `fsck.*`
configuration are unsupported. This keeps object enumeration and strict fsck on
the held repository metadata and prevents source configuration from weakening
or executing commands inside those checks.

Do not use a clean `git status` result as proof for this command. The helper
first requires the exact `HEAD` tree and stage-zero index to agree, then walks
the physical checkout through held directory descriptors without following
links. It hashes regular-file bytes with Git blob framing, checks executable
state and symlink targets, and requires one link per tracked leaf. Repository
ignore and `.git/info/exclude` rules cannot hide physical entries. Remove
ordinary ignored scratch outside `.platform`, remove configured Git filters,
remove repository `include`/`includeIf` paths, and replace hardlinked tracked
files with independent files before retrying.

The source parent, repository root, and `.git` directory remain descriptor-held
and identity-rechecked. Git children receive those held root/`.git` descriptors
as their explicit worktree and Git directory, so replacing the repository name
does not redirect a later source command. A changed canonical path binding or
metadata observation rejects the capture. `.git/config` must be a stable,
one-link regular file of at most 1 MiB; its bytes are retained in the source
identity and rechecked around configuration-sensitive commands.

The resulting capsule contains exactly:

```text
MANIFEST.sha256
RECOVERY.json
repository.bundle
```

The output path must not already exist. Packing verifies a pinned private sibling
before an atomic same-parent no-replace publication, confirms the published
directory identity, and synchronizes the parent. It never overwrites an old or
concurrently created capsule. Bundle stdout is physically capped at 64 MiB in
that stage; an over-limit producer is drained for bounded process handling, but
the overflow rejects packing and no capsule is published. Do not edit any entry
after packing; choose a new absent output path and rebuild it from the final
commit.

## Optional transport archive

The artifact helper reserves `MANIFEST.sha256` at its source root. Therefore do
not pass the capsule itself as `SOURCE`. After confirming that `capsule/` is the
only entry below `.platform/recovery`, package that parent as the wrapper:

```bash
make artifact-pack \
  SOURCE=.platform/recovery \
  OUTPUT=/path/to/flare-platform-recovery.zip
make artifact-verify ARCHIVE=/path/to/flare-platform-recovery.zip
```

The wrapper must contain only `capsule/` and its exact three files. The ZIP
manifest and detached checksum prove transport integrity. They do not replace
recovery semantics.

## Verify after receipt

1. Verify the received ZIP and detached checksum before using its contents.
2. Materialize it into a new directory using a separately trusted, bounded
   extraction procedure that rejects path traversal, links, and extra files.
3. Run semantic verification against that directory:

```bash
make recovery-verify CAPSULE=/path/to/unpacked/capsule
```

The verifier checks the exact three-file set, explicit bundle refs, identity and
digest, direct special-path materialization, clean state, bounded content, and a
full strict object-graph check. It uses the admitted absolute Git executable in
a sanitized environment. Every Git child leads an isolated tracked process
group. Timeout or a surviving descendant triggers exact-identity TERM, poll,
KILL, leader reap, bounded output drain, and two-sample group-absence checks.
Any descendant rejects the command even when it was successfully removed; a
replaced leader identity is never signalled.

Before semantic checks, verification pins the non-symlink capsule root and its
three one-link regular members without following links. It copies bounded bytes
from the open descriptors into a private descriptor-pinned snapshot below the
fixed root-owned sticky `/tmp`, then rechecks the exact names, inode identities,
and metadata. All semantic Git work runs against that snapshot.

Git HOME, the snapshot, and the clone/fsck workspace are private pinned
temporary directories. Their expected top-level entries are identity-registered
before use: Git HOME's template, the snapshot's exact three capsule members,
and the clone workspace's `verify.git` plus restored checkout. Cleanup walks only
the held directory, and removes its name only while that name still resolves to
the original inode. The publisher uses the same identity discipline for its
private stage. Temporary-name replacement cannot redirect semantic work, and
cleanup does not recursively delete the replacement. A detected cleanup
entry/name/identity mismatch fails the pack or verification operation, preserves
a foreign replacement, and scrubs the moved owned bytes; an emptied moved owned
directory may remain for manual removal. A concurrent source, stage,
capsule-member, hardlink, content, or metadata change that affects a recovery
observation is a rejection, not a request to retry against mixed observations.

These guards reject the deterministic swaps exercised at the recovery barriers,
but do not claim a sandbox against a continuously hostile process with the same
UID. Linux does not provide this code an atomic "unlink this name only if it is
still this inode" primitive; a same-UID swap in the final name-recheck/unlink
micro-window is outside this boundary.

The current bounds are 16 KiB for `RECOVERY.json`, 64 MiB for the bundle,
100,000 files, 4 KiB per path, 16 MiB per file, and 128 MiB for the recovered
tree. The reachable-history scan accepts at most 250,000 objects, 100,000 trees,
and 100,000 unique historical `.gitattributes` blobs. Each structural Git output
capture is capped at 32 MiB.

Verification creates only disposable local material. It does not add or change
a remote in the source checkout and does not contact remote infrastructure. A
disposable clone-local `origin` may name the local bundle path.

Task 008 provides pack/verify for the transport ZIP but no canonical extraction
command. Do not describe an arbitrary unzip as repository-provided verification.
The receiver-side checksum-first safe extraction boundary is deferred to Task
009; until then, direct capsule-directory handoff is the complete supported
local recovery path.

## Optional persistent clone outside the proof boundary

`make recovery-verify` is the repository-provided recovery proof. Its disposable
clone runs with the helper's sanitized configuration and is removed afterward.
A persistent recipient clone is a separate, recipient-owned procedure; the
following only creates history and deliberately performs no worktree checkout:

```bash
RECOVERY_GIT='/absolute/path/to/separately-admitted/git'
RECOVERY_EMPTY_CONFIG='/absolute/path/to/new-private-empty-directory'
GIT_CONFIG_NOSYSTEM=1 \
GIT_CONFIG_SYSTEM=/dev/null \
GIT_CONFIG_GLOBAL=/dev/null \
HOME="${RECOVERY_EMPTY_CONFIG}" \
XDG_CONFIG_HOME="${RECOVERY_EMPTY_CONFIG}/xdg" \
GIT_TEMPLATE_DIR="${RECOVERY_EMPTY_CONFIG}/template" \
GIT_TERMINAL_PROMPT=0 \
"${RECOVERY_GIT}" -c core.hooksPath=/dev/null clone --no-checkout \
  /path/to/unpacked/capsule/repository.bundle flare-platform
```

Replace the placeholder only after a recipient-owned admission procedure has
proved the absolute path is a canonical, symlink-free regular executable outside
the capsule, recovered checkout, and project-generated state. Do not derive it
from capsule content or a newly recovered project PATH. Create the empty config,
`xdg`, and `template` directories privately before the command and keep them
empty. Reuse the same empty system/global configuration for recipient identity
and `fsck` checks.

Do not present this history-only clone as equivalent to `make recovery-verify`.
Before any `checkout`, `reset`, build, or bootstrap, the recipient must establish
its own sanitized Git execution and review the recovered committed attributes.
The repository permits non-LFS filter attributes even though capsule packing
rejects every configured source `filter.*`; an ambient recipient filter with a
matching name could execute during worktree materialization. Persistent checkout
policy and subsequent command execution are outside the Task 008 proof boundary.

Compare branch, commit, tree, and object format with `RECOVERY.json`. The capsule
restores every byte in reachable committed history verbatim. If a secret,
credential, private key, or token was committed anywhere in that history, it is
inside the bundle and recovered clone; this boundary does not scan or redact Git
content. The capsule does not separately restore:

- `.platform` state or tool caches;
- the source checkout's `.git/config`, remote definitions, credential-helper or
  other local authentication configuration, and manually installed hooks;
- user/OS credential stores, SSH keys, or tokens that are not committed;
- ignored or uncommitted workstation files;
- Docker images, kind clusters, or Kubernetes objects; or
- Flare/Poker product deployment state.

The recipient clone may create a new local `origin` that points to the received
bundle. That is not a restored source remote and carries no source authentication
or push authority.

Recreate those only through their separately authorized project commands. If
sensitive bytes were committed, reject and remediate the source history rather
than treating capsule packaging as redaction.

## Failure handling

- `manifest mismatch`: reject the capsule and request a new one.
- `bundle refs are not exact`: reject missing explicit `HEAD` or extra refs.
- direct clone or `fsck` failure: reject incomplete history even if
  `git bundle verify` was green.
- identity mismatch: reject the handoff because no authoritative candidate is
  established.
- source clean-state failure: remove every extra entry outside root `.git` and
  guarded `.platform`, including ignored files; restore exact tracked raw bytes,
  mode, symlink target, and one-link ownership; restore the private `.platform`
  directory boundary; remove configured `filter.*` and repository config
  includes, object/common-directory indirection, and fsck/alternate-command/
  worktree-config overrides; then retry from the committed branch.
- Git descendant or process-group cleanup failure: preserve the bounded reason;
  do not accept the capsule while child absence is unproved.
- unsupported source state: fix the source and pack a new committed candidate.

Do not repair received capsule entries in place. A failure does not authorize
remote infrastructure, source-checkout, Docker, or Kubernetes mutation.

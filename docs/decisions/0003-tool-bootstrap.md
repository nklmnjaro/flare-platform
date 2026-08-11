# ADR 0003: Project-local tool bootstrap

Status: Closure-007 candidate implemented; final live and clean replay required

## Decision

Use one pinned Aqua configuration as the source of truth for project CLI
versions. Aqua itself is bootstrapped as a pinned Linux amd64 archive. The
archive and extracted binary have separate pinned SHA-256 values, and a cached
binary must match the binary hash before any version or install execution.

The pinned version, archive hash, binary hash, and exact-version verification
live in one sourceable Aqua trust module. Ordinary bootstrap and the maintainer
`tool-lock` operation use that same boundary. `tool-lock` verifies the cached
Aqua file type, executable mode, binary digest, and exact version before it
creates a backup, changes a tracked file, contacts the network, or executes an
update/install operation.

Normal managed-tool execution is a separate, non-installing boundary. Before
each call it revalidates the cached Aqua binary and exact version, the pinned
proxy digest, and the managed proxy link. It removes inherited exported
`AQUA_*` controls and exports exactly these Aqua variables to the child:

```text
AQUA_ROOT_DIR=<project .platform/aqua>
AQUA_CONFIG=<project aqua.yaml>
AQUA_DISABLE_LAZY_INSTALL=true
```

The child receives the host-only PATH. A missing installed package therefore
fails closed instead of triggering a lazy download or changing project Aqua
state. Ordinary check, verify, hook, and identity commands are not installation
or update boundaries.

All persistent project Aqua state lives under `.platform/aqua`; no global
package-manager changes or `sudo` operations are performed. A bounded
environment observation uses a temporary Aqua root for Aqua metadata,
`list`, and `which`, while treating the admitted project registries and package
bytes as inputs. The subsequent kind/kubectl version commands use the normal
sealed project execution boundary with lazy installation disabled. The
temporary root is removed before returning. The current implemented
OS/architecture pair is Linux x86_64, admitted together with the exact
capabilities in ADR 0006 rather than by OS identity alone. The repository never
installs or reconfigures Docker.

## Managed command admission

The following commands are project-managed and execute only through a validated
project-local entry below `.platform/aqua/bin`:

```text
go gofmt kind kubectl shellcheck shfmt actionlint zizmor
hadolint trivy kubeconform kube-linter prek
```

Admission requires the trusted cached Aqua binary and an executable project
entry whose resolved target remains below `.platform/aqua`. External PATH
entries are not fallbacks. Aqua configuration and checksums remain the source
of package-version truth; the admission boundary does not duplicate versions.

Bash, Git, curl, tar, timeout, `flock`, Docker, and the fixed small host-utility
surface remain host-owned by enforcement, not by PATH precedence. Here,
host-owned means that the caller search path is captured before project state is
published, the command is admitted as a canonical absolute regular executable,
and both its lookup location and resolved target are outside the checkout and
every `.platform` generated-state path. Shell aliases, functions, non-file command
types, repository targets, and project-generated substitutes are rejected.
Admitted commands are executed by their cached absolute paths, and process PATH
contains only canonical external host directories. This is not a claim that
every host executable is root-owned, package-manager-proven, or digest-pinned.

`make doctor` behaviorally checks the exact host surface it consumes, including
`readlink` and the non-blocking kernel-lock behavior used by `flock`, without
installing or changing those prerequisites. Kubernetes RED
proofs use an explicit adapter enabled only by the exact test contract and
confined to an owned temporary fixture root; production entrypoints cannot
select it.

The lifecycle lease is not managed-tool state. It is one deterministic
host-local rendezvous below `/tmp`, derived from a fixed Platform project and
cluster contract so separate same-user checkouts reach the same shared lock. The
host-command admission boundary explicitly excludes that generated lease root;
it cannot become a source of host executables. The lease directory and files
have their own owner, type, mode, link-count, descriptor, and inode checks.

## Checksum admission

The verified lock is committed in `aqua-checksums.json`, and `aqua.yaml` has
exactly one `require_checksum: true` setting. CI fails before network access if
that setting is absent or false. Ordinary development and CI use only:

```text
make bootstrap
CI=true make bootstrap
```

`make tool-lock` is a trusted maintainer operation, not an ordinary install
step. Run it only after an intentional package-version change:

```text
make tool-lock
git diff -- aqua.yaml aqua-checksums.json
make bootstrap
CI=true make bootstrap
```

`make tool-lock` updates `aqua-checksums.json`, verifies installation with
required checksums, atomically enables `require_checksum`, and verifies again.
On failure it restores the prior config and checksum file. Both files must be
committed together.

The integrated lock baseline is commit
`a863afe410ed905eb75ffc0bc19d2572ce04e27f`. At this decision update, the
committed lock-file identities are:

- `aqua.yaml`:
  `b5289b2c824b6dce88a4fc0ffac93f7442e93f52f2f37fd68fe62edfca4f4a51`;
- `aqua-checksums.json`:
  `76fc0524b91810dae828e960758567a69a39283f310a614143e84f2beb4f7705`.

Both ordinary and `CI=true` bootstrap returned zero in the integrated checkout
and in a clean replacement-worker clone of
`42e877c489afe8347e4f5a797d453838c95a59c0`. The clean replay acquired Aqua and
all locked tools from empty project-local state before running the gates.

Those statements describe historical replay only. Independent review of
`f2107559f3acad5cc5468b9e30e537c84add2c20` revoked promotion because
`tool-lock` and managed-command admission did not yet share the required trust
boundaries. The later verification-environment candidate
`51af7e09d975e5c50c2bcaf4c84c7027668b3d5c` was also rejected because
host-command admission, normal Aqua execution, local Docker selection, and the
pristine environment proof remained incomplete. Closure-006 continues from
that exact candidate and has an implementation snapshot at
`cbc68e9c019f87cc2420d7c0fea97271ca234918`; final live and clean-clone replay
remain pending. Closure-007 preserves those tool boundaries while adding
checkout ownership and the shared lifecycle rendezvous. The final combined live
and clean-clone replay remains pending, so promotion is still unclaimed.

## Host prerequisites

`make doctor` verifies the bounded host capabilities used by the canonical
scripts, admission of one external local Unix Docker target, read-only daemon
reachability, and project bootstrap state as separate results. It remains
non-destructive with respect to repository, image, and cluster state; owned
temporary scratch is removed before return. Tool versions used by static checks
and kind are installed project-locally only by explicit bootstrap. See ADR 0006
for the environment profile and the boundary between observation and runtime
mutation proof.

## Network contract

The first bootstrap requires outbound HTTPS to fetch pinned assets. Static
schema/security tools may populate caches below `.platform/`. The Kubernetes
smoke image is built locally and loaded directly into kind; it is not pushed to
or pulled from an external registry. Normal managed execution has Aqua lazy
installation disabled; only bootstrap and the maintainer-only tool-lock
workflow may acquire or update managed tool bytes.

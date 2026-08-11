# PLATFORM-EXECUTION-TRUST-AND-LOCAL-DAEMON-CLOSURE-006 evidence

Date: 2026-08-11

Status: `CANDIDATE; FINAL LIVE AND CLEAN-CLONE REPLAY PENDING`

Promotion: `NOT CLAIMED`

## Boundary and immutable source candidate

This record covers the local Linux x86_64 execution-trust and local-daemon
closure only. It does not authorize remote Docker/BuildKit, remote Kubernetes,
registries, cloud resources, production, hosted-CI behavior, or Flare/Poker
product changes.

Closure-006 starts from the independently rejected verification-environment
candidate:

```text
commit: 51af7e09d975e5c50c2bcaf4c84c7027668b3d5c
tree:   8950676b10c21b6081914b152af7b5dabbba6cc2
```

The current immutable implementation snapshot is:

```text
commit: cbc68e9c019f87cc2420d7c0fea97271ca234918
tree:   2c69dc3fbb6a18e9b5b350b4d1ab80ff907623b9
parent: fa0e970f6bcbdbd66355d1a917cc8fa8114b1eef
```

The documentation commit, final review archive, live runtime replay, and fresh
plain-clone replay do not yet exist in this record. The implementation identity
above is a source candidate, not a promotion identity.

`PLATFORM-VERIFICATION-ENVIRONMENT-005__20260811.md` remains historical. Its
candidate acceptance was revoked after independent reproduction of
project-state host-command impersonation, unsealed normal Aqua execution,
remote Docker/BuildKit acceptance, and a non-pristine environment proof. Its
28-record observation and other exact values are not evidence for Closure-006.

## Enforced execution boundaries

### Host commands

`tools/common/host-commands.sh` captures the caller search path before project
state is published. It rejects shell aliases/functions and non-file command
types, resolves and canonicalizes a regular executable, rejects lookup or
resolved targets inside the checkout or any `.platform` generated-state path,
and executes the cached absolute path. Project Aqua and bootstrap directories
are not placed on process-wide PATH.

For this contract, host-owned means external to repository/generated state. It
does not claim root ownership, package-manager provenance, or a digest for every
host utility. Behavioral capability admission remains a separate doctor check.
An external regular executable intentionally supplied by the caller can be a
host candidate; a repository-resolved target cannot.

The Makefile prevents inherited shell and Make controls from propagating into
recipes, and executed scripts sanitize them after entry. No claim is made that
the repository Makefile can neutralize a caller-provided `MAKEFILES` value
before GNU Make parses that value.

### Normal Aqua execution

Every normal managed-tool call revalidates the pinned Aqua binary digest and
exact version, the pinned Aqua proxy digest, and the managed proxy link. The
child environment removes inherited exported `AQUA_*` variables and publishes
exactly these Aqua controls:

```text
AQUA_ROOT_DIR=<project .platform/aqua>
AQUA_CONFIG=<project aqua.yaml>
AQUA_DISABLE_LAZY_INSTALL=true
```

PATH contains only admitted host directories. Missing installed packages fail
without implicit installation. Normal check, verify, hook, and identity paths
are non-installing; explicit `make bootstrap` and maintainer-only
`make tool-lock` remain the installation/update boundaries.

Doctor uses an owned ephemeral Aqua root for metadata, `list`, and `which`,
verifies the resolved kind/kubectl package bytes against
`aqua-checksums.json`, and removes the temporary root. The kind/kubectl version
commands use the normal sealed production wrapper with lazy installation
disabled; they are not described as executing with the ephemeral root.

### Local Docker, BuildKit, and kind

The production boundary resolves Docker through the host-command admission
module and requires its direct PATH lookup to equal the canonical admitted
executable. It determines the effective target from an explicit
`DOCKER_HOST`, explicit `DOCKER_CONTEXT`, or selected context and admits only an
absolute canonical external Unix socket. The implementation does not hardcode
`/var/run/docker.sock`, so normal system, rootless, and Docker Desktop local
Unix sockets can satisfy the same source contract.

TCP, SSH, HTTP(S), npipe, malformed endpoints, simultaneous host/context
selectors, inherited TLS settings, and remote Buildx/BuildKit controls are
rejected before runtime mutation or connection to the rejected endpoint.
Locally stored context metadata may be queried to classify the endpoint.

The invocation fingerprint binds the canonical Docker executable, canonical
Unix endpoint, and socket device/inode. Each Docker child gets the exact frozen
endpoint, `DOCKER_BUILDKIT=1`, host-only PATH, a non-existent HOME, and owned
empty per-call Docker and Buildx configuration. Runtime builds require
`--builder default`; kind runs with the same frozen Docker environment. This is
a daemon-default BuildKit selection contract, not a separately fingerprinted
BuildKit binary or version.

The explicit Docker fixture adapter requires its exact test contract and an
owned, path-confined temporary fixture root. Production entrypoints do not
select it.

## Environment-v2 invocation snapshot

A fresh bounded `make environment-evidence` observation of implementation
commit `cbc68e9c019f87cc2420d7c0fea97271ca234918` produced:

```text
schema:  flare-platform-environment-v2
records: 35
bytes:   1378
sha256:  e79bdd790b10f7350798d6667bd9f07ea479185f3b00fc607552b6c61ba61d14
```

This hash is an invocation snapshot, not a reproducible cross-host identity.
Observed tool versions, Docker versions, discovery mode, and the Docker target
fingerprint may differ on another admitted host. The schema, exact order,
grammar, record count, byte bound, path-safety rules, and semantics are the
deterministic contract.

The exact 35-key order is:

```text
SCHEMA
EVIDENCE_SEMANTICS
OBSERVATION_TIME_SEMANTICS
OS
ARCHITECTURE
BASH_VERSION
BASH_CAPABILITY
CURL_VERSION
CURL_CAPABILITY
COREUTILS_CAPABILITY
HOST_COMMAND_CAPABILITY
TAR_VERSION
TAR_CAPABILITY
TIMEOUT_VERSION
TIMEOUT_CAPABILITY
PROCESS_STATE_CAPABILITY
DOCKER_CLIENT_VERSION
DOCKER_SERVER_VERSION
DOCKER_CLIENT_API
DOCKER_SERVER_API
DOCKER_DAEMON_PLATFORM
DOCKER_BUILD_SURFACE
BUILDKIT_RESULT_PROOF
DOCKER_LOCAL_OPERATIONS
DOCKER_TARGET_TRANSPORT
DOCKER_TARGET_SCOPE
DOCKER_TARGET_FROZEN
DOCKER_TARGET_DISCOVERY
DOCKER_TARGET_FINGERPRINT
DOCKER_BUILDER_CONTRACT
KIND_DOCKER_CONTRACT
PROJECT_BOOTSTRAP_STATE
AQUA_IDENTITY
KIND_IDENTITY
KUBECTL_IDENTITY
```

The acceptance-sensitive static values are:

```text
SCHEMA=flare-platform-environment-v2
EVIDENCE_SEMANTICS=invocation_scoped_non_destructive
OBSERVATION_TIME_SEMANTICS=invocation_only_not_persisted
HOST_COMMAND_CAPABILITY=behavioral_exact_surface
BUILDKIT_RESULT_PROOF=parser_ready_runtime_execution_not_run
DOCKER_TARGET_TRANSPORT=unix
DOCKER_TARGET_SCOPE=local
DOCKER_TARGET_FROZEN=true
DOCKER_BUILDER_CONTRACT=daemon_default_required_runtime_not_run
KIND_DOCKER_CONTRACT=frozen_same_target_required_runtime_not_run
PROJECT_BOOTSTRAP_STATE=ready
```

Machine evidence requires a ready bootstrapped toolchain. A pristine human
doctor run instead reports `READY_FOR_BOOTSTRAP`; partial or untrusted project
state fails.

## Observation is not runtime mutation proof

Doctor behaviorally probes the host surface, queries local-daemon identity and
Docker help, validates the exact BuildKit-result parser, and observes project
tool identity. It creates only owned bounded scratch and removes it. It does not
build or pull images, inspect/remove workload images, query or mutate a kind
cluster, install tools, or mutate repository state.

The machine records deliberately state
`parser_ready_runtime_execution_not_run`,
`daemon_default_required_runtime_not_run`, and
`frozen_same_target_required_runtime_not_run`. Only `make verify-runtime` can
establish actual BuildKit build, local image inspect/removal, same-target kind
journeys, workload identity, and final teardown for an exact candidate.

## Acceptance still pending

This candidate record does not claim completion of:

- the canonical implementation-checkout matrix with explicit bounds;
- live `make verify-runtime`;
- two complete `make verify` runs;
- a completely clean direct clone replay of the final documentation commit;
- special-character checkout replay;
- final `git diff --check` and `git fsck --full --no-dangling`;
- a clean final worktree;
- a directly cloneable bundle with explicit HEAD/branch; or
- final archive checksum and independent acceptance.

Those results must be appended only after the immutable documentation commit
and actual executions exist. Until then the status remains `CANDIDATE` and
promotion remains unclaimed.

## bwrap statement

No `bwrap` execution or isolation result is claimed by Closure-006. The prior
005 writer note lacked a bounded durable transcript/checksum and is not reused
as current evidence. A future claim would require the exact candidate identity,
bounded command/stdout/stderr, exit status, line and byte counts, and checksums
in the review handoff.

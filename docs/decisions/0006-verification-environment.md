# ADR 0006: Capability-based verification environment

Status: Closure-006 candidate implemented locally; final live and clean replay required

## Decision

Platform support for the current local verification path is established by a
bounded capability profile, not by the broad label "Linux amd64 with Docker"
or by arbitrary host package-version pins.

The implemented OS and architecture remain Linux and x86_64. Admission also
requires the exact host behavior consumed by the repository:

- Bash process and strict-mode behavior used by bounded capture and cleanup;
- GNU tar deterministic ustar options used by the Docker stdin context;
- GNU timeout foreground, signal, and kill-after options;
- readable Linux `/proc/<pid>/stat` process state;
- the fixed required host command surface, admitted as canonical absolute
  executables outside the checkout and generated `.platform` state, with
  behavioral probes for every declared text, file, process, checksum, link,
  temporary-file, comparison, permission, and cleanup dependency;
- a reachable Linux amd64 Docker daemon selected only through an external local
  Unix socket, with the exact Docker executable and socket identity frozen for
  the invocation;
- rejection of remote or ambiguous Docker/BuildKit selectors before runtime
  mutation or connection to a rejected endpoint;
- the advertised Docker build surface, a daemon-default builder contract, and
  the exact BuildKit result grammar parsed by the runtime identity proof; and
- kind and kubectl identities admitted through the locked project toolchain.

`tools/bootstrap/environment-profile.sh` is the single executable source for
this profile and its evidence schema. Documentation describes its boundaries;
it does not maintain a second command or version registry.

The profile derives project tool identity from the trusted Aqua boundary. Aqua
metadata, `list`, and `which` observation use an ephemeral root while the
admitted project registry and package bytes remain inputs. The resolved kind and
kubectl package bytes must match their exact entries in
`aqua-checksums.json`. Their version commands then execute through the normal
sealed production wrapper: inherited exported `AQUA_*` controls are removed,
exactly `AQUA_ROOT_DIR=<project .platform/aqua>`,
`AQUA_CONFIG=<project aqua.yaml>`, and `AQUA_DISABLE_LAZY_INSTALL=true` are
exported as Aqua controls, and PATH remains host-only. The profile does not
accept a same-named PATH command, install a missing tool, or trigger Aqua lazy
installation while observing the environment. Its owned temporary root is
removed before return.

The shared Aqua trust module anchors checksum, path resolution, and timeout
operations in canonical executables admitted from the captured caller host path
before project state can participate. It also pins the Linux amd64 Aqua proxy
installed by Aqua 2.62.3:
proxy v1.2.13 has SHA-256
`0614f38f20377799ad36edb9a3e53c703546ed49ecf5ecd2e395379dd3a4bc3a`.
That digest has one executable source in `tools/bootstrap/aqua-trust.sh` and is
verified after `aqua install`. Aqua documents the proxy as the automatically
installed intermediary used by managed command links:
<https://aquaproj.github.io/docs/reference/lazy-install/>.

The doctor script clears inherited Bash, POSIX shell, Git, Make, tar, and gzip
control variables before its probes. Its entrypoint removes `BASH_ENV` and
`ENV` before starting privileged-mode Bash, and Git evidence calls disable
inherited/global/system configuration. The repository Makefile also stops these
controls from propagating to recipes. This claim begins after the selected
entrypoint starts: a caller-provided `MAKEFILES` value may affect GNU Make
before the repository Makefile is parsed, so it is not described as sealed by
the Makefile itself.

Host-owned is an execution-boundary term here: the lookup and canonical target
must be outside the current checkout and any `.platform` generated state, shell
aliases/functions and non-file command types are rejected, and calls use the
cached absolute executable. It is not evidence of root ownership,
package-manager provenance, or a digest for every host utility.

The Docker boundary resolves the exact host-admitted `docker` executable and
determines the effective endpoint from an explicit host, explicit context, or
the selected context. Context metadata may be inspected locally, but only an
absolute canonical external Unix socket is admitted. The path is not hardcoded,
so normal system, rootless, and Docker Desktop Unix sockets can satisfy the same
contract. TCP, SSH, HTTP(S), npipe, malformed endpoints, simultaneous host and
context selectors, TLS controls, and inherited Buildx/BuildKit remote controls
fail before daemon mutation. After admission, the canonical Docker path,
endpoint, socket device, and socket inode form an invocation-scoped fingerprint.
Docker and kind children use that exact endpoint, `DOCKER_BUILDKIT=1`, the
host-only PATH, and empty owned per-call Docker/Buildx configuration. Runtime
builds explicitly select `--builder default`; no separate BuildKit binary or
version identity is claimed.

## Fast observation and heavy proof

`make doctor` is fast and non-destructive. It performs no Docker build or pull,
workload-image inspect/removal, cluster query or mutation, bootstrap, or
repository-state mutation. It performs bounded local-daemon identity and Docker
help queries and removes its owned temporary scratch before return. It reports
host prerequisites, local-Docker reachability, frozen target identity, and
project bootstrap state separately. A pristine absent toolchain is
`READY_FOR_BOOTSTRAP` in the human result; partial or untrusted project state is
a failure.

`make environment-evidence` emits the bounded machine-readable result. The
`flare-platform-environment-v2` schema contains exactly 35 ordered records and
requires a ready bootstrapped toolchain. It includes invocation and observation
semantics, OS/architecture, Bash, curl, tar/coreutils, process-state, Docker
client/server, the advertised Docker build surface, exact BuildKit parser
readiness, local target transport/scope/discovery/fingerprint, daemon-default
builder and same-target kind contracts, and project tool identities. The
BuildKit and kind contract records explicitly say runtime execution was not run.
Time is invocation-scoped and not persisted, so the output does not invent a
reproducible timestamp. It excludes raw filesystem paths, usernames,
credentials, Docker configuration, and broad environment data. The target
fingerprint and complete output digest are evidence for one invocation, not
stable cross-host identities.

`make verify-runtime` owns behavior that requires mutation or substantial
work: deterministic stdin-tar and stale-context builds with network disabled
and pulls disabled, local image inspection/removal, disposable kind journeys,
and final teardown. It inherits and rechecks the same local-target fingerprint,
uses the exact admitted Docker executable and endpoint in child-shell build
pipelines, requires `--builder default`, and gives kind the same sealed Docker
environment. Doctor does not duplicate or claim those mutation proofs.

## Failure contract

The environment proof contains intentional RED fixtures for missing host
behavior, repository/generated-state command impersonation, inherited
shell/Git/Make/tar controls, unavailable `/proc`, unreachable or malformed
Docker, remote and ambiguous endpoints, remote builder controls, target drift,
a missing consumed BuildKit response, inherited Aqua policy/security controls,
lazy-install attempts, and absent or wrong project-managed kind/kubectl
identity. The ready-toolchain and Docker adapters require exact test-only
contracts and owned temporary roots. A fake command that merely exits zero is
not capability evidence, and each trust RED proves its exact status/reason plus
absence of the forbidden execution or mutation marker.

## Support statement

Mechanically supported means that the capability profile, canonical checks,
and local runtime journey pass for an exact repository revision. A version
observed on one verification host is evidence for that run, not a new minimum
host version. Hosted GitHub behavior, non-Linux systems, other architectures,
remote Docker/BuildKit, remote Kubernetes, cloud provisioning, registries, and
production remain unsupported, unverified, or out of scope until separately
authorized. The Closure-006 implementation snapshot is
`cbc68e9c019f87cc2420d7c0fea97271ca234918`; final live runtime and clean-clone
acceptance replay are still pending.

# ADR 0006: Capability-based verification environment

Status: implemented locally; final clean replay required

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
- the fixed required host command surface, with behavioral admission for every
  declared text, file, process, checksum, link, temporary-file, comparison,
  permission, and cleanup dependency;
- a reachable Docker daemon and the non-mutating client surfaces used by the
  runtime verifier;
- the advertised Docker build surface plus the exact BuildKit result grammar
  parsed by the runtime identity proof; and
- kind and kubectl identities admitted through the locked project toolchain.

`tools/bootstrap/environment-profile.sh` is the single executable source for
this profile and its evidence schema. Documentation describes its boundaries;
it does not maintain a second command or version registry.

The profile derives project tool identity from the trusted Aqua boundary. Aqua
registry/cache observation is redirected to an ephemeral root while project
package bytes remain read inputs. The resolved package bytes must match their
exact entry in `aqua-checksums.json`, then identity commands execute through
the admitted production proxy with the ephemeral root. This preserves runtime
path parity without project timestamp/cache writes. The profile does not
accept a same-named PATH command, install a missing tool, or trigger Aqua lazy
installation while observing the environment.

The shared Aqua trust module anchors checksum, path resolution, and timeout
operations in Bash's host-default command path before project PATH entries can
participate. It also pins the Linux amd64 Aqua proxy installed by Aqua 2.62.3:
proxy v1.2.13 has SHA-256
`0614f38f20377799ad36edb9a3e53c703546ed49ecf5ecd2e395379dd3a4bc3a`.
That digest has one executable source in `tools/bootstrap/aqua-trust.sh` and is
verified after `aqua install`. Aqua documents the proxy as the automatically
installed intermediary used by managed command links:
<https://aquaproj.github.io/docs/reference/lazy-install/>.

Doctor clears inherited Bash, POSIX shell, Git, Make, tar, and gzip control
variables before any probe. Its entrypoint removes `BASH_ENV` and `ENV` before
starting Bash. This prevents a caller from redirecting probe state or
injecting implicit shell, make, or tar behavior outside the owned temporary
workspace.

## Fast observation and heavy proof

`make doctor` is fast and non-destructive. It performs no Docker build or pull,
image removal, cluster operation, bootstrap, or repository-state mutation. It
reports host prerequisites, Docker reachability, and project bootstrap state
separately. A pristine absent toolchain is `READY_FOR_BOOTSTRAP`; partial or
untrusted project state is a failure.

`make environment-evidence` emits the bounded machine-readable result. The
fixed schema includes OS/architecture, Bash, tar/coreutils, process-state,
Docker client/server, the advertised Docker build surface, exact BuildKit
parser readiness with runtime execution explicitly not run, project tool
identities, and observation-time semantics. Time is invocation-scoped and not
persisted, so the output does not invent a reproducible timestamp. It excludes
filesystem paths, usernames, credentials, Docker configuration, and broad
environment data.

`make verify-runtime` owns behavior that requires mutation or substantial
work: deterministic stdin-tar and stale-context builds with network disabled
and pulls disabled, local image inspection/removal, disposable kind journeys,
and final teardown. Doctor does not duplicate those proofs.

## Failure contract

The environment proof contains intentional RED fixtures for missing tar and
timeout features, unavailable `/proc`, unreachable Docker, a missing consumed
BuildKit response, and absent or wrong project-managed kind/kubectl identity.
A fake command that merely exits zero is not capability evidence.

## Support statement

Mechanically supported means that the capability profile, canonical checks,
and local runtime journey pass for an exact repository revision. A version
observed on one verification host is evidence for that run, not a new minimum
host version. Hosted GitHub behavior, non-Linux systems, other architectures,
remote Kubernetes, cloud provisioning, registries, and production remain
unverified or out of scope until separately authorized.

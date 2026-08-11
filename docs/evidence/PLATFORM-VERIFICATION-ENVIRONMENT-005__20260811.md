# PLATFORM-VERIFICATION-ENVIRONMENT-005 evidence

Date: 2026-08-11

Status: `CANDIDATE OBSERVED; FINAL CLEAN REPLAY PENDING`

## Boundary and start gate

This record covers the local Linux x86_64 verification environment only. It
does not authorize production, remote infrastructure, registries, cloud
resources, hosted-CI claims, or Flare/Poker product changes.

Implementation began from commit
`a8b6a2262e981eb92a743f17d42b179b3be54d38`, tree
`6dd8d2bac90a97728484341877956fbe63631dee`. The required trust/toolchain
closure is the four-commit series `456d931`, `e5c74c2`, `4a16446`, `2179941`.
Its directly cloneable bundle has SHA-256
`e8c10849e112d54d0358fc628efa464235f131361fa7dc262cf08a767741f9fc`.
Queued documentation commits `6f05d9b`, `80c3dff`, and `a8b6a22` were applied
before this Change began.

## Observed verification host

Versions below describe this invocation; they are not minimum-version policy.

| Capability | Exact observation |
| --- | --- |
| OS and architecture | Linux, amd64 |
| Bash | 5.2.21; strict mode, job control, coproc, and wait passed |
| core utilities | checksum grammar, readlink `-n/-f`, stat `-c`, guarded temp ownership, compare/diff, permissions, FIFO, and cleanup passed |
| declared host commands | all fixed text, file, process, Git, and Make helpers passed bounded behavioral probes; zero-only substitutes were rejected |
| GNU tar | 1.35; deterministic ustar, NUL files-from stream, gzip, and guarded extraction passed |
| GNU timeout | 9.4; foreground TERM result 124 and TERM-resistant KILL result 137 passed |
| Linux process state | `/proc/<pid>/stat`, live process group, KILL/reap, and final absence passed |
| Docker | client 29.7.2, server 29.7.2, API 1.55/1.55, linux/amd64 |
| Docker CLI surface | stdin context plus advertised network, pull, cache, progress, inspect, and local remove surfaces passed |
| Aqua | exact trusted binary/version 2.62.3 |
| Aqua proxy | v1.2.13 Linux amd64; SHA-256 `0614f38f20377799ad36edb9a3e53c703546ed49ecf5ecd2e395379dd3a4bc3a` |
| kind | expected and directly observed v0.32.0, linux/amd64 |
| kubectl | expected and directly observed v1.36.1, linux/amd64 |

The machine result contains 28 ordered records and 1036 bytes. Its SHA-256 is
`f80d419b957bad1c92e7cc467597c64ba64fed7e6b5525af83e60b2570f2941d`.
It reports invocation-only time semantics and contains no filesystem path,
username, credential, Docker configuration, or environment dump.

## Fast observation versus runtime proof

`make doctor` performs behavioral host probes, read-only Docker
client/server/help queries, and project-tool identity observation. Aqua
registry-cache writes are redirected to a temporary observation root. The
resolved package bytes are checked against the Aqua checksum lock. Version
commands then execute through the exact admitted production proxy with lazy
installation disabled and the temporary Aqua root. Aqua 2.62.3 installed proxy
v1.2.13 at the single pinned digest recorded above. The trust module resolves
its checksum, link, and timeout primitives from the host-default command path,
so project-controlled PATH entries cannot attest their own bytes.

Doctor does not build or pull an image, inspect or remove a workload image,
create or query a cluster, call the Kubernetes API, bootstrap tools, or write
project state. A before/after inventory of production Aqua paths, types,
sizes, modes, modification/change times, and link targets was identical at
SHA-256
`d91c872d628aab39ad3eccce7fefe5bd0c5db13d332f2dfaf3d47943d0874328`.
Inherited `BASH_ENV`, `ENV`, `GIT_DIR`, `MAKEFILES`, and `TAR_OPTIONS` fixtures
also left every outside marker absent. A hostile directory creator could not
replace the owned-workspace marker with a symlink or overwrite its target.

An independent observation also ran the following normalized command, where
`<REPO>` was the candidate checkout:

```bash
bwrap --ro-bind / / --tmpfs /tmp --dir <REPO> \
  --ro-bind <REPO> <REPO> --proc /proc --dev-bind /dev /dev \
  --unshare-net --chdir <REPO> tools/bootstrap/doctor.sh --machine
```

It exited zero with 28 stdout lines, no stderr, the expected schema first, and
the kubectl identity last. The repository and root filesystem were read-only,
the temporary filesystem was fresh, and the external network namespace was
unavailable; the local Docker Unix socket remained observable.

`make verify-runtime` remains the owner of deterministic stdin-tar and
directory-context builds, the exact BuildKit result line, local image
inspection/removal, kind load, Kubernetes journeys, and cleanup. The shared
parser accepts exactly one line shaped as `#<digits> writing image
sha256:<64 lowercase hex> done`. Machine doctor therefore reports parser
readiness and explicitly reports runtime execution as not run; it does not
convert CLI help into a runtime-success claim.

## Intentional RED evidence

`make prove-environment` passed the bounded adversarial matrix:

- zero-returning substitutes for every declared host command were rejected for
  their missing behavior;
- a project-controlled checksum command could not attest tampered Aqua proxy
  bytes, and inherited Bash/Git/Make/tar controls could not escape the probe
  root;
- unavailable and malformed `/proc` state were rejected;
- missing Docker, unreachable daemon, malformed or multiline identity, empty
  help, and each missing consumed CLI surface were rejected;
- a missing BuildKit identity was rejected by the shared parser while a forged
  PATH `sed` was never executed;
- absent/wrong kind and kubectl versions and wrong kubectl platform were
  rejected;
- tampered installed package and Aqua proxy bytes were rejected through the
  complete doctor/tooling boundary before execution;
- pristine project state remained `READY_FOR_BOOTSTRAP`, while partial state
  was rejected and external PATH Aqua/kind/kubectl markers were not executed;
- evidence with missing, extra, duplicate, control, NUL, oversized, path,
  identity, semantic, or symlink defects was rejected.

The ready project-tool fixture used an exact fake Docker adapter, so
`make prove-local` retains its offline/local-fixture semantics. The real
`make doctor` and `make environment-evidence` commands remain separate
canonical observations of the current Docker daemon.

A detached exact-candidate worktree with no `.platform` state ran
`CI=true make bootstrap`. Aqua 2.62.3 installed proxy v1.2.13 at
the expected Linux amd64 internal package path; its SHA-256 was the pinned
`0614f38f20377799ad36edb9a3e53c703546ed49ecf5ecd2e395379dd3a4bc3a`.
The temporary worktree was removed after the bounded observation.

## Candidate checks completed

| Command | Result |
| --- | --- |
| `bash -n` on the environment/profile/parser slice | PASS, exit 0 |
| managed ShellCheck on the environment/profile/parser slice | PASS, exit 0 |
| managed shfmt diff on the environment/profile/parser slice | PASS, empty diff |
| `git diff --check` | PASS, exit 0 |
| `make bootstrap` and `CI=true make bootstrap` | PASS; proxy digest matched the pinned v1.2.13 bytes |
| clean-empty `CI=true make bootstrap` | PASS; Aqua reproduced the pinned proxy path and digest |
| `TMPDIR=/tmp/ tools/bootstrap/doctor.sh --machine` | PASS, 28 records, 1036 bytes |
| `make prove-environment` | PASS, all exact GREEN/RED observations above |
| `make check-fast` | PASS, exit 0 |
| `make prove-local` | PASS, exit 0 |

The final clean-commit canonical matrix, live `make verify-runtime`, direct
bundle clone replay, bundle checksum, and `git fsck --full` are deliberately
not claimed here. They must be recorded in the detached final handoff after
those immutable identities and executions exist.

## External and unsupported behavior

Hosted GitHub runners, Docker-in-Docker, non-Linux systems, other
architectures, registry push/pull identity, remote Kubernetes, production,
cloud provisioning, and customer runtime behavior were not run and are not
supported by this local evidence.

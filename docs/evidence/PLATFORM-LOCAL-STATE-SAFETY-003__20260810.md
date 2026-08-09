# PLATFORM-LOCAL-STATE-SAFETY-003

Date: 2026-08-10

Starting baseline:
`09a30681272d1f2ec37437737e6f765184282115`

Status: implemented and offline-verified

## Confirmed pre-fix defect

A disposable clone was prepared with `.platform` as a symlink to an external
empty directory. Running `tools/diagnostics/collect.sh` returned success and
created all of the following outside the repository:

- `diagnostics/raw/platform.txt`;
- `diagnostics/raw/kubernetes-status.txt`;
- `platform-diagnostics.zip`;
- `platform-diagnostics.zip.sha256`.

The Kubernetes and bootstrap paths had individual checks, but generated state
had no repository-wide path contract. Several scripts still used direct
`mkdir`, redirection, or recursive reset operations.

## Repair

`tools/common/state.sh` is now the single small boundary for generated state:

- `assert_existing_state_directory` validates without creating state;
- `ensure_state_directory` walks and creates only canonical real directories;
- `prepare_state_file` rejects symlink and non-regular output targets;
- `reset_state_directory` rejects unsafe targets before bounded local reset.

`env.sh` validates the `.platform/aqua/bin` directory chain before adding it to
`PATH`. Diagnostics, bootstrap, artifact evidence, quality caches, reference
builds, Kubernetes logs, kubeconfig preparation, and diagnostic resets use the
same helper instead of duplicating path semantics.

Every nested call propagates failure explicitly with `|| return`. This is
intentional: Bash `errexit` is disabled in several conditional call contexts
and is not a security boundary. An early repair candidate was caught by the RED
fixture because it logged a rejected traversal but continued execution when
called from an `if` condition.

New directories are created with a `077` umask. The helper refuses to create a
missing project root implicitly; `PLATFORM_STATE_DIR` must remain below the
already existing repository.

## Intentional RED and positive evidence

The offline fixture proves rejection, with exact failure meaning, of:

- a symlinked `.platform` root;
- a symlinked nested diagnostics directory;
- a symlinked Aqua executable-directory chain before `PATH` use;
- symlinked summary and Kubernetes-status files;
- a symlinked recursive reset target while preserving external data;
- parent traversal and noncanonical double-slash paths;
- an absent parent outside the established project root.

The positive case proves canonical nested state creation, regular-file output,
and `0700` permissions on a newly created state root.

A real `make diagnose` replay was run twice. Both archives passed internal and
detached verification and had the same SHA-256:

```text
2cffcaa370e7eef981df6eb170039e8c68914f20770df9c63efa8251c7598f49
```

The exact hash describes the uncommitted verification worktree and is evidence
of deterministic behavior, not a release identity.

## Threat boundary

This change prevents accidental and same-user symlink/non-regular path escape
through repository-generated state. It does not claim protection against a
hostile concurrent local user, bind mounts, hard-link attacks, a compromised
kernel, or a compromised executable already admitted into the toolchain. No
sandbox, privilege manager, generic filesystem framework, or daemon was added.

## Checks

Executed locally:

- Bash syntax for all repository shell scripts;
- project source line/function policy;
- `git diff --check`;
- `tools/common/prove-state-safety.sh`;
- `make prove-local` with all existing artifact, tool-lock, Kubernetes, commit,
  source-policy, and formatting RED fixtures;
- positive and repeated deterministic `make diagnose`;
- internal and detached diagnostics archive verification.

External scanners and live Docker/kind verification remain assigned to
`PLATFORM-PROMOTION-ONLINE-001` and were not represented as green here.

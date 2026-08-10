# PLATFORM-RUNTIME-IDENTITY-003 evidence

Date: 2026-08-11
Status: `LOCAL_RUNTIME_IDENTITY_VERIFIED`

This record closes the local runtime-identity boundary requested after
`PLATFORM-PROMOTION-CLOSURE-002`. It does not alter the earlier promotion
history or claim that local Docker identities are registry identities.
`LOCAL_RUNTIME_IDENTITY_VERIFIED` describes the integrated clean-worktree live
proof below; final publication additionally requires the post-commit plain
bundle-clone matrix defined in this record.

## Implementation identity

| Identity | Value |
| --- | --- |
| promotion documentation baseline | `3a87c142849255866f819c9fff68aa7d43745adb` |
| runtime-identity implementation | `38730f9e554c6905dd5f57d739dde64fb9fa6443` |
| implementation tree | `0b75cad068d2386fd17139a04289c3ff8375d06d` |
| positive source checkpoints clean | `true` |
| retained `make verify-runtime` duration | `117356` ms |
| retained command status | `0` |

Relative to the promotion documentation baseline, the runtime implementation
changes 14 non-documentation files with 3,447 insertions and 105 deletions. It
does not add a third-party Go module or registry dependency.

## Proven identity chain

The reference server resolves `os.Executable` at startup, streams the file
through standard-library SHA-256, and exposes exactly 64 lowercase hexadecimal
characters plus LF at `/identity`. The positive journey accepts only this byte
shape and exact equality with the freshly built host binary.

Before the positive Docker build, the journey requires a clean worktree and
captures exact Git commit/tree identities. One fresh source snapshot is
materialized from that Git object pair, so concurrent worktree edits cannot
change the inputs. Two fresh host builds from the snapshot must be
byte-identical. Each Docker build uses an independently staged guarded context
and deterministic tar; their bytes must be identical and they contain only
regular files `Dockerfile` and `server`. A canonical TSV outside each staged
context binds path, mode, size, and SHA-256. An adjacent canary must remain
excluded. An unexpected file, symlink, special file, altered source record, or
changed input stream makes the proof red.

The retained integrated clean-worktree measurements are:

| Measurement | Exact result |
| --- | --- |
| captured source commit | `38730f9e554c6905dd5f57d739dde64fb9fa6443` |
| captured repository root tree | `0b75cad068d2386fd17139a04289c3ff8375d06d` |
| positive source checkpoints clean | `true` |
| build source commit/tree equal positive source | `true` |
| build source semantics | `git-commit-tree-snapshot` |
| Docker input semantics | `tee-captured-deterministic-tar` |
| first and second host binary SHA-256 | `59b3548cebd7f05dbc9a9bf20852935996525a6d9e097fa1a5d362cc8c9edea1` |
| running executable SHA-256 | `59b3548cebd7f05dbc9a9bf20852935996525a6d9e097fa1a5d362cc8c9edea1` |
| host binary bytes | `5767294` |
| exact two-file payload bytes | `5767400` |
| context manifest SHA-256 | `38f0b1580a9a24ae88ed15f49d630569c48e15ffe3ff83ff8fcdad80b216d9a8` |
| deterministic context archive SHA-256 | `d303aeece481fd969d59de2184b959233ad6a2d404b3d2cb8837ba6d5d1e6317` |
| first and second tee-captured input SHA-256 | `d303aeece481fd969d59de2184b959233ad6a2d404b3d2cb8837ba6d5d1e6317` |
| first and second tee-captured input bytes | `5775360` |
| first Docker config digest | `sha256:6b44fd16d2ee8375d4264b9077809034acf08505cbf521bb0c13c45b7a4b1da7` |
| second Docker config digest | `sha256:9b0446fcd8155793519be2dacea1466f49e24b3c9a79f5eca522853dbdf0229b` |
| Docker config digests identical | `false` |
| local Docker RepoDigests | empty |
| Pod CRI image identity | retained below |
| Docker config versus Pod CRI comparable | `false` |
| exact health response | `ok` plus LF |
| selected positive IPv4 port | `38657` |

The different Docker config digests are retained honestly; reproducibility is
claimed for the host executable bytes and the two equal client-side tar input
streams, not for Docker image config metadata, daemon-internal reads, or layers.
The local Docker config digest and the CRI-reported Pod identity have different
semantics and are explicitly non-comparable. The running executable response is
the content identity bridge. The exact positive Pod CRI identity was
`docker.io/library/import-2026-08-10@sha256:` followed by
`af2c3ef693d29b53c4063e8ea3b620bc68be415a586d81333f2275f34c1ce825`.

## Live stale same-tag RED

The live RED first built and loaded canonical image A into kind. It then derived
a still-executable B by changing exactly one trailing byte, observed B's exact
intentional startup-failure status and marker, invalidated A's canonical build
record, and rebuilt the same local tag as B without loading B into kind.

The deployed Pod therefore ran node-loaded A while the host expected B:

| Stale boundary | Exact result |
| --- | --- |
| executable A SHA-256 | `59b3548cebd7f05dbc9a9bf20852935996525a6d9e097fa1a5d362cc8c9edea1` |
| expected executable B SHA-256 | `84788e5d12ae5a43417e6b33576a7906fe3a224bd03df7e30af0b342a255bcb0` |
| local Docker config A | `sha256:51e651159b0a6171a9f8591db2fbf3e88f34a586e06a948159d4d16e8cc15d80` |
| local Docker config B | `sha256:a67df6d5a3a2c5329754d08598da4a5dc92adcca91721e3dcc449adc959f16d3` |
| context manifest B SHA-256 | `6b52d89ccd37782083e533bdab4ca6a2fa148868ab9d4897c543336fa90bb37f` |
| stale Pod CRI image identity | retained below |
| observed mismatch status | `74` |
| observed mismatch reason | `FAIL  runtime-id    running binary SHA-256 mismatch` |
| B loaded into kind | `false` |
| selected stale IPv4 port | `44291` |

The Pod `imageID` was captured with an exact-one Running-Pod selector before and
after the endpoint probe and had to remain byte-identical. The RED was accepted
only after health remained exact, runtime SHA equalled A, comparison against B
failed for the required status and reason, the selected port and tracked
process group were absent, and the namespace was API-visibly absent.
The exact stale Pod CRI identity was
`docker.io/library/import-2026-08-10@sha256:` followed by
`dbfe03c71e5714f1417af46d6b944ae8f1baac0a0bf0241f1148688158864b97`.

## Positive, negative, and cleanup results

| Boundary | Result |
| --- | --- |
| strict health and identity bytes | `PASS` |
| positive Pod identity stable across probe | `PASS` |
| mutable tag re-inspected immediately before load | `PASS` |
| stale same-tag mismatch | `PASS`, exact status and reason |
| malformed, NUL-terminated, and extra-key evidence REDs | `PASS` |
| source commit/tree record mismatch | `PASS`, exact RED |
| same-size Dockerfile and server mutation | `PASS`, exact RED |
| stream capture and changed stdin stream | `PASS`, exact RED |
| dirty positive evidence | `PASS`, exact RED |
| TERM-resistant process-group KILL and reap | `PASS`, final absence |
| positive port-forward process-group and PID absence | `PASS` |
| stale port-forward process and port absence | `PASS` |
| positive namespace absence | `PASS` |
| intentional startup marker | `PASS`, exact marker |
| negative namespace absence | `PASS` |
| cluster after final teardown | `absent` |
| cluster after idempotent teardown | `absent` |

The aggregate evidence publisher snapshots and revalidates each guarded journey
file, enforces exact key order and value formats, rejects NUL bytes and invalid
shell syntax, and publishes atomically only after both cluster-absence results
are `absent`.

The build record uses schema `flare-platform-reference-build-v2` with exactly 31
allowlisted records. Positive evidence uses
`flare-platform-runtime-identity-positive-v2` with exactly 40 records, while the
aggregate uses `flare-platform-runtime-identity-evidence-v2` with 73. The stale
and startup-failure v1 journey contracts contain 24 and 3 records respectively.
Before kind load, the consumer independently re-hashes the generated
`Dockerfile` and `server` against the manifest, reconstructs the deterministic
tar, and requires its hash and byte count to equal the build record.

## Machine evidence identity

The accompanying implementation evidence contains the bounded command index,
runtime log, the three journey records, and the final aggregate. The aggregate
retains the positive build-record and BuildKit-log hashes. The mutable
`.platform/reference` files are deliberately not presented as positive
evidence because the later startup-failure journey performs another build and
replaces that generated state.

| Machine evidence | Bytes | SHA-256 |
| --- | ---: | --- |
| integrated clean-worktree command index | `258` | `aac92de8ed775a59b245732e1985f9eed4d22341d586bf7de7a21df639edb7fb` |
| integrated clean-worktree `make verify-runtime` log | `9250` | `a859fec4eca237578ae1127af8d12f5eba46428c946280c5f92ddac71a7dfe72` |
| aggregate `evidence.env` | `4923` | `b587bc90b704a98dceda496ffb71dfd27c40316c32d61bcd24d98aad76e2f6b2` |
| positive journey | `2393` | `780133ca47ea0f16a18b49912f6725505dff843b5856fc61f91b695027c6f92e` |
| stale same-tag journey | `1475` | `f3128d66a9a2137458b59d3500663e1ef0aeff43b3ea95c0223a786e50ea35ba` |
| startup-failure journey | `129` | `e7b70333ce70df43305228db60b30812d7d8de91b316080b7587c648ef891233` |

## Before and after

The earlier fixture sent the repository root as its Docker context and used a
fixed local port `18080`. A retained baseline log showed a `5.77MB` context
transfer, both IPv4 and IPv6 forwarding on `18080`, and an initial connection
refusal before health succeeded. Its observed local Docker config digest was
`sha256:cb0d823544f0ea2d7cdfa9e68ad0ca91577ee9185446b8298ecc7b6b4e957021`;
its Pod CRI identity was
`docker.io/library/import-2026-08-10@sha256:293324866bf49af97fb30bd971a2afefa07e2f534dfc7cee76d374935fe59d03`.
Baseline RepoDigests were not measured and are therefore `unknown`, not inferred
to be empty.

The new context is not claimed to be dramatically smaller: the statically
linked server itself is about 5.77 MB. The improvement is the exact Git-object
source snapshot, deterministic two-file tar, external manifest, canary
exclusion, tee-captured presented input bytes, and bound BuildKit result. The
fixed port is replaced with an observed ephemeral IPv4 port and explicit
post-cleanup process-group absence in both live probes plus selected-port absence
in the stale RED.

## Post-commit delivery identity

A commit cannot contain its own SHA and a bundle cannot contain its own detached
checksum. The handoff therefore must carry a separately generated
`runtime-identities.env` after this documentation commit. It will bind the
implementation commit, final documentation commit, branch and HEAD bundle refs,
bundle checksum, clean-clone command index, and final aggregate evidence hashes.
The bundle verifier and plain clone replay will check those values mechanically.
The required clean-clone sequence is `make doctor`, `make bootstrap`,
`CI=true make bootstrap`, `make prove-local`, `make prove-gates`,
`make check-fast`, `make check`, `make verify-runtime`, `make verify`, and
`make kind-down`. It also records `git rev-parse HEAD`, initial and final
`git status --porcelain=v1 --untracked-files=all`, `git fsck --full`, exact
branch and bundle refs, and final cleanup checks.

## Authorized scope and disposition

This proof covers the local Linux amd64 Docker/kind path only. Docker config
digests are not registry manifest digests; the observed local image has empty
RepoDigests. The CRI `imageID` is retained as CRI evidence and is not compared
to the local config digest. Hosted GitHub Actions, registry push/pull behavior,
remote clusters, production rollout, Flare product semantics, and Poker product
semantics remain outside the authorized scope and were not mutated. Signing and
key management, registry publication, SBOM or vulnerability policy, a generic
provenance framework, Helm or GitOps delivery, Flare or Poker manifests, and
platforms other than Linux amd64 are also explicit non-goals.

The Git-object snapshot isolates ordinary concurrent worktree edits, including
an IDE or another local agent changing files after source capture. It is not a
defence against a malicious same-UID process that tampers with the Git object
database or guarded temporary files; that stronger threat model requires
kernel-enforced read-only mounts or namespaces and is outside this local proof.
The tee evidence binds bytes presented to a successful Docker CLI stdin, not a
daemon-internal byte stream, layer digest, or registry identity.
The positive journey checks revision and cleanliness before capture and again at
publication; these are two checkpoints, not a continuously locked worktree.
The local commit/tree values are content identities, not signed or authenticated
provenance.

The local runtime-identity implementation at
`38730f9e554c6905dd5f57d739dde64fb9fa6443` is verified in an integrated clean
worktree. Final publication still requires the mechanical post-commit identity
and clean bundle-clone replay described above.

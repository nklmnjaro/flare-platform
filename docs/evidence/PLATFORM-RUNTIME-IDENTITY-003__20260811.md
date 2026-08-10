# PLATFORM-RUNTIME-IDENTITY-003 evidence

Date: 2026-08-11
Status: `LOCAL_RUNTIME_IDENTITY_VERIFIED`

This record closes the local runtime-identity boundary requested after
`PLATFORM-PROMOTION-CLOSURE-002`. It does not alter the earlier promotion
history or claim that local Docker identities are registry identities.

## Implementation identity

| Identity | Value |
| --- | --- |
| promotion documentation baseline | `3a87c142849255866f819c9fff68aa7d43745adb` |
| runtime-identity implementation | `568b395d50b4fe4971b7f86c63b6b242ee781444` |
| implementation tree | `0ae15a023c8c30c970772b986c02e441d2892c03` |
| clean implementation worktree | `true` |
| retained `make verify-runtime` duration | `122621` ms |
| retained command status | `0` |

The implementation adds 2,821 lines and removes 104 lines across 14 files. It
does not add a third-party Go module or registry dependency.

## Proven identity chain

The reference server resolves `os.Executable` at startup, streams the file
through standard-library SHA-256, and exposes exactly 64 lowercase hexadecimal
characters plus LF at `/identity`. The positive journey accepts only this byte
shape and exact equality with the freshly built host binary.

Before Docker runs, two fresh host builds must be byte-identical. Docker receives
only a generated context with two regular files, `Dockerfile` and `server`; a
canonical TSV outside the context binds path, mode, size, and SHA-256. An
adjacent canary must remain excluded. An unexpected file, symlink, or special
file inside the context makes the context proof red.

The retained clean measurements are:

| Measurement | Exact result |
| --- | --- |
| first and second host binary SHA-256 | `59b3548cebd7f05dbc9a9bf20852935996525a6d9e097fa1a5d362cc8c9edea1` |
| running executable SHA-256 | `59b3548cebd7f05dbc9a9bf20852935996525a6d9e097fa1a5d362cc8c9edea1` |
| host binary bytes | `5767294` |
| exact generated context bytes | `5767400` |
| context manifest SHA-256 | `38f0b1580a9a24ae88ed15f49d630569c48e15ffe3ff83ff8fcdad80b216d9a8` |
| first Docker config digest | `sha256:3c0a7245f537f03e6085279149f15b6daeb7e1c5752ef1ed5eedc76202706391` |
| second Docker config digest | `sha256:df1669e5bef4cd688162e3e2bc772ac9790ede3edf621bd735552c80f4aa8078` |
| Docker config digests identical | `false` |
| local Docker RepoDigests | empty |
| BuildKit context transfer, first / second | `5.77MB` / `30B` |
| Pod CRI image identity | retained below |
| Docker config versus Pod CRI comparable | `false` |
| exact health response | `ok` plus LF |
| selected positive IPv4 port | `41235` |

The different Docker config digests are retained honestly; reproducibility is
claimed for the host executable bytes, not for Docker image config metadata.
The local Docker config digest and the CRI-reported Pod identity have different
semantics and are explicitly non-comparable. The running executable response is
the content identity bridge. The exact positive Pod CRI identity was
`docker.io/library/import-2026-08-10@sha256:` followed by
`20dc61590670f00bb12460bee2a6591add196976e927f7e33e606daad71525e6`.

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
| local Docker config A | `sha256:0de3e7c9aca1e960f67c7525d99ff729bf40c8560f532d4cbdeeee41a18cd541` |
| local Docker config B | `sha256:857c84ea76108145ab06f5a3e34a18f757e2d0e3523e540b2c770989e6a226ca` |
| context manifest B SHA-256 | `6b52d89ccd37782083e533bdab4ca6a2fa148868ab9d4897c543336fa90bb37f` |
| stale Pod CRI image identity | retained below |
| observed mismatch status | `74` |
| observed mismatch reason | `FAIL  runtime-id    running binary SHA-256 mismatch` |
| B loaded into kind | `false` |
| selected stale IPv4 port | `43419` |

The Pod `imageID` was captured with an exact-one Running-Pod selector before and
after the endpoint probe and had to remain byte-identical. The RED was accepted
only after health remained exact, runtime SHA equalled A, comparison against B
failed for the required status and reason, the selected port and tracked
process group were absent, and the namespace was API-visibly absent.
The exact stale Pod CRI identity was
`docker.io/library/import-2026-08-10@sha256:` followed by
`433538537ca0044f88df8256ec0071eedc6a5c011ae7815463950b7f82f1fdd3`.

## Positive, negative, and cleanup results

| Boundary | Result |
| --- | --- |
| strict health and identity bytes | `PASS` |
| positive Pod identity stable across probe | `PASS` |
| mutable tag re-inspected immediately before load | `PASS` |
| stale same-tag mismatch | `PASS`, exact status and reason |
| malformed, NUL-terminated, and extra-key evidence REDs | `PASS` |
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

## Machine evidence identity

The accompanying implementation evidence contains the bounded command index,
runtime log, the three journey records, and the final aggregate. The aggregate
retains the positive build-record and BuildKit-log hashes. The mutable
`.platform/reference` files are deliberately not presented as positive
evidence because the later startup-failure journey performs another build and
replaces that generated state.

| Machine evidence | SHA-256 |
| --- | --- |
| clean command index | `fe5ff28d2751824a6d21a8f83717875a6f15a692622c0f060e82554f603c0555` |
| clean `make verify-runtime` log | `63c87a833ab8d7d282af6a56d620910fc895ba6e3516f0328b37c55beec25664` |
| aggregate `evidence.env` | `4c830924d67138a30933d289e6f8ff252bcf5df2dd0493dfd5523d0e02d09a91` |
| positive journey | `57da85240262b8fb3d8bef5ba60620f4717d009ba122ae18ee0a84d28f1e2fa0` |
| stale same-tag journey | `dadb9a62734eaccdeb04e27f0209916b8bee5cb5faf7410f5ea63811f935d3e2` |
| startup-failure journey | `e7b70333ce70df43305228db60b30812d7d8de91b316080b7587c648ef891233` |

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
linked server itself is about 5.77 MB. The improvement is the exact two-file
allowlist, external manifest, canary exclusion, and bound BuildKit result. The
fixed port is replaced with an observed ephemeral IPv4 port and explicit
post-cleanup process-group absence in both live probes plus selected-port
absence in the stale RED.

## Post-commit delivery identity

A commit cannot contain its own SHA and a bundle cannot contain its own detached
checksum. The handoff therefore carries a separately generated
`runtime-identities.env` after this documentation commit. It binds the
implementation commit, final documentation commit, branch and HEAD bundle refs,
bundle checksum, clean-clone command index, and final aggregate evidence hashes.
The bundle verifier and plain clone replay check those values mechanically. The
required clean-clone sequence is `make doctor`, `make bootstrap`,
`make prove-gates`, `make check`, `make verify-runtime`, and `make verify`, plus
initial/final Git status, object integrity, branch/ref, and cleanup checks.

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

The local runtime-identity implementation at
`568b395d50b4fe4971b7f86c63b6b242ee781444` is verified. Final publication is
subject only to the mechanical post-commit identity and clean bundle-clone
replay described above.

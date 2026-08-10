# PLATFORM-PROMOTION-CLOSURE-002 evidence

Date: 2026-08-10
Status: `LOCAL_PROMOTION_VERIFIED`

This is the superseding local disposition record for the integrated Platform
candidate. It supersedes only the present-tense promotion status in older
evidence. The older documents remain immutable historical observations and are
not rewritten as if their unavailable checks had passed.

## Verified input and integration identity

| Identity | SHA |
| --- | --- |
| common ancestor | `ddb7366bf140ba1b274bd93d8ca17ce749ac1d76` |
| offline hardening input | `a89461a8202519b5deae8d6edc4f0e1e3bc8db40` |
| online candidate input | `227684019568b95a172f74e680360a0b2701c801` |
| online input bundle SHA-256 | `b250bb8b1de527aab80f3906bb70855b65f2e1323224705b53681544ebfbbccc` |
| offline input bundle SHA-256 | `faecda7783dff127e9d8856e3e7a0888316ab385c9e00cd824c5db31f17277c5` |
| integrated committed baseline | `a863afe410ed905eb75ffc0bc19d2572ce04e27f` |
| repair implementation | `42e877c489afe8347e4f5a797d453838c95a59c0` |

The integration starts from the complete offline-hardening history. It then
preserves the supplied online changes in order through these semantic replays:

| Supplied online commit | Integrated commit | Subject |
| --- | --- | --- |
| `e87eeb65e622f1c6e382742deb4b426b354dfe96` | `1f8f282c46c2d90905ddd7b4a23598c9ca894862` | make project tool proxies executable |
| `602c0fc27118ef560a5ae138fe6bc769b99c1175` | `901f63a7f570bf24852479a4c91f2646c300bf74` | reject false-green promotion evidence |
| `227684019568b95a172f74e680360a0b2701c801` | `a863afe410ed905eb75ffc0bc19d2572ce04e27f` | lock the verified Aqua toolchain |

The committed Aqua lock has `require_checksum: true`. Its file identities are:

- `aqua.yaml`:
  `b5289b2c824b6dce88a4fc0ffac93f7442e93f52f2f37fd68fe62edfca4f4a51`;
- `aqua-checksums.json`:
  `76fc0524b91810dae828e960758567a69a39283f310a614143e84f2beb4f7705`.

## Verified local closure boundary

The blocking code repairs are committed at
`42e877c489afe8347e4f5a797d453838c95a59c0`. Both the integrated checkout and a
clean replacement-worker clone executed the complete local command matrix at
that exact implementation SHA.

| Required local identity or replay | Result |
| --- | --- |
| repair implementation SHA | `42e877c489afe8347e4f5a797d453838c95a59c0` |
| integrated-checkout canonical command record | `PASS` at repair implementation SHA |
| clean replacement-worker checkout SHA | `42e877c489afe8347e4f5a797d453838c95a59c0` |
| clean replacement-worker canonical command record | `PASS`, ordinals `100-113` |
| clean initial and final Git status | `PASS`, both machine logs empty |
| clean `git fsck --full` | `PASS`, machine log empty |

## Machine evidence identity

The accompanying closure evidence stages the clean replay and independent Aqua
derivation as `code-clean/commands.tsv` plus logs `100.log` through `114.log`.
The index is 4,927 bytes, has SHA-256
`acf8a381d23bc184f08885adaf04844eadb2cc316687b608d800fa6a3ff5af1e`,
and records 15 of 15 entries with exit status zero and no truncated output:
14 clean-matrix records at ordinals `100-113`, plus the Aqua derivation at
ordinal `114`.

| Machine evidence | SHA-256 or exact result |
| --- | --- |
| clean command and derivation index | `acf8a381d23bc184f08885adaf04844eadb2cc316687b608d800fa6a3ff5af1e` |
| `make verify-runtime` log, ordinal `109` | `ff93254f430f3467611e17cd193295c2b05a052ab95a4989815476fd5e1c1d62` |
| `make verify` log, ordinal `110` | `df89b5f942c3293f3aeda571c4dcaf153b7c5f52f6227dfa81b0438109a743cb` |
| Aqua derivation log, ordinal `114` | `b1cc3663d1a2438a445008c98c7c4de9f54fd9eb9b6b176136a32e827f23f45c` |
| initial/final status and fsck logs | empty-file SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| clean Kubernetes `1.36.1` schema-cache content | `3725782fb01e3f27d8be2da565e2d653d7b78bf6debe5440804cea993c87b8f9` |

## Integrated and clean command replay

Every command below returned status zero in the integrated implementation
checkout and the clean replacement-worker clone.

| Command | Integrated | Clean | Clean ordinal | Proven boundary |
| --- | --- | --- | --- | --- |
| `make doctor` | `PASS` | `PASS` | `102` | Linux prerequisites and reachable Docker daemon |
| `make bootstrap` | `PASS` | `PASS` | `103` | pinned archive, cached binary, and locked tools |
| `CI=true make bootstrap` | `PASS` | `PASS` | `104` | exact required-checksum policy accepted |
| `make prove-local` | `PASS` | `PASS` | `105` | offline RED, state, artifact, and delivery contracts |
| `make prove-gates` | `PASS` | `PASS` | `106` | pinned external RED fixtures rejected for exact reasons |
| `make check-fast` | `PASS` | `PASS` | `107` | source, shell, workflow syntax, and offline security |
| `make check` | `PASS` | `PASS` | `108` | Dockerfile, secret, schema, and Kubernetes policy targets |
| `make verify-runtime` | `PASS` | `PASS` | `109` | positive, negative, diagnostics, and repeated teardown |
| `make verify` | `PASS` | `PASS` | `110` | static, RED, and live runtime aggregate |
| `make kind-down` | `PASS` | `PASS` | `111` | project cluster remained absent |

Ordinals `100`, `101`, `112`, and `113` additionally record the exact checkout
SHA, empty initial status, empty final status, and empty `git fsck --full`
output.

Ordinal `114` independently derives the pinned Aqua executable. It verifies the
downloaded archive SHA-256
`89cb081adb19e425b1dca6b16d912c349a43535ce88d8713050738c9263618d0`
before extraction, then verifies the extracted binary SHA-256
`e3e28482e8a0ef5258cf273e87b3f0cb72e50cb2c9f52d6a10fc8270f5571e5f`
before executing it and observing the exact version `2.62.3`. The retained log
states the enforced order as `archive-verify,extract,binary-verify,execute`.

## Local promotion results

| Verification | Status |
| --- | --- |
| cached Aqua fake/symlink/non-regular RED | `PASS` in both replays |
| independent Aqua archive-to-binary derivation | `PASS`, ordinal `114`; archive and binary identities verified before exact-version execution |
| integrated canonical command matrix | `PASS` |
| clean replacement-worker canonical command matrix | `PASS` |
| pinned external-gate RED and real positive targets | `PASS` in both replays |
| clean schema-cache identity replay | `PASS`, Kubernetes `1.36.1`, content hash retained |
| diagnostics ZIP and detached-checksum delivery proof | `PASS` |
| positive HTTP health response | `PASS` in both replays, exact `ok` plus LF |
| intentional negative startup marker | `PASS` in both replays, exact marker observed |
| namespace absence after positive journey | `PASS` in both replays |
| namespace absence after negative journey | `PASS` in both replays |
| cluster absence after final teardown | `PASS` in both replays |
| repeated idempotent teardown | `PASS` in both replays |
| clean initial and final tracked/untracked status | `PASS`, empty |
| clean full object check | `PASS`, empty `git fsck --full` output |

### Live Docker/kind observations

- the health response was exactly three bytes: `ok` plus LF
  (`6f 6b 0a` in hexadecimal);
- the negative container log and bounded diagnostics contained the exact marker
  `intentional startup failure requested`;
- namespace deletion reached API-visible absence after both the positive and
  negative journeys for `flare-platform-reference`;
- runtime teardown reported
  `cluster_after_final_teardown=absent` and then independently reported
  `cluster_after_idempotent_teardown=absent`;
- the later standalone `make kind-down` also returned zero with the project
  cluster already absent;
- clean runtime log `109` and aggregate log `110` independently contain every
  health, marker, namespace, and cluster-absence observation above.

### External gate observations

The positive repository targets passed ShellCheck, shfmt, actionlint,
`zizmor --offline`, Hadolint, Trivy secret scanning, kubeconform strict schema
validation, and KubeLinter. Their intentional RED fixtures also failed with the
required statuses and rule markers. Kubeconform used the explicit Kubernetes
schema identity `1.36.1`; retained RED output contained no floating
`master-standalone-strict` source. The clean schema content hash is
`3725782fb01e3f27d8be2da565e2d653d7b78bf6debe5440804cea993c87b8f9`.

## Post-commit identity contract

A Git commit cannot contain its own final SHA, and a bundle cannot contain its
own detached checksum. Immediately after the documentation commit, the handoff
generator machine-writes an accompanying `identities.env` with these exact
fields:

- `IMPLEMENTATION_SHA`;
- `FINAL_HANDOFF_COMMIT_SHA`;
- `CODE_CLEAN_COMMANDS_SHA256`;
- `BUNDLE_SHA256`;
- `BUNDLE_HEAD_SHA`;
- `BUNDLE_BRANCH_SHA`.

The verifier requires `IMPLEMENTATION_SHA` to equal
`42e877c489afe8347e4f5a797d453838c95a59c0` and
`CODE_CLEAN_COMMANDS_SHA256` to equal the command-index hash above. It then
checks the final repository HEAD, detached bundle checksum, `git bundle verify`,
explicit `HEAD` and branch refs, and a plain-clone checkout against the other
recorded values. This post-commit contract supplies the final publication
identity without placing a false self-referential value in this commit.

## Authorized local scope

The blocking local workflow-security gate runs `zizmor --offline` over the
checked-in workflow files. In this mode zizmor disables all online audit rules
and remote-repository auditing. A green result therefore covers only enabled
offline rules; it does not prove live repository settings, branch protection,
runner posture, artifact availability after hosted execution, or other
GitHub-observed behavior. Hosted Actions and remote settings are outside the
authorized local promotion scope. This disposition makes no claim about them
and authorizes no remote mutation.

## Disposition

The required local repair matrix is green in both the integrated checkout and
a clean replacement-worker clone. The durable disposition is
`LOCAL_PROMOTION_VERIFIED` for implementation
`42e877c489afe8347e4f5a797d453838c95a59c0`, subject to the mechanical
post-commit identity contract above. It does not authorize hosted, remote,
production, Flare, or Poker mutation.

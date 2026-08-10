# PLATFORM-RELEASE-CUSTOMER-READINESS-001

Дата: 2026-08-11.

## Scope

Documentation-only research и contract repair на Platform baseline
`a89461a8202519b5deae8d6edc4f0e1e3bc8db40`.

Цели:

- определить release/promotion/distribution boundary до реализации remote workflow;
- подготовить безопасный GitHub/GHCR activation profile;
- исправить неверное предположение, что Platform должен разворачивать Poker workload;
- извлечь полезные и опасные patterns из переданных ARI repositories;
- не пересекаться с `PLATFORM-PROMOTION-CLOSURE-002` и `PLATFORM-RUNTIME-IDENTITY-003`.

## Task assumptions reviewed

### Принято

- Platform является отдельным repository owner для infrastructure/delivery mechanics.
- Flare baseline остаётся `19d004da25f0658b3e610899f04f086e3a441628`.
- Remote/paid infrastructure без разрешения запрещена.
- Deployable Flare artifact пока отсутствует.
- Poker является external design partner и самостоятельно разворачивает Flare.

### Отклонено

Предыдущее `integrations/poker` предполагало, что Platform должен получить Poker build, image, service port и
persistence contract. Это противоречит accepted customer model. Poker не является deployable workload Platform; нужен consumer
environment contract для Flare.

Статус: `TASK ASSUMPTION INVALID`, исправлено документацией.

## Source review

### Platform repository

Подтверждено:

- release/rollback ownership заявлено в boundary и README;
- executable release/distribution contract отсутствовал;
- GitHub setup runbook покрывал только минимальную branch policy;
- current CI остаётся Platform-only;
- никакой product release workflow не существует.

### ARI reference snapshots

Механически измерено:

- pipeline: 40 files, 2 047 YAML LOC, 99 `!reference`, 65 `CI_PIPELINE_SOURCE` conditions;
- 50 corporate registry references и 38 `KUBE_TOKEN` references;
- `ci_contract/contract.py`: 1 072 LOC;
- две validator functions превышают 80 lines: 152 и 98;
- девять `HELM_SET_ARGS` blocks;
- autotests `tools/ci` вместе с tests: 11 654 LOC;
- image bootstrap явно отключает TLS verification, и unit test закрепляет это поведение.

Переносимые patterns и rejected assumptions перечислены в `docs/research/ari-reference-transfer.md`.

## External primary-source verification

Проверены официальные источники на 2026-08-11:

- GitHub Secure Use Reference:
  https://docs.github.com/en/actions/reference/security/secure-use
- GitHub Rulesets:
  https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets
- GitHub Merge Queue:
  https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
- GitHub Packages permissions:
  https://docs.github.com/en/packages/learn-github-packages/about-permissions-for-github-packages
- GitHub Container Registry access:
  https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility
- GitHub Artifact Attestations:
  https://docs.github.com/en/actions/concepts/security/artifact-attestations
- Kubernetes Images:
  https://kubernetes.io/docs/concepts/containers/images/
- OCI Image Manifest:
  https://github.com/opencontainers/image-spec/blob/main/manifest.md
- OCI Descriptor:
  https://github.com/opencontainers/image-spec/blob/main/descriptor.md

## Decisions proposed

1. Build once; promotion and rollback reuse one digest.
2. Tags are discovery metadata; deployment identity is digest.
3. Normative release contract is separate from observed runtime evidence.
4. Customer readiness requires independent deploy/upgrade/rollback/uninstall.
5. GHCR activation waits for exact remote identity and real image contract.
6. Artifact attestations start as `ADVISORY`, not automatic blocking policy.
7. Poker provides environment constraints and feedback, not its build/runtime ownership to Platform.
8. ARI is mined for properties, not copied as provider-specific implementation.

## Security findings

- No new secret values or remote credentials were introduced.
- ARI TLS verification bypass is explicitly rejected for Flare.
- Mutable-tag deployment is explicitly rejected.
- Long-lived Kubernetes token variables are not adopted as default auth model.
- GitHub token permissions remain least-privilege and job-scoped.

## Rejected overengineering

- release workflow before product artifact;
- generic release framework;
- Helm/GitOps/Terraform/Vault/service mesh;
- mandatory signing/SBOM/admission stack;
- remote repository creation;
- GHCR publication;
- Poker-specific logic in Flare;
- machine-readable release schema before authoritative fields exist.

## External decisions still required

- exact GitHub organization/repository;
- public/private visibility;
- permission to create or push remote;
- exact package ownership/access policy;
- authoritative Flare deployable artifact contract;
- Poker target-environment inputs;
- any support/SLA commitment.

## Next smallest Change

After Codex closes promotion/runtime identity and Flare publishes an artifact contract:

`PLATFORM-REMOTE-REPOSITORY-AND-RELEASE-005`

- activate exact GitHub repository settings;
- prove required checks once before enforcing them;
- publish one non-production candidate to authorized GHCR;
- verify digest from an independent consumer path;
- attach bounded release evidence;
- perform no remote deployment.

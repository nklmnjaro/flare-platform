# ADR 0005: Граница release, promotion и distribution

Статус: proposed; реализация заблокирована до появления реального Flare-артефакта и разрешённого remote target.

## Контекст

Platform уже заявляет ответственность за release, rollback и delivery mechanics, но в репозитории пока нет
нормативного контракта, который отделяет продуктовую сборку от публикации и promotion. Без него легко получить:

- повторную сборку одного release для разных окружений;
- deployment по изменяемому tag;
- расхождение между source commit, опубликованным image и реально запущенным Pod;
- фиктивный `customer ready` без независимого self-deployment;
- дублирование Flare build/test/runtime semantics в Platform workflow.

Flare пока не публикует подтверждённый deployable artifact. Поэтому этот ADR определяет границы и состояния, но не
создаёт release workflow, registry, signing subsystem или deployment manifest.

## Решение

### 1. Product repository владеет сборкой

Flare repository остаётся единственным владельцем:

- canonical bootstrap/build/test/check/verify commands;
- application dependency graph и lockfiles;
- runtime configuration schema;
- health/readiness semantics;
- compatibility и migration semantics.

Platform вызывает эти команды как provider adapter и не воспроизводит их в GitHub YAML или собственных scripts.

### 2. Build once, promote without rebuild

Один source commit и один canonical build создают один content-addressed artifact. Проверка, публикация, customer
qualification и rollback ссылаются на тот же digest. Promotion не запускает новую сборку.

Tags допускаются только как указатели для поиска человеком. Автоматический deployment обязан использовать digest.
Kubernetes deployment по digest исключает незаметную смену кода при изменении tag и делает rollback однозначным.

### 3. Цепочка identity

Release evidence связывает четыре разные identity и не смешивает их:

1. **Source identity** — exact repository и full commit SHA.
2. **Build identity** — project-owned canonical command и toolchain/lock identity.
3. **Artifact identity** — checksum binary либо OCI descriptor digest, media type, size и target platform.
4. **Runtime identity** — declared image digest, observed runtime `imageID` и, если поддерживается, self-hash процесса.

`PLATFORM-RUNTIME-IDENTITY-003` должен доказать последний переход для Platform fixture. Это не заменяет будущий
Flare-owned runtime contract.

### 4. Normative contract и observed evidence разделены

Normative contract определяет, что разрешено выпускать и поддерживать:

- source revision;
- artifact digest и supported platform;
- configuration, health и persistence contract revisions;
- разрешённый promotion state;
- rollback target.

Observed evidence фиксирует, что произошло в конкретном запуске:

- workflow/run identity;
- команды и результаты checks;
- runtime image identity;
- health, cleanup и diagnostics results.

Observed evidence не может молча переписать normative contract. Любое расхождение является failure.

### 5. Promotion states

Platform использует следующие состояния готовности:

| State | Значение |
| --- | --- |
| `NOT_AVAILABLE` | Deployable product artifact отсутствует. Это текущее состояние Flare integration. |
| `CANDIDATE` | Exact artifact создан из exact source и прошёл product-owned static verification. |
| `RUNTIME_VERIFIED` | Тот же artifact прошёл bounded runtime, health и cleanup proof. |
| `PUBLISHED` | Тот же digest доступен в разрешённом immutable distribution target и повторно проверен consumer'ом. |
| `CUSTOMER_READY` | Независимый оператор выполнил deploy, verify, upgrade, rollback и uninstall по документации. |
| `REVOKED` | Artifact запрещён из-за дефекта, security finding или нарушенного evidence contract. |

`CUSTOMER_READY` не означает production approval. Production остаётся запрещён до отдельного `APPROVE FLARE-000`.

### 6. Rollback

Rollback означает повторное применение предыдущего accepted artifact digest вместе с совместимым configuration
contract. Старый source commit не пересобирается. Если data migration необратима, rollback считается неподдержанным,
пока product contract не предоставит отдельную recovery procedure.

### 7. Remote distribution

GHCR является предпочтительным первым кандидатом для OCI images только после явного решения об organization,
repository, visibility, package ownership и permissions. До этого source ZIP и Git bundle остаются review/handoff
artifacts, но не product release channel.

Обычный release job получает только минимальные job-level permissions. Delete/restore package permissions не входят в
штатный publish path. Cross-repository private pulls не должны автоматически вводить long-lived personal token.

### 8. Provenance attestations

GitHub artifact attestations рассматриваются как будущий `ADVISORY` signal после появления реального публикуемого
артефакта. Они могут связать artifact с workflow, repository и source commit, но сами по себе не доказывают, что
артефакт безопасен. До measured consumer value они не являются blocking gate.

## Последствия

- Platform может спроектировать release plumbing без захвата Flare semantics.
- Customer deployment проверяет один и тот же digest, а не похожую пересборку.
- Promotion и rollback становятся audit-friendly и воспроизводимыми.
- Публикация остаётся заблокированной, пока отсутствуют реальные artifact и remote contracts.

## Отклонённые решения

- deployment по `latest` или другому mutable tag;
- rebuild per environment/customer;
- release workflow до deployable Flare artifact;
- обязательные Helm, GitOps, Terraform, signing service, SBOM platform или admission controller в этом change;
- generic multi-product release framework без второго реального consumer;
- трактовка runtime evidence как замены нормативному product contract.

## Основания

- Kubernetes Images: digest pinning и риски `latest`.
- OCI Image Specification: content-addressable manifests и descriptors.
- GitHub Secure Use: least-privilege token permissions и immutable action SHA.
- GitHub Artifact Attestations: provenance capabilities и ограничения.

Точные ссылки и дата проверки перечислены в evidence document этого change.

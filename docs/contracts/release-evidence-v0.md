# Release evidence contract v0

Статус: candidate contract; machine-readable schema откладывается до появления Flare artifact contract.

## Назначение

Контракт определяет минимальный набор данных, необходимый для проверки release, promotion и rollback. Он не задаёт
формат Flare image, Kubernetes topology или product versioning и не заменяет product-owned build/runtime semantics.

## Основные правила

1. Один release record относится к одному exact artifact digest.
2. Normative claims и observed evidence хранятся раздельно.
3. Неизвестное значение остаётся `MISSING`; оно не заменяется догадкой или default из Platform.
4. Secret values, raw environment dumps, kubeconfig и credentials запрещены.
5. Workstation usernames и absolute home paths не являются release evidence.
6. Любой файл evidence имеет checksum и bounded size.
7. Promotion использует существующий artifact; повторная сборка создаёт новый release record.

## Normative release record

| Field | Требование | Текущее состояние |
| --- | --- | --- |
| `schema_version` | Версия contract format. | `DECLARED` |
| `product.repository` | Authoritative repository identity. | `MISSING_REMOTE` |
| `product.commit` | Full immutable source SHA. | Flare baseline известен, release artifact отсутствует. |
| `product.command_contract` | Revision документа с canonical build/check/verify commands. | `MISSING` |
| `build.toolchain_identity` | Lock/manifest digest, определяющий build toolchain. | `MISSING` |
| `artifact.kind` | Например, `oci-image` или `binary`; определяется product contract. | `MISSING` |
| `artifact.digest` | Content digest, проверяемый consumer'ом. | `MISSING` |
| `artifact.size` | Exact byte size или OCI descriptor size. | `MISSING` |
| `artifact.platforms` | Поддерживаемые OS/architecture tuples. | `MISSING` |
| `artifact.location` | Разрешённый immutable distribution target. | `MISSING_REMOTE` |
| `configuration.contract` | Versioned config schema/default/required values. | `MISSING` |
| `health.contract` | Readiness/liveness semantics и bounded timeout. | `MISSING` |
| `persistence.contract` | Durable state, backup, migration и restore semantics. | `MISSING` |
| `promotion.state` | Одно состояние из ADR 0005. | `NOT_AVAILABLE` |
| `rollback.previous_release` | Exact prior release record либо явное `NONE`. | `MISSING` |
| `revocation.reason` | Заполняется только для `REVOKED`. | `NOT_APPLICABLE` |

## Observed build evidence

| Field | Что доказывает |
| --- | --- |
| `run.provider` и `run.identity` | Где выполнен проверяемый run. |
| `source.observed_commit` | Что checkout совпал с normative source SHA. |
| `command.name` | Какой canonical project command вызван. |
| `command.result` | Exit status и bounded redacted evidence. |
| `toolchain.observed_identity` | Что использован ожидаемый lock/manifest. |
| `artifact.observed_digest` | Что producer получил exact normative digest. |
| `artifact.consumer_digest` | Что независимое чтение из distribution target дало тот же digest. |

## Observed runtime evidence

| Field | Что доказывает |
| --- | --- |
| `runtime.declared_image` | Digest, указанный в deployment input. |
| `runtime.image_id` | Runtime-observed container image identity. |
| `runtime.executable_hash` | Hash реально исполняемого binary, если endpoint/fixture это поддерживает. |
| `runtime.health` | Bounded health/readiness result по product contract. |
| `runtime.cleanup` | Namespace/workload/process absence после teardown. |
| `runtime.diagnostics` | Bounded redacted failure evidence, если scenario красный. |

## Promotion acceptance

Переход разрешён только при выполнении всех условий предыдущего state и новых evidence requirements:

- `CANDIDATE`: source, commands, toolchain и artifact identity совпадают;
- `RUNTIME_VERIFIED`: runtime identity, health и cleanup доказаны для того же digest;
- `PUBLISHED`: independent pull/read verification подтверждает тот же digest;
- `CUSTOMER_READY`: независимый оператор без скрытых команд выполнил полный customer journey;
- `REVOKED`: deployment и дальнейший promotion блокируются, причина сохраняется.

## Failure rules

Следующие ситуации всегда являются failure:

- tag разрешился в digest, отличный от release record;
- observed source SHA отличается от normative source SHA;
- artifact был пересобран между verification и promotion;
- runtime `imageID` или executable hash не соответствует expected identity;
- evidence отсутствует, повреждено или опубликовано без checksum;
- cleanup не доказан;
- customer journey требовал недокументированной ручной команды;
- release содержит secret value или непредусмотренный workstation path.

## Почему пока нет JSON Schema

Flare ещё не определил deployable artifact, supported platforms, config, health и persistence contracts. Создание schema
сейчас закрепило бы догадки как API. После появления этих inputs Platform создаст минимальную machine-readable schema и
intentional RED fixtures только для реально используемых полей.

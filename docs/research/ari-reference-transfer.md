# ARI как reference implementation: что переносим в Flare Platform

Дата анализа: 2026-08-11.

## Область анализа

Проверены переданные snapshots:

- `pipeline-ARI-533 (1)(1).zip`;
- `autotests-dev (5)(1).zip`.

Это reference implementations, а не authoritative Flare contracts. Corporate provider, registry, certificate,
environment и product assumptions не переносятся автоматически.

## Измеренное состояние ARI pipeline

- 40 files;
- 2 047 строк GitLab YAML;
- 99 использований `!reference`;
- 65 упоминаний `CI_PIPELINE_SOURCE`;
- 50 ссылок на corporate registry;
- 38 ссылок на `KUBE_TOKEN`;
- `ci_contract/contract.py`: 1 072 строки;
- `ci_contract/tests/test_contract.py`: 967 строк;
- две функции contract validator длиннее Flare limit 80 строк: 152 и 98 строк;
- девять повторов `HELM_SET_ARGS` в двух YAML-файлах.

Autotests snapshot содержит 11 654 строки Python только под `tools/ci` и их tests. Это зрелая система с полезными
идеями, но она уже показывает стоимость централизованной orchestration и накопленного provider-specific glue.

## ADOPT NOW

### 1. Canonical repository commands

ARI Makefile предоставляет локальные команды для lint, architecture, unit, collection, typing и CI tooling. Flare
Platform уже следует более компактной версии этого подхода: provider workflow вызывает Make, а не дублирует логику.

### 2. Consumer contract для shared CI

Autotests root CI ограничен typed inputs и immutable include SHA. Contract tests запрещают локальным YAML захватывать
shared orchestration. Переносим принцип: cross-repository adapter имеет узкий проверяемый интерфейс.

Не переносим GitLab `include` topology как реализацию для GitHub.

### 3. Explicit unsafe-environment rejection

`run_pytest.py` запрещает regression на PREPROD до запуска suite. Переносим общий принцип: destructive или дорогой
operation должен проверять target identity и policy до любых mutations.

### 4. Deterministic typed publication record

`report_publication.py` создаёт сортированный JSON manifest и строго валидирует URLs при чтении. Переносим принцип для
release/evidence records: producer пишет минимальный deterministic payload, consumer парсит его fail-closed.

### 5. Image cache boundaries

ARI Dockerfile разделяет runtime, dependencies и candidate; dependency install предшествует source copy, а volatile OCI
labels добавляются после дорогих layers. Это хороший reference для будущего Flare image contract.

Не реализуем его сейчас: Flare ещё не опубликовал image/build context contract.

### 6. Resource serialization только для shared mutable target

GitLab `resource_group` используется для общих environments, а production jobs не interruptible. Переносим property,
не синтаксис: один shared mutable target не получает конкурирующие mutations.

Local disposable kind не требует remote lock.

## ADOPT AFTER REAL CONSUMER

- report finalizer и customer-facing publication index;
- STARTED/FINAL notifications с bounded status contract;
- image layer cache metrics;
- environment-specific concurrency keys;
- release gate finalizer;
- persistent Allure history.

До появления соответствующего Flare/Poker journey эти механизмы будут speculative infrastructure.

## REJECT OR REDESIGN

### 1. Corporate environment assumptions

Registry hosts, proxy URLs, certificate chain, deployer tags, Kubernetes tokens и environment names принадлежат ARI.
Они запрещены как defaults в Flare Platform.

### 2. Отключение TLS verification

`tools/image/bootstrap_runtime.py` создаёт TLS context с `CERT_NONE`, а unit test закрепляет это поведение как expected.
Такой bootstrap нельзя переносить. Flare Platform требует проверяемый TLS и content checksum до исполнения download.

### 3. Mutable image/tag-driven deployment

ARI deploy jobs вычисляют release tags и передают image tags в Helm values. Для Flare release contract deployment должен
использовать immutable digest; tag остаётся только discovery metadata.

### 4. Большой central CI contract module

1 072 строки и функции на 152/98 строк нарушают текущую Flare policy. Нужны небольшие validators по responsibility,
а не единый checker всего provider graph.

### 5. Дублирование deployment blocks

Повторные `HELM_SET_ARGS` и environment-specific jobs делают изменения дорогими и конфликтными. Flare не будет строить
matrix abstraction заранее, но при втором реальном target вынесет общий provider-neutral command contract из YAML.

### 6. Long-lived secret variables как базовая auth модель

ARI использует множество `KUBE_TOKEN`/server/namespace variables. Для Flare remote deployment auth выбирается отдельно;
при cloud provider предпочтительны short-lived credentials/OIDC, а не копирование постоянных token values в CI.

### 7. Shared pipeline repository до необходимости

ARI имеет отдельный orchestration repository и глубокий include graph. Flare Platform уже отдельная repo, но не должна
становиться generic CI engine. Reusable workflow появляется только при двух реальных consumers с одинаковой semantics.

## Вывод

ARI полезен как каталог доказанных patterns и предупреждений. Главный переносимый урок — не конкретный набор YAML jobs,
а строгие boundaries, negative contracts, target safety и deterministic evidence. Главный непереносимый слой —
corporate topology и accumulated central orchestration complexity.

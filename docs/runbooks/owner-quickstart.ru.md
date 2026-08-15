# Быстрый старт владельца

## Что нужно

- Linux x86_64 с Bash, Git, curl, GNU tar/timeout и `flock`;
- доступный локальный Docker daemon через Unix socket;
- исходящий HTTPS/registry-доступ для первой загрузки зафиксированных
  инструментов, Kubernetes-схем и kind node image;
- чистый именованный Git checkout для recovery/runtime evidence.

Репозиторий не использует `sudo`, не меняет системные пакеты и не настраивает
Docker. Фактические capability проверяет `make doctor`.

## Полная локальная проверка

```bash
make doctor && make bootstrap && make verify
```

Команда должна завершиться с кодом `0`. Она создаёт приватное состояние
`.platform/`, загружает инструменты строго по `aqua.yaml` и
`aqua-checksums.json`, выполняет static/security и намеренные RED-проверки,
полный non-race recovery proof, собирает локальный Docker image и на время
поднимает disposable kind-кластер. Канонический успешный путь удаляет namespace
и кластер до завершения.

После заполнения `.platform/` обычные запуски Aqua ничего не устанавливают.
Полностью автономный повтор дополнительно требует уже закэшированных схем и
наличия pinned kind node image в локальном Docker; fixture image всегда
собирается локально и во внешний registry не отправляется.

Это доказывает локальный Platform fixture на текущем хосте. Это не доказывает
production, hosted GitHub Actions, удалённый registry/cloud, Flare/Poker runtime
или подлинность издателя recovery capsule.

## Ежедневный цикл

Перед коммитом:

```bash
make check-fast
```

Перед передачей или публикацией:

```bash
make check
make verify
git status --short
git fsck --full
```

Race-enabled recovery — отдельная дорогая maintainer-проверка и не входит в
обычный `make verify`:

```bash
make prove-recovery-race
```

## Если проверка упала

Не подменяйте ошибку старым PASS и не добавляйте `|| true`. Сначала сохраните
свежую ограниченную диагностику:

```bash
make diagnose
make artifact-verify ARCHIVE=.platform/platform-diagnostics.zip
```

Архив и detached checksum находятся в `.platform/`; проверяйте их парой. Код
`75` означает, что другой checkout держит lifecycle lease: дождитесь его
завершения и повторите команду. Код `76` означает небезопасную или повреждённую
lease-границу; не удаляйте её вслепую, используйте сообщение команды и
`docs/runbooks/local-kubernetes.md`.

Безопасное завершение только принадлежащего checkout кластера:

```bash
make kind-down
```

Полная локальная очистка:

```bash
make clean
```

`make clean` сначала удаляет только кластер с подтверждённым ownership marker,
затем удаляет `.platform/`. Инструменты и кэши придётся загрузить заново. Команда
не удаляет чужой/неоднозначный кластер и не меняет системные файлы.

## Изменение версий инструментов

Обычный пользователь запускает только `make bootstrap`. `make tool-lock` —
maintainer-only операция после сознательного изменения версии или registry
revision. Полный порядок находится в `docs/runbooks/tool-updates.md`.

# GitHub remote governance: безопасный профиль активации

Статус на 2026-08-15: частично применено к приватному
`nklmnjaro/flare-platform`. `origin/main` опубликован, а Platform CI
`31904226260` прошёл `static` и `kind-smoke` на
`da420c160f5d68eda7acea0dea7b7998062301e2`. Branch protection и rulesets не
доступны: GitHub API требует GitHub Pro либо public visibility. Поэтому `main`
пока не защищён сервером; менять visibility или тариф без отдельного решения
владельца запрещено.

## 1. Preflight до любого remote action

Зафиксировать в Change:

- exact GitHub organization и repository;
- owner/admin, который разрешил создание или изменение;
- public/private visibility и влияние на Poker access;
- default branch;
- доступный GitHub plan и поддерживаемые ruleset capabilities;
- package namespace/ownership для будущего GHCR;
- кто может approve workflow из fork;
- кто является вторым accountable reviewer, если требуется human approval.

При отсутствии любого обязательного input остаёмся на local bundle. Не создаём repository «временно» и не меняем
visibility по предположению.

## 2. Repository baseline

После первого push и первого успешного CI run настроить ruleset или branch protection для `main`:

Первый push и успешные checks уже выполнены. На текущем private-плане таблица
ниже остаётся целевым контрактом, а не фактическим enforcement: API отвечает
`403`, поэтому PR requirement, required checks и запреты force-push/delete не
применены. Успешный CI run нельзя называть обязательной защитой ветки.

| Setting | Baseline |
| --- | --- |
| Pull request before merge | Required. Direct push запрещён. |
| Required status checks | Включить только после первого реального success каждого check. |
| Force push | Disabled. |
| Branch deletion | Disabled для `main`. |
| Conversation resolution | Required, если команда реально использует review comments. |
| Human approvals | `0`, пока есть только один accountable human; `1` после появления второго. |
| Admin bypass | Только break-glass, с обязательным post-event record. |
| Merge queue | Не включать в первом change. При включении добавить и проверить `merge_group`. |
| Signed commits | Не делать blocking до отдельного signing/identity contract. |
| CODEOWNERS | Не создавать с фиктивными handles. Добавить после точных owner identities. |

PR requirement с нулём approvals не идеален, но лучше прямых push и не создаёт ложный независимый review от бота.

## 3. GitHub Actions policy

- Repository default `GITHUB_TOKEN` permissions: read-only.
- Job повышает permissions только для своей операции.
- Third-party Actions используют full commit SHA, проверенный в upstream repository.
- `pull_request_target` не используется для checkout/исполнения untrusted PR code.
- Workflow остаётся thin adapter к Make/project CLI.
- Каждый job имеет timeout; долгие jobs получают concurrency/cancellation, если безопасно.
- Untrusted PR не получает environment secrets, registry write или remote deploy permissions.
- Cache ускоряет работу, но не является release evidence и не определяет artifact identity.
- Uploaded evidence включает payload и checksum; отсутствие любого файла завершает job ошибкой.
- Dependabot обновляет pinned GitHub Actions отдельными reviewable PR.

## 4. Required checks

Начальный набор Platform repository после online closure:

- canonical static/quality check;
- intentional RED proof;
- disposable kind runtime proof;
- handoff/evidence integrity proof, если он выделен в отдельный check.

Имена required checks фиксируются только после реального run, чтобы repository не заблокировал первый merge
несуществующим status context.

## 5. Merge strategy

До отдельного product decision разрешается только одна стратегия, которая сохраняет Conventional Commit history:

- squash merge при проверяемом Conventional PR title; либо
- rebase merge при проверке каждого commit message.

Не включать оба режима без единого enforcement source. Текущий repository validator проверяет commit messages, поэтому
переход на squash требует отдельного PR-title contract, а не ручного соглашения.

## 6. GHCR activation

GHCR включается только после появления реального OCI image contract.

- publish job получает `contents: read` и `packages: write`;
- обычные CI jobs не получают `packages: write`;
- package связывается с producer repository;
- private cross-repository pull требует явного package access decision;
- personal access token не добавляется, если достаточно repository-scoped `GITHUB_TOKEN`;
- delete/restore permissions не входят в штатный release workflow;
- public anonymous pull допускается только после отдельного visibility decision;
- deployment использует digest, а не tag.

## 7. Artifact attestations

После публикации реального artifact можно ввести GitHub artifact attestation как `ADVISORY`:

1. producer workflow создаёт attestation для exact digest;
2. consumer проверяет repository и, при необходимости, exact signer workflow;
3. verification result входит в release evidence;
4. gate становится `BLOCKING` только после intentional RED, measured noise/cost и customer value.

Attestation связывает artifact с build provenance, но не заменяет vulnerability, runtime или product verification.

## 8. Audit и rollback remote settings

Каждое изменение ruleset, Actions permissions, package visibility или environment protection фиксируется в Change:

- old value;
- new value;
- owner;
- reason;
- verification;
- rollback step.

Remote setting screenshots не являются единственным evidence. Где доступно, сохраняется machine-readable export или
`gh api` response с удалёнными secret values.

## 9. Явно отложено

- branch protection или repository ruleset после явного решения о GitHub Pro
  либо public visibility;
- organization ruleset rollout;
- merge queue;
- release/tag ruleset;
- GHCR publication;
- cloud OIDC;
- GitHub Environment deployment approvals;
- reusable organization workflows;
- self-hosted runners.

Они требуют реального remote, consumer или deployment property и не вводятся «на будущее».

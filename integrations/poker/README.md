# Poker как внешний design partner Flare

Poker не является workload, который команда Flare должна собирать или разворачивать. Poker-команда самостоятельно
разворачивает Flare в своём окружении и использует его в реальной тестовой работе.

Сергей пишет Poker autotests под review владельца тестов. Flare Platform:

- не владеет Poker autotests;
- не меняет Poker ради удобства Flare;
- не добавляет poker-specific logic в Flare core;
- предоставляет воспроизводимый Flare self-deployment path;
- собирает эксплуатационную и продуктовую обратную связь;
- принимает bounded support evidence для диагностики самого Flare.

## Что требуется от Poker до executable deployment guide

Нужен не Poker build/runtime contract, а authoritative consumer-environment contract:

- target topology: local machine, VM или Kubernetes;
- OS/architecture и доступные CPU/memory/storage limits;
- Docker/Kubernetes versions и operator permissions;
- network, proxy, firewall, TLS/CA и registry reachability;
- ingress/port/DNS interface без secret values;
- поддерживаемый способ передачи secrets;
- persistence/backup facilities, которые Poker готов предоставить Flare;
- правила хранения и удаления test logs/attachments;
- endpoint/auth interface, через который Poker autotests отправляют данные во Flare;
- maintenance window для upgrade/rollback;
- способ передать bounded redacted diagnostics команде Flare.

Точные values остаются вне публичной документации, если они sensitive. Platform документирует имена, форматы и checks.

## Customer readiness

Deployment считается `CUSTOMER_READY` только после независимого выполнения Сергеем или другим Poker operator:

1. prerequisites/doctor;
2. deploy exact Flare artifact digest;
3. health verification;
4. отправка минимального тестового события через поддерживаемый interface;
5. просмотр результата в Flare;
6. сбор bounded diagnostics при controlled failure;
7. upgrade на новый digest;
8. rollback на предыдущий digest;
9. uninstall/offboarding с проверкой cleanup.

Assisted run отмечается `ASSISTED` и не выдаётся за self-deployment.

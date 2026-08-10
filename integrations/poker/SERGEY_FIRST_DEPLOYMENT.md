# Серёга: подготовка к первому самостоятельному деплою Flare

Сейчас это checklist подготовки, а не набор выдуманных команд. У Flare ещё нет подтверждённого deployable artifact и
customer deployment contract.

## Что нужно один раз зафиксировать про окружение Poker

1. Где будет работать Flare: рабочая машина, VM или Kubernetes.
2. OS и architecture target host/cluster.
3. Доступные Docker/Kubernetes versions и права operator.
4. Можно ли скачать image из внешнего registry; нужен ли proxy или corporate CA.
5. Какой ingress/port/DNS interface допустим для Flare.
6. Как в Poker environment безопасно передаются secrets.
7. Какое persistence/backup доступно и кто им владеет.
8. Какие limits по CPU, memory и storage реальны.
9. Как долго можно хранить test logs и attachments.
10. Как Poker autotests будут обращаться к Flare: endpoint и auth interface без передачи secret values в чат.
11. Когда допустимы upgrade и rollback.
12. Как передать bounded diagnostics без customer data и credentials.

## Что Platform обязуется предоставить после появления Flare artifact

- exact prerequisites и `doctor`;
- deploy только по immutable digest;
- configuration contract с safe defaults и обязательными fields;
- health/readiness verification;
- минимальный end-to-end acceptance scenario;
- bounded diagnostics;
- upgrade без пересборки artifact;
- rollback на предыдущий digest;
- uninstall/offboarding и cleanup proof;
- короткий troubleshooting tree.

## Как будет приниматься результат

Первый прогон может быть `ASSISTED`: Platform наблюдает и фиксирует пробелы. Второй прогон должен выполнить Poker
operator по репозиторию и документации без скрытых команд. Только после второго прогона статус может стать
`CUSTOMER_READY`.

Flare-команда не забирает Poker autotests себе и не просит менять их архитектуру под внутренности Flare. Нужен только
подтверждённый внешний interface и feedback по реальному использованию.

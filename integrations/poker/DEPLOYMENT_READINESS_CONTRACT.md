# Poker deployment readiness contract

Статус: input contract; executable deployment blocked until Flare publishes a deployable artifact.

## Ownership

| Area | Owner |
| --- | --- |
| Flare application build/test/runtime semantics | Flare repository |
| Platform CI, artifact distribution и deployment mechanics | Flare Platform repository |
| Poker environment, access policy и operator actions | Poker team |
| Poker autotests и их review | Сергей и владелец Poker tests |
| Product feedback prioritization | Flare Product Owner |

## Environment inputs

Для каждого field применяется status: `MISSING`, `DECLARED`, `VERIFIED`, `NOT_APPLICABLE`.

| Input | Нужное evidence | Status |
| --- | --- | --- |
| target topology | Название класса target без credentials. | `MISSING` |
| OS/architecture | Machine-readable values. | `MISSING` |
| container runtime/Kubernetes | Exact versions и доступные APIs. | `MISSING` |
| operator permissions | Список допустимых operations. | `MISSING` |
| network egress | Registry/API reachability probe. | `MISSING` |
| proxy/CA | Interface и install method, без secret material. | `MISSING` |
| ingress/DNS/TLS | Allowed interface и ownership. | `MISSING` |
| secret injection | Supported mechanism и secret names only. | `MISSING` |
| persistence | Storage class/path, backup и restore ownership. | `MISSING` |
| resource budget | CPU, memory, storage limits. | `MISSING` |
| data retention | Logs/attachments retention и deletion policy. | `MISSING` |
| Poker-to-Flare interface | Endpoint/auth contract revision. | `MISSING` |
| maintenance window | Upgrade/rollback constraints. | `MISSING` |
| support evidence channel | Bounded redacted package transfer method. | `MISSING` |

## Flare inputs

| Input | Required before deploy |
| --- | --- |
| authoritative source commit | Yes |
| deployable artifact digest | Yes |
| supported platforms | Yes |
| configuration contract | Yes |
| health/readiness contract | Yes |
| persistence/migration contract | Yes when stateful |
| upgrade compatibility | Yes |
| rollback procedure | Yes |
| uninstall/offboarding procedure | Yes |
| evidence collection boundary | Yes |

## Acceptance journeys

### POKER-DEPLOY-01: clean install

- doctor passes;
- exact digest is pulled/loaded;
- declared and observed image identity match;
- health contract passes;
- no undocumented manual command is required.

### POKER-DEPLOY-02: minimal real use

- Poker sends one supported test event through the public contract;
- Flare accepts and exposes the result through its supported UI/API;
- no Poker-specific code exists in Flare core.

### POKER-DEPLOY-03: controlled failure

- one documented dependency/config failure is induced;
- failure is visible and bounded;
- diagnostics contain no secret or customer payload outside the accepted evidence policy;
- recovery returns the same release to healthy state.

### POKER-DEPLOY-04: upgrade

- previous digest is healthy;
- new digest is applied without rebuilding;
- compatibility/migration checks run;
- health and minimal real-use scenario pass.

### POKER-DEPLOY-05: rollback

- prior accepted digest and compatible configuration are restored;
- health and minimal real-use scenario pass;
- no ambiguous mutable tag is used.

### POKER-DEPLOY-06: uninstall/offboarding

- Flare workloads and Platform-owned resources are absent;
- intentionally retained data is listed explicitly;
- credentials/access granted only for Flare are revoked or removal is assigned to an owner;
- cleanup failure is not reported as success.

## Support boundary

Platform accepts a bounded evidence package containing versions, exact artifact identity, health results, events,
resource state and redacted logs. It does not request raw kubeconfig, registry tokens, Poker test source or unrestricted
environment dumps.

No support SLA, production availability promise or on-call commitment exists until Product Owner approves it explicitly.

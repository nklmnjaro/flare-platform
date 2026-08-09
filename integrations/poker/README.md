# Poker onboarding contract

Poker is the first external design partner/reference workload, but this repository does not yet contain
an authoritative Poker repository or runtime contract. Platform foundation work continues without
inventing Poker-specific behavior.

Before an executable deployment guide is produced, Poker/Sergey needs to provide or authorize access to:

- exact repository identity and revision/branch policy;
- canonical local build, test, check, and run commands;
- produced artifact or image contract;
- service ports and health/readiness behavior;
- configuration schema and required environment variables;
- secret **names/interfaces only**, never secret values in documentation;
- persistence/database dependencies, if any;
- expected local and target deployment topology;
- rollback and cleanup expectations.

Once these inputs exist, Platform will turn them into a bounded self-deployment path that Sergey can run
without internal Flare-team intervention. Assisted steps must remain explicitly marked `ASSISTED` until
self-deployment succeeds independently.

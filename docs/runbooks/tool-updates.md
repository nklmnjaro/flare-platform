# Tool update runbook

Tool versions are changed in `aqua.yaml`, not scattered across scripts or CI.

For the initial bootstrap on an online host:

1. run `make bootstrap`;
2. run `make tool-lock`;
3. confirm `aqua-checksums.json` is non-empty and `require_checksum: true` is set;
4. run `make bootstrap` again to prove the locked configuration is idempotent;
5. commit `aqua.yaml` and `aqua-checksums.json` together.

For a later tool update:

1. confirm the upstream release and security status from its primary source;
2. update the exact package version and Aqua registry revision if required;
3. run `make tool-lock` to refresh and prune the checksum lock;
4. run `make bootstrap` from clean `.platform/` state;
5. run `make prove-gates` and verify each RED fixture still fails for the intended reason;
6. run `make check` and `make verify`;
7. review behavior/noise before treating the new version as blocking;
8. commit the version change, checksum lock, and evidence together.

Do not update security tools purely because a newer tag exists. Supply-chain history, release provenance,
and negative-test behavior are part of the decision.

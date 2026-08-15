# Tool update runbook

Tool versions are changed in `aqua.yaml`, not scattered across scripts or CI.

For ordinary first use on an online host:

1. run `make bootstrap`;
2. run `CI=true make bootstrap` if CI admission also needs local proof;
3. do not run `make tool-lock` and do not modify either tracked lock file.

The committed `aqua-checksums.json` and `require_checksum: true` setting are the
ordinary install boundary. `make tool-lock` is a maintainer-only mutation used
after an intentional version or registry change; it is never a repair step for
a normal bootstrap failure.

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

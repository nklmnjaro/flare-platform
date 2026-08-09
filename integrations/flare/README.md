# Flare integration boundary

Authoritative Flare baseline for this platform bootstrap:

`19d004da25f0658b3e610899f04f086e3a441628`

No Flare source is modified by this repository.

Before wiring a Flare GitHub workflow, read the exact canonical commands from that baseline and bind the
provider adapter to them. Do not infer or reimplement build/test/check semantics from historical CI or
from this platform repository.

Required integration inputs:

- repository identity and protected default branch;
- canonical bootstrap/doctor/check/check-fast/verify commands;
- artifact/image output contract;
- runtime configuration boundary;
- health/readiness contract when runtime work is authorized;
- rollback/cleanup command contract.

Until those inputs are read from the authoritative Flare tree, application CI integration remains
`NOT_RUN`, not green-by-assumption.

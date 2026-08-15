# Security policy

## Supported scope

Security fixes are made on the current default branch. This repository proves a
local Platform reference fixture; it is not a production Kubernetes, cloud,
registry, Flare, or Poker security boundary.

## Private reporting

Do not place a real credential, private workstation path, or unredacted
diagnostic archive in an issue. Prefer a private GitHub Security Advisory for
the repository. If that channel is unavailable, contact the repository owner
through an existing private channel before sharing reproduction material.

Include:

- exact commit and tree;
- affected canonical command;
- expected and observed status/reason;
- smallest synthetic reproducer;
- whether any external target was mutated;
- proposed containment, without destructive cleanup.

## Evidence rules

- Use synthetic canaries only; rotate any real secret before reporting it.
- Preserve the failing bytes and detached checksum without editing them.
- A checksum proves received-byte integrity, not publisher authenticity.
- Recovery capsules preserve exact Git history, including author/committer
  metadata and any secret ever committed to reachable history.
- A previous PASS never overrides a failure on changed source or tooling.
- Do not run untrusted capsules without an isolated, resource-bounded receiver.

Public issues may describe an already-contained problem after private material
has been removed. Release promotion and disclosure timing are explicit owner
decisions, not automatic consequences of a local fix.

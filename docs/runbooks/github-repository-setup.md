# GitHub repository setup

The live target is the private repository
[`nklmnjaro/flare-platform`](https://github.com/nklmnjaro/flare-platform), with
`main` as its default branch. It was activated on 2026-08-15 after the local
candidate was accepted.

## Observed activation state

- merge commits and squash merges are disabled; rebase merge is enabled;
- merged branches are deleted, web commit sign-off is required, and repository
  projects/wiki are disabled;
- Actions are limited to GitHub-owned actions; the default workflow token is
  read-only and cannot approve pull requests;
- vulnerability alerts and Dependabot automated security fixes are enabled;
- Platform CI run
  [`31904226260`](https://github.com/nklmnjaro/flare-platform/actions/runs/31904226260)
  passed `static` and `kind-smoke` on commit
  `da420c160f5d68eda7acea0dea7b7998062301e2`.

`main` is **not protected**. Both branch-protection and repository-ruleset APIs
return `403 Upgrade to GitHub Pro or make this repository public to enable this
feature` for this private repository. Consequently successful CI is observed,
but pull requests, required checks, force-push prevention, and branch-deletion
prevention are not server-enforced. Do not change visibility or purchase a plan
implicitly. Apply the policy below only after an explicit owner decision makes
one of those mechanisms available.

GitHub code scanning and secret scanning are also not enabled on the current
plan. The repository-local Trivy/zizmor gates remain useful checks, but are not
represented as server-side GitHub Advanced Security.

## Target policy when protection is available

Minimum repository policy:

- default branch: `main`;
- pull requests required for `main`;
- required checks: `static` and `kind-smoke` after their first proven run;
- branch deletion after merge allowed;
- force-push and branch deletion disabled for `main`;
- GitHub Actions default token permissions set to read-only;
- workflow approval policy reviewed before accepting contributions from forks.

The workflow itself declares `contents: read`, does not use
`pull_request_target`, and pins third-party actions to immutable full commit SHA
references.

The first successful real runs now exist. When protection becomes available,
bind the exact `static` and `kind-smoke` contexts and read the result back before
claiming enforcement.

## Reproduce the live observation

```bash
gh repo view nklmnjaro/flare-platform \
  --json nameWithOwner,visibility,defaultBranchRef,url
gh api repos/nklmnjaro/flare-platform/actions/permissions
gh api repos/nklmnjaro/flare-platform/actions/permissions/selected-actions
gh api repos/nklmnjaro/flare-platform/actions/permissions/workflow
gh api --include repos/nklmnjaro/flare-platform/vulnerability-alerts
gh api repos/nklmnjaro/flare-platform/automated-security-fixes
gh run view 31904226260 --repo nklmnjaro/flare-platform
gh api repos/nklmnjaro/flare-platform/branches/main/protection
```

The final command is expected to return the plan-related `403` until the owner
changes the plan or visibility. A later `200` is a state change that requires a
fresh machine-readable policy review.

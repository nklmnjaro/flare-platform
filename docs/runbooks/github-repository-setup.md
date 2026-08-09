# GitHub repository setup

This file describes the external step after the local repository candidate is accepted.

Minimum repository policy:

- default branch: `main`;
- pull requests required for `main`;
- required checks: `static` and `kind-smoke` after their first proven run;
- branch deletion after merge allowed;
- force-push and branch deletion disabled for `main`;
- GitHub Actions default token permissions set to read-only;
- workflow approval policy reviewed before accepting contributions from forks.

The workflow itself declares `contents: read`, does not use `pull_request_target`, and pins third-party
actions to immutable full commit SHA references.

Do not enable required checks before they have completed successfully at least once in the real GitHub
repository; otherwise repository setup can deadlock its own first merge.

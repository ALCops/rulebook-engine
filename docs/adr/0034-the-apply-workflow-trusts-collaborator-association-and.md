# D34. The apply workflow trusts collaborator association and nothing else

- **Status:** Accepted
- **Date:** 2026-10-03

- **Decision:** the apply workflow acts only when the issue author's `author_association` is `OWNER`, `MEMBER` or `COLLABORATOR`. Anyone else gets one comment and the issue is closed as not planned, before the body is parsed. The pull request review is the second gate; there is no approval label.
- **Rationale:** on a public repository anyone can open an issue, and a label-filtered workflow is a public entry point. Collaborator association is the permission model the organization already manages; it needs no list in the settings and no second login.
- **Rejected:** anyone who can open an issue (direct-commit mode would let a stranger change the endpoints); a maintainer-added approval label before the workflow runs (a second step for every change, and the PR already is the review).
- **Consequences:** direct-commit mode is safe only because of this gate, which the docs state. `edited` events re-check the author of the issue.
- **Affects:** WP15.

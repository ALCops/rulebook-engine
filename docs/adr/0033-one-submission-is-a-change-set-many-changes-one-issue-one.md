# D33. One submission is a change set: many changes, one issue, one pull request or commit

- **Status:** Accepted
- **Date:** 2026-10-03

- **Decision:** the cart collects any number of changes and submits them as one change set in one issue. The apply workflow applies them all or none, regenerates once, and lands them as one pull request, or as one direct commit when `commitOptions.createPullRequest` is false, the same setting ChangeRule honours. The pull request body carries the optional batch note and the before/after table per endpoint; `Closes #<issue>` links them.
- **Rationale:** a maintainer who reviews a matrix changes several cells in one sitting; one issue per click would flood the repository and split one decision over many pull requests. All-or-nothing keeps a half-applied cart from reaching the endpoints. Reusing `commitOptions` keeps one setting for how changes land.
- **Rejected:** one change per issue (simplest, but noisy and splits related changes); a cart that the workflow splits into one PR per rule (independent review and revert, but the org asked for one PR); a per-issue choice between PR and commit (a second place for a setting that already exists).
- **Consequences:** the change-set schema has `changes[]`; the cart shows the encoded size against the URL limit and offers split and copy when it is exceeded; the apply workflow guards against a second run while a PR for the issue is open.
- **Affects:** WP14, WP15.

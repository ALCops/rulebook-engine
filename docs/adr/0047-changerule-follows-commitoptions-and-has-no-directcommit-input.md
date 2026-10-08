# D47. ChangeRule follows commitOptions.createPullRequest and has no directCommit input

- **Status:** Accepted
- **Date:** 2026-10-08

- **Decision:** where a change of the Change Rule workflow lands is decided by `commitOptions.createPullRequest` of the settings on every run (true or absent: a pull request on `change-rule/<ruleId>/<yyMMddHHmmss>`; false: a direct commit to the branch the workflow runs on, falling back to the pull request when the push is refused), and the form has no `directCommit` input.
- **Rationale:** the Update and Scan workflows take `directCommit` from the form on a manual run and from the setting on a scheduled run. Change Rule has only manual runs, so that rule would never let the setting apply and every organization that wants direct commits would have to tick a box on every change. One switch in the settings states the organization's policy once, the same way for every person who runs the form, and a protected branch still gets its pull request through the fallback.
- **Rejected:** a boolean `directCommit` input like the update workflow (the setting would never apply, and the form gets a field that bypasses review on a click); a choice input `settings | pullRequest | directCommit` (a third form field for a rare need, and the default would still have to be the setting); always a pull request (ignores `commitOptions.createPullRequest`, which the dashboard write path, D33, follows too).
- **Consequences:** the workflow's "Read the settings" step derives `directCommit = -not createPullRequest` on every run and passes it to the action; the action keeps a `directCommit` input for other callers. Documented in [reference/change-mechanics.md](../reference/change-mechanics.md) section 7 and the user page `docs/changing-a-rule.md`.
- **Affects:** WP09 ([#11](https://github.com/ALCops/rulebook-engine/issues/11)), WP15 (the change-set workflow follows the same setting).

# D11. Rule changes go through a workflow_dispatch form

- **Status:** Partly superseded by D32 (2026-10-03)
- **Date:** 2026-09-29

- **Partly superseded** by D32 (2026-10-03): the rejection of issue forms and of a web UI no longer holds. A prefilled issue form applied by a workflow is the dashboard's write path, with the choice lists problem solved by D30 and the hosted-service problem avoided by using the submitter's GitHub session. The `workflow_dispatch` form stays as a second entry point that calls the same module.
- **Decision:** the `ChangeRule` workflow takes rule id, action, scope, levels, targets, stages and justification as inputs, edits the right files and opens a pull request.
- **Rationale:** GitHub renders choice inputs as dropdowns, no extra infrastructure, same UX as AL-Go workflows. The action is designed so a later web UI or VS Code extension can call it.
- **Rejected:** issue forms (static choice lists, parsing fragility); a web UI on alcops.dev for v1 (needs a hosted service and a GitHub App; kept as a post-1.0 idea).
- **Consequences:** the action must know the layer model well enough to write to level files or endpoint roots (WP09).
- **Affects:** WP09, WP11.

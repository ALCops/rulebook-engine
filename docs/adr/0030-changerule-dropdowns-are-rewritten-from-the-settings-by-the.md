# D30. ChangeRule dropdowns are rewritten from the settings by the update workflow

- **Status:** Accepted
- **Date:** 2026-10-01

- **Decision:** the `levels` and `stages` inputs of `ChangeRule.yaml` stay `choice` inputs. Their option lists are the slugs from `settings.levels` and `settings.stages` plus `*`, written by `CheckForUpdates` whenever it rewrites the workflow file, in the same pass that AL-Go uses to rewrite workflow content from settings.
- **Rationale:** a configurable set cannot have a static choice list, and free text loses the dropdown that made the form usable without documentation. AL-Go already rewrites workflow yaml from settings on every update (`GetWorkflowContentWithChangesFromSettings`), so the mechanism exists and is ported anyway.
- **Rejected:** free text for both inputs, validated against the settings (works, but every rule change starts with a typo risk); dropdowns for the shipped set only with free text as fallback (two code paths).
- **Consequences:** an organization that adds a level or stage sees it in the form after the next update run (or runs the update manually). `CheckForUpdates` gains a workflow rewrite step for `ChangeRule.yaml` (WP07); WP09's open question on dropdowns is closed. Selector values in `overrides.json` are slugs (D28).
- **Affects:** WP07, WP09.

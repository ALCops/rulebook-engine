# D25. `L0` is removed; the starting point is the closest shipped level plus overrides

- **Status:** Accepted
- **Date:** 2026-10-01

- **Decision:** the template ships no "everything off" level. An organization starts from the shipped level closest to its practice and adjusts with `overrides.json`. An organization that wants everything off adds its own root level (D27) whose file lists every enabled-by-default catalog id at `None`, generated once by a helper (`New-RulebookOffLevel`, WP10) and org-owned afterwards. Requirement R6-A is met that way.
- **Rationale:** an all-`None` file decides nothing, yet it needed its own regeneration path in the daily scan and a thirteenth endpoint, skeleton and base file. With deltas at the source (D27) the same content is one org-owned file.
- **Rejected:** keeping `L0` as a shipped level (what this entry removes); a shipped `rulesets/off.ruleset.json` outside the level list (a special case in every generator and validator for one file); a recipe only, without a helper (628 ids to type by hand).
- **Consequences:** 12 endpoints, skeletons and base files in the shipped set instead of 13. The scan regenerates `rulesets/` only. The migration guide says "pick the closest level, then override". The `L0` sentences of D4, D15, D18 and D22 are superseded.
- **Affects:** WP02, WP03, WP04, WP05, WP08, WP10, WP11.

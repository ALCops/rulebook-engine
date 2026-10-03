# D15. Four named content levels, L0 kept, L5 dropped

- **Status:** Superseded by D25, D26 and D28 (2026-10-01)
- **Date:** 2026-09-29

- **Superseded** by D25, D26 and D28 (2026-10-01): `L0` removed, the `L<n>` ids removed, the four names are the identity and the set is configuration.
- **Decision:** the template ships `L0` (everything `None`) plus four content levels `L1` Essential, `L2` Recommended, `L3` Strict and `L4` Complete. `L5` is removed. Ids stay `L<n>`; the names are `settings.levels[].name`.
- **Rationale:** the rule interview of 2026-09-29 settled on four levels a user understands without documentation: cannot ship without, healthy project, quality gate, everything. A fifth placeholder would cost nine endpoint files and decide nothing. `L0` stays as the opt-out starting point (R6-A).
- **Rejected:** metal names (memorable, meaning must be explained); three levels (too coarse for the Info versus Warning dial); five levels (nothing left to put in the fifth).
- **Consequences:** `Rulebook-Settings.json` lists five levels; 45 endpoint roots and skeletons instead of 54. Level content is specified in `docs/rulebook/` (D16).
- **Affects:** WP02, WP04, WP10. Supersedes the level count in D4; D4's "names are configuration" still holds.

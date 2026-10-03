# D23. Twin pairs are an organization setting

- **Status:** Accepted
- **Date:** 2026-10-01

- **Decision:** the 17 PerTenantExtensionCop/AppSourceCop twin pairs (identical check in both cops) are both active at their native ladder in the matrix. `Rulebook-Settings.json` gains `"twins"` with the values `both` (default), `appsource` and `pte`. The generator writes the losing side of every pair at `None` when the setting is `appsource` or `pte`. The engine exports the pair list as `docs/rulebook/matrix/twins.json`, generated from the `twin:` flags of the inventory, and the template ships it as the system file `base/twins.json`. Precedence per id: override, then twins setting, then base, then quarantine.
- **Rationale:** with both cops enabled a twin reports twice on the same line. Which side to keep is an organization-wide choice, not a matrix decision and not a per-project one. A setting with a shipped pair list means new twins reach organizations through the update workflow. Rulebook cannot read a project's `al.codeAnalyzers`, so the rule "if you run only one cop, keep `both`" is documentation, not validation.
- **Rejected:** keeping the twin choice as a matrix dimension (that is the target again); 17 override entries per organization (hand-maintained, no update path); dropping one side in the matrix (loses the check for projects that disable the other cop).
- **Consequences:** `base/twins.json` is a system file in the update file classes. `Rulebook.Generate` gains a twins step with provenance `twins`. The near-twins PTE0006/AS0060, PTE0007/AS0058 and PTE0020/AS0085 check different things and stay out of the list (DR-020).
- **Affects:** WP02, WP03, WP04, WP07, WP11.

# D24. The catalog records analyzer defaults and the scan reports changes

- **Status:** Accepted
- **Date:** 2026-10-01

- **Decision:** every entry of `catalog/diagnostics.json` carries `defaultSeverity` and `enabledByDefault`. The daily scan compares them with the extracted descriptors, lists every changed default in its pull request, and regenerates the endpoints so that a deviation that newly equals the default disappears from the file and an id whose default moved away from the base action appears.
- **Rationale:** sparse endpoints (D22) make the analyzer default part of the effective ruleset. Following the author is the intent, but an organization must be able to see when and why a rule changed.
- **Rejected:** accepting the drift silently (cheapest; no trace); pinning an id explicitly once its default changed (most protective; adds tooling and makes endpoints grow back).
- **Consequences:** the template seeds the catalog from the inventory with both fields (WP04); the scan diff gains a "default changed" section (WP08).
- **Affects:** WP04, WP08.

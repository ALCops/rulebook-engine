# D37. Justification is optional in every change path

- **Status:** Accepted
- **Date:** 2026-10-03

- **Decision:** a justification on an override entry, a change-set item or the ChangeRule form is optional. The change set also has an optional batch note that becomes the pull request body.
- **Rationale:** the owner chose "optional everywhere": a required field on a click-driven dashboard turns every cell change into a form, and the pull request is where the reason is discussed anyway. The field keeps its place in the files for organizations that use it.
- **Rejected:** required per change (WP09 as written; blocks the cart); required per batch only (one text copied into every entry says nothing per rule).
- **Consequences:** WP09's `justification` input and `Set-RulebookOverride` accept an empty value; the overrides schema marks it optional; validation never fails on a missing justification.
- **Affects:** WP02, WP09, WP15.

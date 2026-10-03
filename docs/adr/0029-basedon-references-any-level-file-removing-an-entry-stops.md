# D29. `basedOn` references any level file; removing an entry stops publishing, not content

- **Status:** Accepted
- **Date:** 2026-10-01

- **Decision:** `basedOn` names a level file by name, whether or not that level is listed in `settings.levels`. Removing an entry from `levels` or `stages` stops generating its endpoints, skeletons and docs page; the shipped file stays in the repository and keeps being overwritten by the update until the organization lists it in `unusedRulebookFiles` (WP07). A file in `base/` or `stages/` that no entry references and that is not excluded is a validation warning (C9). Cycles are an error (C5).
- **Rationale:** decouples "what content exists" from "what is published". An organization can stop publishing Essential and keep Recommended, which is based on it, without copying anything. An alias level (D28) is the same mechanism.
- **Rejected:** `basedOn` must name the previous array entry (removing or reordering an entry breaks the chain, and inserting a level means repointing the one above); a `publish: false` flag per entry (a second way to say "not listed"); deleting the shipped file on removal (the update re-adds it; AL-Go's exclude list is the existing answer).
- **Consequences:** `Resolve-LevelChain` reads files, not entries. The index page lists published levels only. The update's exclude handling (`unusedRulebookFiles`) covers level and stage files.
- **Affects:** WP02, WP03, WP07, WP10.

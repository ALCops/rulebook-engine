# D14. The quarantine policy is configured per org, with no default

- **Status:** Partly superseded by D26 (2026-10-01)
- **Date:** 2026-09-29

- **Partly superseded** by D26 (2026-10-01): the stage set is configurable; `quarantine.stages` and `prereleaseStages` hold stage slugs from `settings.stages`. The no-default policy stands.
- **Decision:** `Rulebook-Settings.json` has `quarantine.stages` (which stages receive new stable-release ids at `None`) and `quarantine.prereleaseStages` (same for ids first seen in a prerelease package). The scan workflow fails with a clear message until both are set.
- **Rationale:** whether developers should see new rules immediately, and whether pipelines may go red on them, is a team decision. A silent default would surprise one half of the teams.
- **Rejected:** default "dev and cicd quarantined, nextmajor sees everything" (the model of the blob-hosted setup that preceded Rulebook, sensible but opinionated); "only cicd quarantined".
- **Consequences:** the template documents the two common policies and the getting-started guide makes the user choose in step 2.
- **Affects:** WP08, WP11.

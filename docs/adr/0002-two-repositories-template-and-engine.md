# D2. Two repositories: template and engine

- **Status:** Accepted
- **Date:** 2026-09-29

- **Decision:** `ALCops/rulebook` is the clean public template with the "Use this template" button and the user-facing docs. `ALCops/rulebook-engine` holds the composite actions, PowerShell modules, tests, architecture, decisions and workpackages. Org repo workflows reference `ALCops/rulebook-engine/actions/<Name>@v1`.
- **Rationale:** a template copy should contain only what an org needs. Logic that changes often lives in one place and is versioned by branch, so a bug fix reaches every org without an update PR.
- **Rejected:** one repo with `is_template` (tests and engine code copied into every org); three repos like AL-Go (source, actions, template) as more maintenance than the size of the project warrants.
- **Consequences:** a deploy step copies `template/` from the engine into the template and pins `@main` to `@v1` (WP13). Docs are split: user docs in the template, contributor docs in the engine.
- **Affects:** WP00, WP13, all action WPs.

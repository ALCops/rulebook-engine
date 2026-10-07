# Rulebook decision records

Every decision that shapes Rulebook, one file per decision, with the alternatives that were considered and why they lost. The numbers are the `D` numbers used throughout the docs: `D12` is [0012](0012-testing-scope-for-v1-is-pester-unit-tests.md). Open decisions are tracked as issues labeled [`decision`](https://github.com/ALCops/rulebook-engine/issues?q=is%3Aissue+label%3Adecision) and closed by the pull request that adds the record.

> **Rule:** a decision is changed by adding a new record that supersedes the old one, never by editing history. The superseded record gets a status line pointing forward and keeps its text.

## Adding a record

1. Copy [0000-adr-template.md](0000-adr-template.md) to `NNNN-kebab-title.md` with the next free number.
2. Fill the five fields. Keep the decision to one sentence; put the discussion in Rationale and Rejected.
3. Add a row to the index below. If the record supersedes an earlier one, add the status line to that earlier record.

## Format

| Field | Meaning |
|---|---|
| Decision | What was decided, in one sentence. |
| Rationale | Why. |
| Rejected | The alternatives and the reason each one lost. |
| Consequences | What the decision forces elsewhere in the design. |
| Affects | Work packages (issues) that implement or depend on it. |

## Index

D1 to D14 were taken in the requirements interview of 2026-09-29, D15 to D20 in the rule interview of the same day, D21 to D24 in the interview of 2026-10-01 that removed the target dimension, D25 to D30 in the second interview of 2026-10-01 that dropped `L0`, made levels and stages configuration and turned the source files into deltas, D31 to D37 in the interview of 2026-10-03 that added the dashboard and the issue-form write path, D38 and D39 in the bootstrap interview of the same day (WP00) that chose generated release notes and Pester 6, D40 in the WP02 planning interview of 2026-10-04 that made the justification optional in level and stage files, D41 in the WP03 planning interview of 2026-10-05 that let quarantine win over a stage entry for an id no level file mentions, D42 in the WP05 planning interview of 2026-10-06 that made Publish a gate that never commits, D43 in the WP06 planning interview of the same day that publishes `rulebook.json` with the levels and stages, D44 in the WP07 planning interview of 2026-10-07 that keeps the AL-Go secret `GHTOKENWORKFLOW` and its format for the write token, and D45 and D46 in the WP08 planning interview of the same day that made the scan keep one living pull request and treat seeded, unadvertised, deprecated and vanished ids as catalog facts.

| # | Title | Status | Date |
|---|---|---|---|
| [D1](0001-topology-one-rulebook-repo-per-organization.md) | Topology: one rulebook repo per organization | Accepted | 2026-09-29 |
| [D2](0002-two-repositories-template-and-engine.md) | Two repositories: template and engine | Accepted | 2026-09-29 |
| [D3](0003-managed-levels-are-vendored-into-the-org-repo.md) | Managed levels are vendored into the org repo | Accepted | 2026-09-29 |
| [D4](0004-level-content-starts-empty-placeholder-names-l0-to-l5.md) | Level content starts empty, placeholder names L0 to L5 | Superseded by D25, D26 and D28 (2026-10-01) | 2026-09-29 |
| [D5](0005-endpoint-dimensions-level-x-target-x-stage.md) | Endpoint dimensions: level x target x stage | Partly superseded by D21 and D28 (2026-10-01) | 2026-09-29 |
| [D6](0006-levels-are-cumulative.md) | Levels are cumulative | Superseded by D18, partly reinstated by D27 (2026-10-01) | 2026-09-29 |
| [D7](0007-hosting-is-pluggable-github-pages-is-the-default.md) | Hosting is pluggable, GitHub Pages is the default | Accepted | 2026-09-29 |
| [D8](0008-endpoint-urls-are-unversioned-in-v1.md) | Endpoint URLs are unversioned in v1 | Accepted | 2026-09-29 |
| [D9](0009-tooling-powershell-7-and-pester-on-ubuntu-runners.md) | Tooling: PowerShell 7 and Pester on ubuntu runners | Partly superseded by D39 (2026-10-03) | 2026-09-29 |
| [D10](0010-the-diagnostic-scan-runs-in-each-org-repo.md) | The diagnostic scan runs in each org repo | Accepted | 2026-09-29 |
| [D11](0011-rule-changes-go-through-a-workflow-dispatch-form.md) | Rule changes go through a workflow_dispatch form | Partly superseded by D32 (2026-10-03) | 2026-09-29 |
| [D12](0012-testing-scope-for-v1-is-pester-unit-tests.md) | Testing scope for v1 is Pester unit tests | Partly superseded by D39 (2026-10-03) | 2026-09-29 |
| [D13](0013-compiler-format-files-are-the-source-and-are-published-as-is.md) | Compiler-format files are the source and are published as-is | Superseded by D18 (2026-09-29) | 2026-09-29 |
| [D14](0014-the-quarantine-policy-is-configured-per-org-with-no-default.md) | The quarantine policy is configured per org, with no default | Partly superseded by D26 (2026-10-01) | 2026-09-29 |
| [D15](0015-four-named-content-levels-l0-kept-l5-dropped.md) | Four named content levels, L0 kept, L5 dropped | Superseded by D25, D26 and D28 (2026-10-01) | 2026-09-29 |
| [D16](0016-level-content-comes-from-a-markdown-matrix-target-and-stage.md) | Level content comes from a Markdown matrix; target and stage layers are generated ancestors | Accepted | 2026-09-29 |
| [D17](0017-stage-treatment-is-decided-per-rule-in-the-matrix.md) | Stage treatment is decided per rule in the matrix | Partly superseded by D26 and D27 (2026-10-01) | 2026-09-29 |
| [D18](0018-every-endpoint-is-one-flat-ruleset-file-there-is-no-include.md) | Every endpoint is one flat ruleset file; there is no include chain | Partly superseded by D25 and D28 (2026-10-01) | 2026-09-29 |
| [D19](0019-organization-overrides-and-quarantine-are-generator-inputs.md) | Organization overrides and quarantine are generator inputs | Partly superseded by D27 (2026-10-01) | 2026-09-29 |
| [D20](0020-custom-levels-are-out-of-scope-for-v1.md) | Custom levels are out of scope for v1 | Superseded by D26, D27 and D29 (2026-10-01) | 2026-09-29 |
| [D21](0021-no-target-dimension-one-ladder-per-rule-both-microsoft-cops.md) | No target dimension: one ladder per rule, both Microsoft cops at their native severity | Partly superseded by D25 and D28 (2026-10-01) | 2026-10-01 |
| [D22](0022-sparse-endpoints-an-id-at-its-analyzer-default-is-not-listed.md) | Sparse endpoints: an id at its analyzer default is not listed | Partly superseded by D25 and D27 (2026-10-01) | 2026-10-01 |
| [D23](0023-twin-pairs-are-an-organization-setting.md) | Twin pairs are an organization setting | Accepted | 2026-10-01 |
| [D24](0024-the-catalog-records-analyzer-defaults-and-the-scan-reports.md) | The catalog records analyzer defaults and the scan reports changes | Accepted | 2026-10-01 |
| [D25](0025-l0-is-removed-the-starting-point-is-the-closest-shipped.md) | `L0` is removed; the starting point is the closest shipped level plus overrides | Accepted | 2026-10-01 |
| [D26](0026-levels-and-stages-are-configuration.md) | Levels and stages are configuration | Accepted | 2026-10-01 |
| [D27](0027-source-files-are-deltas-level-chain-and-stage-deltas-flat.md) | Source files are deltas: level chain and stage deltas, flat sparse endpoints | Accepted | 2026-10-01 |
| [D28](0028-identity-is-one-name-the-slug-names-every-file-url-selector.md) | Identity is one `name`; the slug names every file, URL, selector and key | Accepted | 2026-10-01 |
| [D29](0029-basedon-references-any-level-file-removing-an-entry-stops.md) | `basedOn` references any level file; removing an entry stops publishing, not content | Accepted | 2026-10-01 |
| [D30](0030-changerule-dropdowns-are-rewritten-from-the-settings-by-the.md) | ChangeRule dropdowns are rewritten from the settings by the update workflow | Accepted | 2026-10-01 |
| [D31](0031-the-dashboard-is-a-hugo-site-shipped-in-the-template-and.md) | The dashboard is a Hugo site shipped in the template and published next to the endpoints | Accepted | 2026-10-03 |
| [D32](0032-dashboard-writes-go-through-a-prefilled-github-issue-form.md) | Dashboard writes go through a prefilled GitHub issue form applied by a workflow | Accepted | 2026-10-03 |
| [D33](0033-one-submission-is-a-change-set-many-changes-one-issue-one.md) | One submission is a change set: many changes, one issue, one pull request or commit | Accepted | 2026-10-03 |
| [D34](0034-the-apply-workflow-trusts-collaborator-association-and.md) | The apply workflow trusts collaborator association and nothing else | Accepted | 2026-10-03 |
| [D35](0035-site-is-a-customizable-file-class-overwritten-only-when.md) | `site/**` is a customizable file class: overwritten only when unchanged locally | Accepted | 2026-10-03 |
| [D36](0036-the-public-site-omits-the-organization-s-free-text.md) | The public site omits the organization's free-text justifications by default | Accepted | 2026-10-03 |
| [D37](0037-justification-is-optional-in-every-change-path.md) | Justification is optional in every change path | Accepted | 2026-10-03 |
| [D38](0038-release-notes-are-generated-from-pull-request-labels.md) | Release notes are generated from pull request labels | Accepted | 2026-10-03 |
| [D39](0039-test-framework-is-pester-6.md) | Test framework is Pester 6 | Accepted | 2026-10-03 |
| [D40](0040-justification-is-optional-in-level-and-stage-files-too.md) | Justification is optional in level and stage files too | Accepted | 2026-10-04 |
| [D41](0041-quarantine-wins-over-a-stage-entry-for-an-unmentioned-id.md) | Quarantine wins over a stage entry for an id no level file mentions | Accepted | 2026-10-05 |
| [D42](0042-publish-is-a-gate-and-never-commits.md) | Publish is a gate and never commits | Accepted | 2026-10-06 |
| [D43](0043-rulebook-json-is-published-from-wp06-with-levels-and-stages.md) | `rulebook.json` is published from WP06 with the levels and stages | Accepted | 2026-10-06 |
| [D44](0044-the-write-token-secret-is-ghtokenworkflow-in-al-go-format.md) | The write token secret is `GHTOKENWORKFLOW` in the AL-Go format | Accepted | 2026-10-07 |
| [D45](0045-the-scan-keeps-one-living-pull-request-and-records-every-package-version.md) | The scan keeps one living pull request and records every package version | Accepted | 2026-10-07 |
| [D46](0046-seeded-catalog-ids-are-known-unadvertised-deprecated-and-vanished-ids-are-catalog-flags.md) | Seeded catalog ids are known; unadvertised, deprecated and vanished ids are catalog flags | Accepted | 2026-10-07 |

## Open decisions

| # | Question | Recommendation | Tracked in |
|---|---|---|---|
| O3 | How template workflows reference the engine: `@main` in the engine's `template/` source and `@v1` pinned by the deploy step (AL-Go style), or git tags? | Branch `v1` pinned by deploy, tags as convenience. Branches can receive fixes without touching every org repo. | [#27](https://github.com/ALCops/rulebook-engine/issues/27) |

Closed: O1 and O2 by D19 (and D17), O4 by D44 ([#28](https://github.com/ALCops/rulebook-engine/issues/28)), O5 moot since D21, O6 by D28 (one skeleton file per stage).

## References

- Requirements interview and plan of 2026-09-29 (summarised in [ARCHITECTURE.md](../ARCHITECTURE.md) section 1).
- Interview of 2026-10-01 (target removal, sparse endpoints, twins, default drift): D21 to D24.
- Second interview of 2026-10-01 (no `L0`, configurable levels and stages, delta sources, slugs, rewritten dropdowns): D25 to D30.
- Interview of 2026-10-03 (dashboard on the published site, issue-form write path, change sets, collaborator gate, customizable site files, exposure, optional justification): D31 to D37. Design in [dashboard.md](../dashboard.md).
- Bootstrap interview of 2026-10-03 for WP00 ([#2](https://github.com/ALCops/rulebook-engine/issues/2)): generated release notes and Pester 6, D38 and D39.
- WP03 planning interview of 2026-10-05 ([#5](https://github.com/ALCops/rulebook-engine/issues/5), [#42](https://github.com/ALCops/rulebook-engine/issues/42)): D41.
- WP05 planning interview of 2026-10-06 ([#7](https://github.com/ALCops/rulebook-engine/issues/7)): D42.
- WP06 planning interview of 2026-10-06 ([#8](https://github.com/ALCops/rulebook-engine/issues/8)): D43.
- WP07 planning interview of 2026-10-07 ([#9](https://github.com/ALCops/rulebook-engine/issues/9), [#28](https://github.com/ALCops/rulebook-engine/issues/28)): D44.
- [reference/compiler-ruleset-internals.md](../reference/compiler-ruleset-internals.md): the merge rules behind D6, D13, D16 and their supersession by D18; the `suppressWarnings` merge behind D22.
- [reference/al-go-template-mechanics.md](../reference/al-go-template-mechanics.md): the update mechanism behind D2, D3, O3 and D44.
- Work package issues: where each decision is implemented, see the `Affects` field and the [work package list](https://github.com/ALCops/rulebook-engine/issues?q=is%3Aissue+label%3Aworkpackage).

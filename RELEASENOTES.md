# Release notes

## v1.0.0-beta.8

- Documentation strategy (D58): alcops.dev is to become the canonical home of the user documentation, the published site will explain itself and link there, and an organization's `docs/` will keep a README and its own text; nothing moves yet: `docs/` ships every page as today, the README says where the pages are going, and every link keeps opening them on GitHub ([#145](https://github.com/ALCops/rulebook-engine/pull/145))
- Site shell decision (D59): the redesigned site will be built on its own CSS and a small script, without a vendored Hugo theme; a spike that built the shell twice, on own CSS and on Hextra, is recorded with its screenshots; nothing changes in `site/` yet ([#146](https://github.com/ALCops/rulebook-engine/pull/146))
- Site shell: the dashboard gets the ALCops logo, a header with labelled Stage and Level links, dark mode that follows the system with a toggle, a menu on narrow screens, a matrix that scrolls with a sticky header row and rule column, action chips, a favicon, a title, description and Open Graph tags on every page, a footer with the publish time, the engine ref and the links, and one Tab stop per grid with arrow-key navigation; `rulebook.json` gains the `docs` map; `site/` changes, so an organization that edited a site file finds it under "Skipped: local changes" of the update ([#147](https://github.com/ALCops/rulebook-engine/pull/147))
- Landing page: `<baseUrl>/` says what the site is (the text of `site/content/_index.md`, which an organization edits), shows the facts of the rulebook, three steps to a ruleset in an AL project and a card per stage and level; the grid of the first stage moves to `<baseUrl>/stages/<slug>/` and every other address stays; an old `<baseUrl>/#...` filter bookmark opens the landing page; Publish checks the matrix marker on the first stage page and its warning names that page ([#148](https://github.com/ALCops/rulebook-engine/pull/148))
- Cart drawer: the cart slides in over the page as a dialog with a close button; Escape, the close button or a click beside it closes it, the **Cart** button opens it again with its changes, and the keyboard focus stays inside while it is open and returns to the **Cart** button; the justification of a change and the note take several lines and grow as you type, and their line breaks arrive in the issue unchanged; full width on a narrow screen; `site/` changes, so an organization that edited a site file finds it under "Skipped: local changes" of the update ([#149](https://github.com/ALCops/rulebook-engine/pull/149))
- Setup page: one block per level, the first open, with the two commands of the init script for that level and the `al.ruleSetPath` and `rulesetFile` lines; a **Copy** button beside every command, path and URL (one for both commands), which says "Copied" for two seconds, and every skeleton a download button that saves it under its skeleton name; without JavaScript the buttons are hidden and the text stays selectable; `site/` changes, so an organization that edited a site file finds it under "Skipped: local changes" of the update ([#150](https://github.com/ALCops/rulebook-engine/pull/150))
- In-context help: a **How this works** page at `<baseUrl>/how-it-works/` explains levels, stages, the cells and their markers and the cart in one screen, each paragraph linking the documentation page that goes deeper; the header **Help** link, the landing page and the legend open it; every page title has a sentence that says what the page shows; the legend markers show a tooltip on hover and keyboard focus; a **?** after the section headings of the stage, level, rule and setup pages opens the matching documentation; every documentation link comes from the `docs` map of `rulebook.json`; `site/` changes, so an organization that edited a site file finds it under "Skipped: local changes" of the update ([#151](https://github.com/ALCops/rulebook-engine/pull/151))

## v1.0.0-beta.7

- Publish: an empty `baseUrl` takes the address of the Pages site when the action deploys (a set `baseUrl` overrides it; a dry run still fails with the proposal), and a private Pages site (Enterprise Managed Users) ends the run green with a warning, the output `private` and no reachability check (D57) ([#135](https://github.com/ALCops/rulebook-engine/pull/135))

## v1.0.0-beta.6

- Validate passes again on pwsh 7.6.7 (`ubuntu-latest` since 2026-10-19): the schema checks run through JsonSchema.Net inside pwsh instead of `Test-Json`, which from 7.6.7 refuses the schemas' sibling `$ref` and names no nested error; a schema finding (C1, C5, C10, C14) now names the first error with its JSON pointer, and a property name repeated in one object is a finding instead of a crash (D56) ([#126](https://github.com/ALCops/rulebook-engine/pull/126))
- Apply Rulebook Change: an invalid change set is answered with one line per schema error and its JSON pointer; the shape hint line is gone ([#126](https://github.com/ALCops/rulebook-engine/pull/126))
- This release changes only the engine: the update pull request of an organization carries only the release notes copy ([#127](https://github.com/ALCops/rulebook-engine/pull/127))

## v1.0.0-beta.5

- Change sets: release from quarantine, change set version 1, the rulebook-change issue body reader with the schema check, and the GitHub issue helpers of the issue path ([#116](https://github.com/ALCops/rulebook-engine/pull/116))
- Quarantine files are read with System.Text.Json: a justification that looks like a date stays text, and keys match case-sensitively, so `"Rules"` or `"Id"` is no longer accepted (the schema is case-sensitive) ([#116](https://github.com/ALCops/rulebook-engine/pull/116))
- Apply Rulebook Change: the new workflow applies the change set of a rulebook-change issue from the dashboard as one pull request or direct commit, when the issue author, and the editor of a body edit, can push to the repository (D55), and answers on the issue ([#117](https://github.com/ALCops/rulebook-engine/pull/117))
- ApplyChangeSet action: the push-permission gate, the label created when missing, the duplicate guard, a red run with one comment line per error, `Nothing to change.` for a no-op, and the title `<change> (#<issue>)` with `Closes #<issue>` ([#117](https://github.com/ALCops/rulebook-engine/pull/117))
- User documentation: the dashboard and changing-a-rule pages describe the Apply Rulebook Change workflow and every answer it gives on the issue, the label is no longer created by hand, and the issue form and the site legend say the workflow applies a change set when its author may push ([#118](https://github.com/ALCops/rulebook-engine/pull/118))
- After the live run of 2026-10-18: a run does not repeat a comment that is already the latest comment of a bot on the issue (a title-only edit through the REST API runs the job), an edit that leaves the body as it was is skipped, the change numbers of the validation messages count from 1 (`change 1` is the first change), and a change set of several changes no longer opens with `No justification given.`; the issue body fixture is the body GitHub wrote in that run ([#125](https://github.com/ALCops/rulebook-engine/pull/125))

## v1.0.0-beta.4

- Dashboard data: rulebook.json gets every rule with its cells, the deciding input and the fallback of override and quarantine cells, the level and stage page models, the change set schema and the issue form ([#110](https://github.com/ALCops/rulebook-engine/pull/110))
- Dashboard site: Publish builds the matrix with one page per stage, level and rule, the cart opens the rulebook-change issue form, and catalog/diagnostics.json is published ([#111](https://github.com/ALCops/rulebook-engine/pull/111))
- Dashboard documentation: docs/dashboard.md, the dashboard route in changing-a-rule.md, and the setup page and published data files on the hosting and consumer pages ([#112](https://github.com/ALCops/rulebook-engine/pull/112))

## v1.0.0-beta.3

- Update: templateUrl accepts a tag, the pin of a release ([#108](https://github.com/ALCops/rulebook-engine/pull/108))
- Release model: template main is the release, preview the bleeding edge, tags the pin, deprecations instead of majors (D53) ([#109](https://github.com/ALCops/rulebook-engine/pull/109))
- A repository created from the template's former `v1` branch: set `templateUrl` in `.github/Rulebook-Settings.json` to end in `@main` and run Update Rulebook System Files; `v1` of the template goes away ([#109](https://github.com/ALCops/rulebook-engine/pull/109))

## v1.0.0-beta.2

- Release notes: the deploy line names its pull request ([#102](https://github.com/ALCops/rulebook-engine/pull/102))
- Release: v1.0.0-beta.2, the second prerelease of the live check ([#103](https://github.com/ALCops/rulebook-engine/pull/103))

## v1.0.0-beta.1

- WP00: Repository bootstrap ([#32](https://github.com/ALCops/rulebook-engine/pull/32))
- Spike (c): alc runs on ubuntu-latest from the stable NuGet tool ([#3](https://github.com/ALCops/rulebook-engine/issues/3))
- Spike (b): analyzer ids are extracted by reflection in pwsh from tools/net10.0/any and lib/net10.0 ([#3](https://github.com/ALCops/rulebook-engine/issues/3))
- Spike (h): Hugo 0.167.0 builds the 628 rule pages from one content adapter in 0.2 s ([#3](https://github.com/ALCops/rulebook-engine/issues/3))
- Spike (d): Pages on GitHub Free serves only public repos, and needs the org's Pages creation privilege and a pre-enabled site ([#3](https://github.com/ALCops/rulebook-engine/issues/3))
- Spike (a): Pages and raw both pass the compiler, one fetch per compile, the skeleton's own rules win, and a failing include aborts alc ([#3](https://github.com/ALCops/rulebook-engine/issues/3))
- Spike (f): suppressWarnings removes analyzer errors a sparse endpoint does not list, and is a no-op for listed ids ([#3](https://github.com/ALCops/rulebook-engine/issues/3))
- Spike (g): GitHub rejects prefilled issue URLs from 8192 bytes; render: json textareas prefill intact ([#3](https://github.com/ALCops/rulebook-engine/issues/3))
- Spike (e): VS Code re-reads a remote ruleset only on an app.json save, an al.* setting change, Reload Window or reopen ([#3](https://github.com/ALCops/rulebook-engine/issues/3))
- WP02: JSON schemas and naming reference for the organization rulebook layout ([#44](https://github.com/ALCops/rulebook-engine/pull/44))
- WP03 part 1: Rulebook.Generate, D41 precedence, sparse endpoints and the effective diff ([#45](https://github.com/ALCops/rulebook-engine/pull/45))
- WP03 part 2: Rulebook.Validate and the Validate action with checks C1 to C15, annotations and the effective diff on every pull request ([#46](https://github.com/ALCops/rulebook-engine/pull/46))
- tools/rulebook: shared sort key from Rulebook.Generate, portable paths, sorted twin pairs and the matrix checks in CI ([#53](https://github.com/ALCops/rulebook-engine/pull/53))
- WP04: template content, Rulebook.Template generators and the organization README ([#54](https://github.com/ALCops/rulebook-engine/pull/54))
- WP05: Publish action for GitHub Pages, reachability check and the template Publish workflow ([#59](https://github.com/ALCops/rulebook-engine/pull/59))
- WP06: AL project skeletons, the init script, rulebook.json and the C11 README exemption ([#60](https://github.com/ALCops/rulebook-engine/pull/60))
- Update Rulebook System Files: CheckForUpdates action, update workflow, GHTOKENWORKFLOW (D44), unusedRulebookFiles as paths ([#66](https://github.com/ALCops/rulebook-engine/pull/66))
- Validate: C16 reports a quarantine file that names no stage of the settings ([#68](https://github.com/ALCops/rulebook-engine/pull/68))
- Scan Diagnostics: daily NuGet scan with quarantine, catalog defaults and one living pull request ([#69](https://github.com/ALCops/rulebook-engine/pull/69))
- Share the action helpers in a Rulebook.Action module ([#73](https://github.com/ALCops/rulebook-engine/pull/73))
- Validate: update.check in the settings turns the template update check off ([#74](https://github.com/ALCops/rulebook-engine/pull/74))
- WP09: ChangeRule workflow, Rulebook.Edit change-set engine and the ChangeRule action ([#76](https://github.com/ALCops/rulebook-engine/pull/76))
- Update: the job summary renders the effective diff tables instead of System.String[] ([#79](https://github.com/ALCops/rulebook-engine/pull/79))
- WP10: Rulebook.Levels, the off-level script, generated level pages and the authoring guide ([#80](https://github.com/ALCops/rulebook-engine/pull/80))
- Update: docs/ is a customizable file class and the installed template commit is recovered from the initial commit ([#85](https://github.com/ALCops/rulebook-engine/pull/85))
- Tests: the user-docs troubleshooting rule is on and only migration.md is pending ([#86](https://github.com/ALCops/rulebook-engine/pull/86))
- Tests: every user page is checked now that the WP11 pages are merged ([#89](https://github.com/ALCops/rulebook-engine/pull/89))
- Modules and actions: one Rulebook.Common, C12 without What if lines, the refused push as a warning annotation, name-only binding ([#90](https://github.com/ALCops/rulebook-engine/pull/90))
- CI: coverage as a report (D51), the test summary step and one fixture guard suite ([#91](https://github.com/ALCops/rulebook-engine/pull/91))
- Tests: the coverage pass, docs/reference/testing.md and the WP12 close-out ([#94](https://github.com/ALCops/rulebook-engine/pull/94))
- Release model: D52, the engine ref helper and RELEASENOTES.md ([#99](https://github.com/ALCops/rulebook-engine/pull/99))
- Docs: the user documentation ships in template/docs/ and Docs.Tests checks it from the checkout ([#100](https://github.com/ALCops/rulebook-engine/pull/100))
- Deploy: the release pipeline, RELEASENOTES.copy.md and the refresh of rulebook@main ([#101](https://github.com/ALCops/rulebook-engine/pull/101))

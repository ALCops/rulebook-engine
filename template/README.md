# Rulebook

This repository is your organization's rulebook: one place that decides which diagnostics of the AL compiler, the Microsoft code cops and the ALCops analyzers your AL projects report, and at which severity. It publishes one flat ruleset per level and stage (for example `strict.ci`). Every AL project includes the endpoint it needs through a small skeleton file, so a change here reaches all projects on their next build without editing them.

The rulebook ships four levels (`Essential`, `Recommended`, `Strict`, `Complete`) and three stages (`default` for the editor, `CI` for pull request and release builds, `vNext` for builds against the next platform). The engine behind it is [ALCops/rulebook-engine](https://github.com/ALCops/rulebook-engine).

## Layout

| Path | Content | Class | Written by |
|---|---|---|---|
| `.github/Rulebook-Settings.json` | Base URL, publish target, quarantine policy, twins setting, the levels and stages. | settings | you |
| `.github/workflows/` | The rulebook workflows. `Validate.yaml` checks every pull request and push; `Publish.yaml` publishes the endpoints when a push to `main` changes them, the skeletons or the settings; the update, scan and change workflows arrive with a later version of the template. | system | the update workflow (later version) |
| `base/<level>.ruleset.json` | The level content: `essential` lists the ids that differ from the analyzer defaults, every other level the ids that differ from the level it is based on. | system | the update workflow (later version) |
| `base/twins.json` | The PerTenantExtensionCop and AppSourceCop rules that check the same thing. | system | the update workflow (later version) |
| `stages/<stage>.json` | What the `ci` and `vnext` stages change on top of every level. | system | the update workflow (later version) |
| `overrides.json` | Your organization's rule changes, scoped to levels and stages. | org-owned | you, or the change workflow (later version) |
| `quarantine.<stage>.json` | New diagnostic ids held at `None` per stage until you adopt them. | org-owned | the scan workflow (later version) |
| `catalog/diagnostics.json` | Every known diagnostic id with its analyzer default. | org-owned | the scan workflow (later version) |
| `rulesets/` | The published endpoints: one flat file per level and stage, listing only the ids whose action differs from the analyzer default. | generated | every workflow that changes an input; never edit by hand |
| `skeletons/` | One file per level and stage to copy into an AL project. | system | the update workflow (later version) |
| `README.md` | This file. | yours | you |

System files are replaced when you update from the template; settings are kept; org-owned files are yours and are never overwritten; generated files are rebuilt from the others.

## First steps

1. Make sure GitHub Pages can serve this repository: on GitHub Free the repository must be **public**, and an organization owner must allow *Pages creation* under Organization settings > Member privileges.
2. Enable Pages once: Settings > Pages > Build and deployment > Source **GitHub Actions**. The Publish workflow never creates the site itself.
3. In `.github/Rulebook-Settings.json`, set `baseUrl` to the site address, `https://`, all lowercase, no trailing slash: `https://<owner>.github.io/<repository>` (for example `https://contoso.github.io/rulebook`), or your custom domain. `publish.target` stays `pages`; the other targets are planned.
4. Set `quarantine.stages` and `quarantine.prereleaseStages` to the stages that hold back new diagnostic ids (for example `["ci"]`), or to `[]` to adopt new ids right away. The scan does not run until both are set.
5. Merge the settings change into `main` (a pull request lets Validate check it first). The Publish workflow runs on every push to `main` that changes `rulesets/`, `skeletons/`, the settings or the workflow itself, and by hand under Actions > Publish: it validates the rulebook, publishes `rulesets/`, the skeletons with your `baseUrl` filled in and an index page to `baseUrl`, and then checks that every URL serves the committed file. It never commits: when `rulesets/` is out of date it stops and tells you to regenerate it in a pull request.

After the first run, `baseUrl` opens a page that lists every endpoint and skeleton. If Publish fails before deploying, its message says what to change (Pages not enabled, `baseUrl` empty, endpoints out of date).

## Using a skeleton in an AL project

Copy the skeleton for your level, one per stage, into the project as `.rulebook/<stage>.ruleset.json`, for example `skeletons/strict.ci.ruleset.json` as `.rulebook/ci.ruleset.json`. Point `al.ruleSetPath` (VS Code) at `.rulebook/default.ruleset.json` and the AL-Go `rulesetFile` at `.rulebook/ci.ruleset.json`. Download the skeleton from the published site (`<baseUrl>/skeletons/strict.ci.ruleset.json`, linked from the index page): the published copy carries your `baseUrl`. The skeletons in this repository keep the placeholder `{BASEURL}`, so an update from the template never conflicts with your URL. Project exceptions go into the skeleton's `rules`; they override the endpoint.

## Changing a rule

Never edit `rulesets/`: it is regenerated from the other files, and the Validate workflow fails when it is out of date. Change a rule for your organization with an entry in `overrides.json` (an id, an action, the levels and stages it applies to and an optional justification), then let the workflows regenerate the endpoints.

## Documentation

- `docs/getting-started.md`
- `docs/hosting.md`
- `docs/al-go.md`
- `docs/azure-devops.md`
- `docs/vscode.md`
- `docs/al-project.md`
- `docs/pte-or-appsource.md`
- `docs/overrides.md`
- `docs/quarantine.md`
- `docs/updating.md`

These pages, and the workflows other than Validate and Publish, arrive with a later version of the template. Questions and issues: [ALCops/rulebook-engine](https://github.com/ALCops/rulebook-engine/issues).

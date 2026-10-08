# Rulebook

This repository is your organization's rulebook: one place that decides which diagnostics of the AL compiler, the Microsoft code cops and the ALCops analyzers your AL projects report, and at which severity. It publishes one flat ruleset per level and stage (for example `strict.ci`). Every AL project includes the endpoint it needs through a small skeleton file, so a change here reaches all projects on their next build without editing them.

The rulebook ships four levels (`Essential`, `Recommended`, `Strict`, `Complete`) and three stages (`default` for the editor, `CI` for pull request and release builds, `vNext` for builds against the next platform). The engine behind it is [ALCops/rulebook-engine](https://github.com/ALCops/rulebook-engine).

## Layout

| Path | Content | Class | Written by |
|---|---|---|---|
| `.github/Rulebook-Settings.json` | Base URL, publish target, quarantine policy, twins setting, the levels and stages. | settings | you |
| `.github/workflows/` | The rulebook workflows. `Validate.yaml` checks every pull request and push; `Publish.yaml` publishes the endpoints when a push to `main` changes them, the skeletons or the settings; `UpdateRulebookSystemFiles.yaml` pulls a new template version into a pull request (by hand, or on the schedule in `update.schedule`); `ScanDiagnostics.yaml` scans the compiler and ALCops packages every day (`scan.schedule`) and keeps one pull request with the new diagnostic ids, quarantined by your policy; the change workflows arrive with a later version of the template. | system | the update workflow |
| `base/<level>.ruleset.json` | The level content: `essential` lists the ids that differ from the analyzer defaults, every other level the ids that differ from the level it is based on. | system | the update workflow |
| `base/twins.json` | The PerTenantExtensionCop and AppSourceCop rules that check the same thing. | system | the update workflow |
| `stages/<stage>.json` | What the `ci` and `vnext` stages change on top of every level. | system | the update workflow |
| `overrides.json` | Your organization's rule changes, scoped to levels and stages. | org-owned | you, or the change workflow (later version) |
| `quarantine.<stage>.json` | New diagnostic ids held at `None` per stage until you adopt them; mentioning an id in a level file adopts it, and the next scan removes the entry. | org-owned | the scan workflow |
| `catalog/diagnostics.json`, `catalog/scan-state.json` | Every known diagnostic id with its analyzer default, the package versions that carry it and its docs link; the package versions the scan read last (created by the first scan). | org-owned | the scan workflow |
| `rulesets/` | The published endpoints: one flat file per level and stage, listing only the ids whose action differs from the analyzer default. | generated | every workflow that changes an input; never edit by hand |
| `skeletons/` | One file per level and stage to copy into an AL project, and a README that explains them (not published). | generated (the README is system) | the update workflow, from your levels and stages |
| `README.md` | This file. | yours | you |

System files are replaced when you update from the template; settings are kept; org-owned files are yours and are never overwritten; generated files are rebuilt from the others.

## Updating

The workflow **Update Rulebook System Files** (Actions > Update Rulebook System Files > Run workflow) pulls the newest version of the template into a pull request: the system files, your settings with the new `templateSha`, and `rulesets/` and `skeletons/` regenerated under your overrides and quarantine, with the effective change of every endpoint in the pull request. Your own files are never touched. It needs a secret `GHTOKENWORKFLOW` (a GitHub App or a personal access token, the same secret AL-Go uses), because the workflow token cannot change workflow files. Every Validate run also tells you when an update is available (set `"update": { "check": false }` in `.github/Rulebook-Settings.json` to turn that off); when the template cannot be read with the workflow token (a private template, or a pull request from a fork) it says "update check skipped" instead. How it works: [docs/updating.md](https://github.com/ALCops/rulebook/blob/main/docs/updating.md); the secret: [docs/ghtokenworkflow.md](https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md).

## First steps

1. Make sure GitHub Pages can serve this repository: on GitHub Free the repository must be **public**, and an organization owner must allow *Pages creation* under Organization settings > Member privileges.
2. Enable Pages once: Settings > Pages > Build and deployment > Source **GitHub Actions**. The Publish workflow never creates the site itself.
3. In `.github/Rulebook-Settings.json`, set `baseUrl` to the site address, `https://`, all lowercase, no trailing slash: `https://<owner>.github.io/<repository>` (for example `https://contoso.github.io/rulebook`), or your custom domain. `publish.target` stays `pages`; the other targets are planned.
4. Set `quarantine.stages` (ids new in a stable package) and `quarantine.prereleaseStages` (ids new in a prerelease) to the stages that hold back new diagnostic ids, for example `["default", "ci"]` for both so that only `vnext` shows new rules at their default severity, or to `[]` to adopt new ids right away. The Scan Diagnostics workflow stops with a message until both are set; it uses the same `GHTOKENWORKFLOW` secret as the update. How the scan works: [docs/quarantine.md](https://github.com/ALCops/rulebook/blob/main/docs/quarantine.md).
5. Merge the settings change into `main` (a pull request lets Validate check it first). The Publish workflow runs on every push to `main` that changes `rulesets/`, `skeletons/`, the settings or the workflow itself, and by hand under Actions > Publish: it validates the rulebook, publishes `rulesets/`, the skeletons with your `baseUrl` filled in and an index page to `baseUrl`, and then checks that every URL serves the committed file. It never commits: when `rulesets/` is out of date it stops and tells you to regenerate it in a pull request.

After the first run, `baseUrl` opens a page that lists every endpoint and skeleton. If Publish fails before deploying, its message says what to change (Pages not enabled, `baseUrl` empty, endpoints out of date).

## Using a skeleton in an AL project

Copy the skeleton for your level, one per stage, into the project as `.rulebook/<stage>.ruleset.json`, for example `skeletons/strict.ci.ruleset.json` as `.rulebook/ci.ruleset.json`. Point `al.ruleSetPath` (VS Code) at `.rulebook/default.ruleset.json` and the AL-Go `rulesetFile` at `.rulebook/ci.ruleset.json`. Download the skeleton from the published site (`<baseUrl>/skeletons/strict.ci.ruleset.json`, linked from the index page): the published copy carries your `baseUrl`. The skeletons in this repository keep the placeholder `{BASEURL}`, so an update from the template never conflicts with your URL. Project exceptions go into the skeleton's `rules`; they override the endpoint.

The init script does the download for you: it reads the levels and stages from `<baseUrl>/rulebook.json` and writes one file per stage into `.rulebook/` of the current folder (PowerShell 7):

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/ALCops/rulebook-engine/main/scripts/Get-RulebookSkeletons.ps1 -OutFile Get-RulebookSkeletons.ps1
./Get-RulebookSkeletons.ps1 -BaseUrl https://contoso.github.io/rulebook -Level strict
```

Why one file per stage, the settings per consumer and when `suppressWarnings` in `app.json` works instead of an exception: the user page `docs/al-project.md` in the ALCops/rulebook repository (written with WP06).

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

Updating the rulebook: [docs/updating.md](https://github.com/ALCops/rulebook/blob/main/docs/updating.md). The token the update writes with: [docs/ghtokenworkflow.md](https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md).

The pages in the list above, and the workflows other than Validate, Publish and Update Rulebook System Files, arrive with a later version of the template. Questions and issues: [ALCops/rulebook-engine](https://github.com/ALCops/rulebook-engine/issues).

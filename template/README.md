# Rulebook

This repository is your organization's rulebook: one place that decides which diagnostics of the AL compiler, the Microsoft code cops and the ALCops analyzers your AL projects report, and at which severity. It publishes one flat ruleset per level and stage (for example `strict.ci`). Every AL project includes the endpoint it needs through a small skeleton file, so a change here reaches all projects on their next build without editing them.

The rulebook ships four levels (`Essential`, `Recommended`, `Strict`, `Complete`) and three stages (`default` for the editor, `CI` for pull request and release builds, `vNext` for builds against the next platform). The engine behind it is [ALCops/rulebook-engine](https://github.com/ALCops/rulebook-engine).

## Layout

| Path | Content | Class | Written by |
|---|---|---|---|
| `.github/Rulebook-Settings.json` | Base URL, publish target, quarantine policy, twins setting, the levels and stages. | settings | you |
| `.github/workflows/` | The rulebook workflows. `Validate.yaml` checks every pull request and push. | system | the update workflow |
| `base/<level>.ruleset.json` | The level content: `essential` lists the ids that differ from the analyzer defaults, every other level the ids that differ from the level it is based on. | system | the update workflow |
| `base/twins.json` | The PerTenantExtensionCop and AppSourceCop rules that check the same thing. | system | the update workflow |
| `stages/<stage>.json` | What the `ci` and `vnext` stages change on top of every level. | system | the update workflow |
| `overrides.json` | Your organization's rule changes, scoped to levels and stages. | org-owned | you, or the change workflow |
| `quarantine.<stage>.json` | New diagnostic ids held at `None` per stage until you adopt them. | org-owned | the scan workflow |
| `catalog/diagnostics.json` | Every known diagnostic id with its analyzer default. | org-owned | the scan workflow |
| `rulesets/` | The published endpoints: one flat file per level and stage, listing only the ids whose action differs from the analyzer default. | generated | every workflow that changes an input; never edit by hand |
| `skeletons/` | One file per level and stage to copy into an AL project. | system | the update workflow |
| `README.md` | This file. | yours | you |

System files are replaced when you update from the template; settings are kept; org-owned files are yours and are never overwritten; generated files are rebuilt from the others.

## First steps

1. In `.github/Rulebook-Settings.json`, set `baseUrl` to the address the rulesets are served from (`https://`, no trailing slash, for example `https://contoso.github.io/rulebook`) and choose the `publish` target.
2. Set `quarantine.stages` and `quarantine.prereleaseStages` to the stages that hold back new diagnostic ids (for example `["ci"]`), or to `[]` to adopt new ids right away. The scan does not run until both are set.
3. Run the Publish workflow. It validates the rulebook, regenerates `rulesets/` and publishes it to `baseUrl`.

## Using a skeleton in an AL project

Copy the skeleton for your level, one per stage, into the project as `.rulebook/<stage>.ruleset.json`, for example `skeletons/strict.ci.ruleset.json` as `.rulebook/ci.ruleset.json`. Point `al.ruleSetPath` (VS Code) at `.rulebook/default.ruleset.json` and the AL-Go `rulesetFile` at `.rulebook/ci.ruleset.json`. The `{BASEURL}` placeholder in the repository copy is replaced with your `baseUrl` in the published copy, so copy the skeleton from the published site, or replace the placeholder yourself. Project exceptions go into the skeleton's `rules`; they override the endpoint.

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

These pages, and the workflows other than Validate, arrive with a later version of the template. Questions and issues: [ALCops/rulebook-engine](https://github.com/ALCops/rulebook-engine/issues).

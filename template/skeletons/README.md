# Skeletons

One file per level and stage, `<level>.<stage>.ruleset.json`, the `default` stage included. Each skeleton is the root ruleset of an AL project: it includes one endpoint, `{BASEURL}/rulesets/<level>[.<stage>].ruleset.json`, and holds the project's own exceptions in `rules`. The files are generated from the levels and stages in `.github/Rulebook-Settings.json` (`New-RulebookSkeleton` in the engine) and are system files: the update workflow overwrites them, so do not edit them here.

## Do not copy from this folder

The copies here keep the placeholder `{BASEURL}`, which the compiler cannot fetch. The Publish workflow renders your `baseUrl` into the published copy, `<baseUrl>/skeletons/<level>.<stage>.ruleset.json`, and the index page at `<baseUrl>/` links every one of them.

## In an AL project

One file per stage in `.rulebook/`, named after the stage: `.rulebook/default.ruleset.json`, `.rulebook/ci.ruleset.json`, `.rulebook/vnext.ruleset.json`. The init script downloads the published skeletons of one level (PowerShell 7):

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/ALCops/rulebook-engine/main/scripts/Get-RulebookSkeletons.ps1 -OutFile Get-RulebookSkeletons.ps1
./Get-RulebookSkeletons.ps1 -BaseUrl https://contoso.github.io/rulebook -Level strict
```

Then point the consumers at the files:

- VS Code, `.vscode/settings.json`: `"al.ruleSetPath": ".rulebook/default.ruleset.json"`
- AL-Go, `.AL-Go/settings.json`: `"rulesetFile": ".rulebook/ci.ruleset.json"` with `"enableExternalRulesets": true`

## Exceptions

A project exception goes into `rules` of the file, with an `id`, an `action` and a `justification`; the file's own rules beat the endpoint it includes. Each stage has its own file, so an exception that applies to every stage is repeated in each. Why one file per stage, and when `suppressWarnings` in `app.json` works instead: [docs/al-project.md](https://github.com/ALCops/rulebook/blob/main/docs/al-project.md). Opting out of the other cop's rules (per-tenant extension or AppSource app): [docs/pte-or-appsource.md](https://github.com/ALCops/rulebook/blob/main/docs/pte-or-appsource.md).

This README is not published and is exempt from the file-name check C11.

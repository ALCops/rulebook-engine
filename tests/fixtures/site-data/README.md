# Site data fixture

`rulebook.json` is the site data export (`Export-RulebookSiteData`, [docs/dashboard.md](../../../docs/dashboard.md) section 5) of the repository fixture `tests/fixtures/repos/valid-minimal`: 30 ids, four levels, three stages, two overrides (`AA0072` everywhere, `LC0029` on `recommended.ci`) and `LC0099` quarantined in `default` and `ci`. `site.includeJustifications` is false in that fixture, so the overrides and the quarantine lists carry no justification.

`tests/Rulebook.Site.Tests.ps1` exports `valid-minimal` again and compares the bytes (the drift test). The Hugo build of the site and the cart tests of `tests/site/` read this file too (WP14, PR B).

Regenerate it after a change to the export or to `valid-minimal`, from the repository root, with the engine ref variables unset so `docsUrl` is built for the ref `main` (the `preview` user page):

```powershell
Remove-Item Env:GITHUB_ACTION_REF, Env:GITHUB_ACTION_PATH -ErrorAction SilentlyContinue
Import-Module ./modules/Rulebook.Site.psd1 -Force
Export-RulebookSiteData -RepositoryRoot tests/fixtures/repos/valid-minimal -BaseUrl https://contoso.github.io/rulebook -Repository contoso/rulebook -GeneratedAt 2026-10-17T00:00:00Z -OutFile tests/fixtures/site-data/rulebook.json
```

Read `generatedAt` as text: `ConvertFrom-Json` turns it into a `DateTime` ([#62](https://github.com/ALCops/rulebook-engine/issues/62)); on PowerShell 7.5 and later `ConvertFrom-Json -DateKind String` keeps the string.

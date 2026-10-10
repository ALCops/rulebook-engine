# Template fixtures

Two versions of a mini template and one organization repository created from it, for the update suites (WP07, [#9](https://github.com/ALCops/rulebook-engine/issues/9)): `tests/Rulebook.Update.Tests.ps1`, `tests/CheckForUpdates.Action.Tests.ps1`, `tests/Validate.Action.Tests.ps1` and the `update-action` job in `.github/workflows/ci.yml`. Mechanics: [docs/reference/update-mechanics.md](../../../docs/reference/update-mechanics.md).

Every `rulesets/` folder is written by `Update-RulebookEndpoints` and every `skeletons/*.ruleset.json` by `New-RulebookSkeleton`, never by hand; the template cases of `tests/Fixtures.Tests.ps1` run `Test-Rulebook` on all three folders, regenerate their generated folders and compare the v1 -> v2 differences with the table below.

## v1

A mini template on the 30-id catalog of `tests/fixtures/repos/valid-minimal`:

- From `valid-minimal`: `base/essential`, `recommended`, `strict`, `complete` `.ruleset.json`, `base/twins.json`, `stages/ci.json`, `stages/vnext.json`, `catalog/diagnostics.json`.
- From `template/`: `overrides.json` and the three quarantine files (empty), `.github/workflows/Validate.yaml`, `Publish.yaml` and `UpdateRulebookSystemFiles.yaml` (with `{TEMPLATEURL}`, no `schedule:`).
- Written for the fixture: `.github/Rulebook-Settings.json` (the levels and stages of `valid-minimal`, `templateUrl` `https://github.com/Contoso/rulebook-template@main`, `templateSha` `""`, `baseUrl` `""`, `update.schedule` `null`, `unusedRulebookFiles` `[]`), `.github/workflows/ChangeRule.yaml` (choice inputs `levels` and `stages` listing `'*'` and the four level and three stage slugs), `.github/workflows/Legacy.yaml`, `.github/RELEASENOTES.copy.md` (`## v1.0`), `README.md`, `skeletons/README.md`, `site/config.yaml`, `site/layouts/index.html`, `rule.html`, `legacy.html`, `site/static/style.css` and `site/static/logo.png` (a 1x1 PNG, the binary case), and the organization documentation `docs/README.md`, `docs/getting-started.md` and `docs/images/logo.png` (the same PNG; customizable since D50).
- Generated: `skeletons/` (12) with `New-RulebookSkeleton -SettingsPath .github/Rulebook-Settings.json -OutputPath skeletons`, then `rulesets/` (12) with `Update-RulebookEndpoints -RepositoryRoot v1`.

## v2

A copy of v1 with exactly these differences (then `rulesets/` regenerated with `Update-RulebookEndpoints`):

| Path | Difference |
|---|---|
| `.github/RELEASENOTES.copy.md` | `## v1.1` with two lines added above `## v1.0` |
| `.github/workflows/ChangeRule.yaml` | a comment line above the `levels` input |
| `.github/workflows/Legacy.yaml` | removed |
| `base/recommended.ruleset.json` | `AL0200` Warning -> Error (the id `update-org` overrides), `AC0001` Warning -> Error |
| `docs/getting-started.md` | changed (a step added) |
| `docs/images/badge.png` | added (a 1x1 PNG with other bytes than `logo.png`) |
| `rulesets/complete.ci.ruleset.json` | regenerated |
| `rulesets/complete.ruleset.json` | regenerated |
| `rulesets/complete.vnext.ruleset.json` | regenerated |
| `rulesets/recommended.ci.ruleset.json` | regenerated |
| `rulesets/recommended.ruleset.json` | regenerated |
| `rulesets/recommended.vnext.ruleset.json` | regenerated |
| `rulesets/strict.ci.ruleset.json` | regenerated |
| `rulesets/strict.ruleset.json` | regenerated |
| `rulesets/strict.vnext.ruleset.json` | regenerated |
| `site/layouts/footer.html` | added |
| `site/layouts/index.html` | changed |
| `site/layouts/legacy.html` | removed |
| `site/layouts/rule.html` | changed |
| `skeletons/README.md` | changed |
| `stages/ci.json` | `AL0432` Info -> Hidden (Essential sets AL0432 to None, so `essential.ci` does not move) |

Everything else, `site/static/style.css`, `docs/README.md` and `docs/images/logo.png` included, is byte-identical. The `essential.*` endpoints do not change: no v2 change reaches the Essential level.

## repos/update-org

A complete fixture (listed in `$complete` of `tests/Helpers/RepoFixture.ps1`): the repository an organization has after creating it from v1, making its own changes and running the update once. Derivation:

1. A copy of v1.
2. The organization's changes: `.github/Rulebook-Settings.json` with `baseUrl` `https://contoso.github.io/rulebook`, the level **House** (`basedOn` Recommended) between Recommended and Strict (Strict `basedOn` House), `update.schedule` `"0 6 * * 1"` and `unusedRulebookFiles` `[".github/workflows/Legacy.yaml", "site/layouts/legacy.html"]` (`commitOptions.pullRequestLabels` `["rulebook"]` , `site.updateMode` and `docs.updateMode` `"skip"` as shipped); `base/house.ruleset.json` (LC0001 Error, TA0001 Info); one override in `overrides.json` (`AL0200` Info for every level and stage, the id v2 changes in Recommended); one entry in `quarantine.ci.json` (`LC0099`); the organization workflow `.github/workflows/MyNightly.yaml`.
3. One update run: `Get-RulebookUpdatePlan` with `Get-RulebookTemplate -TemplatePath v1 -InstalledTemplatePath v1 -TemplateSha 0123456789abcdef0123456789abcdef01234567`, and its changes written. That sets `templateSha` to the fake sha, replaces `{TEMPLATEURL}` and adds `schedule:` (`0 6 * * 1`) in `UpdateRulebookSystemFiles.yaml`, adds `house` to the `levels` list of `ChangeRule.yaml`, deletes `Legacy.yaml` and `site/layouts/legacy.html` (listed in `unusedRulebookFiles`), and writes `rulesets/` (15) and `skeletons/` (15) for the five levels.
4. Local site edits after the update: `site/layouts/index.html` and `site/static/style.css` changed; `rule.html` stays the v1 file.
5. Local documentation edits (D50): `docs/README.md` (a help line; v2 leaves it alone, so the update keeps it) and `docs/getting-started.md` (a step added; v2 changes it too, so the update skips it) changed; `docs/images/logo.png` stays the v1 file.

So `update-org` against v1 (installed v1) differs only in `templateSha` (the local v1 has a content sha, not the fake one): the check reports "not recorded", no updates. Against v2 the expected change set is in the Update suite. The cases that need `Legacy.yaml` and `legacy.html` present (removal through `unusedRulebookFiles`, the notes without the entries) copy them back from v1 in TestDrive.

The variants without a folder (`templateSha` empty, `site.updateMode` overwrite, other `unusedRulebookFiles`, a v2 with an invalid action, a v2 with only `stages/ci.json` changed) are TestDrive mutations in the suites.

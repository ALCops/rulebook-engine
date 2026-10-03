# Source versions and refresh procedure

The inventory and matrix describe a specific version of every analyzer. This file records which one, and how to refresh when a new version ships.

## 1. Versions used

| Source | Version | Where it was read | Date |
|---|---|---|---|
| AL compiler and Microsoft cops (`AL`, `AA`, `AW`, `PTE`, `AS`) | NuGet `Microsoft.Dynamics.BusinessCentral.Development.Tools` `30.0.42.32495-beta` (prerelease), assembly `30.0.42.32495` | Sibling repo `../nav-sdk-source`, tag `v30.0.42.32495-prerelease`, commit `01e17eee`, folder `net10.0` (the `net8.0` copies are byte-identical) | 2026-09-29 |
| Latest stable compiler for the `Since` column | `18.0.41.62505`, tag `v18.0.41.62505` in the same repo | Same repo | 2026-09-29 |
| ALCops analyzers (`PC`, `AC`, `LC`, `DC`, `FC`, `TA`, `CM`) | `main` at commit `2f13e3e` (2026-09-28), 18 commits after tag `v1.3.1` | Sibling repo `../Analyzers` | 2026-09-29 |
| ALCops documentation | `alcops.dev` at commit `9534ab8` (2026-09-27) | Sibling repo `../alcops.dev` | 2026-09-29 |
| navcontainerhelper AppSource default ruleset | commit `83a731e`, `AppHandling/appsource.default.ruleset.json` | GitHub raw | 2026-09-29 |

The compiler tag `v30.0.42.32495-prerelease` and the stable tag `v18.0.41.62505` declare the same descriptor sets, so every id is `stable` today. The version jump from 18 to 30 is Microsoft's renumbering, not a content change.

## 2. Drift policy

- **Unknown ids are harmless.** The compiler ignores a ruleset entry whose id no analyzer reports. Listing an id that a customer's older analyzer does not know costs nothing, so the matrix always describes the newest known version.
- **Removed ids stay listed** until the next refresh confirms the removal in a stable release; then they are dropped from the inventory and the matrix in one commit that names the version.
- **New ids** are added by the refresh below and land in `Family = general` with the placement the decision rows give them, unless a `DR` in `decisions.md` says otherwise. At runtime, an organization's daily scan (WP08) writes a new id at `None` into the quarantined stages until a base file generated from this matrix mentions it; the matrix decides what that mention will be.
- **Changed defaults** (an analyzer author moves a rule from Warning to Info, or enables it by default) change the `Default` and `Enabled` columns and therefore the decision row. `Build-Matrix.ps1` recomputes the ladder; the diff of `matrix/*.md` is the review artifact.

## 3. Refresh procedure

1. Update the sibling repos: `git -C ../nav-sdk-source pull`, `git -C ../Analyzers pull`, `git -C ../alcops.dev pull`. Note the new tag or commit in the table above.
2. Run `pwsh tools/rulebook/Extract-Inventory.ps1 -StableTag <latest stable tag>`. It rewrites `inventory/*.md` and `inventory/inventory.json`, merging the hand-maintained `inventory/annotations.json` (families, config gates, twin and overlap flags).
3. Review new ids: `git diff --stat docs/rulebook/inventory`. For every new id decide the Family (and twin or overlap flags) in `annotations.json`, then run the extraction again.
4. Run `pwsh tools/rulebook/Build-Matrix.ps1`. It rewrites `matrix/*.md` and `matrix/resolved.json`.
5. Run `pwsh tools/rulebook/Test-Rulebook.ps1`. Every check in `verification.md` must pass.
6. Update the count tables in `README.md` (printed by `Build-Matrix.ps1`) and add a line to `decisions.md` for any override introduced.
7. Commit the inventory, matrix, annotations and this file together, with the version in the commit message.

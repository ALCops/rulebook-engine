# Verification

Checks that hold for the inventory, the matrix and the docs. `tools/rulebook/Test-Rulebook.ps1` implements every one of them and exits non-zero on the first failing check; run it after every rebuild. Each check is stated as a query over the tables so it can be re-implemented by another tool.

| # | Check | Query |
|---|---|---|
| V1 | Inventory files are complete and consistent. | For each `inventory/<PREFIX>.md`: data rows = `Count:` line = rows of that prefix in `inventory.json`. Ids unique across files and match `^(AL|AA|AW|PTE|AS|PC|AC|LC|DC|FC|TA|CM)[0-9]{4}i?$`. Per-prefix totals: AL 219, AA 93, AW 17, PTE 26, AS 143, PC 38, AC 35, LC 34, DC 11, FC 8, TA 3, CM 1; total 628. `inventory.json` is in strictly ascending `Get-DiagnosticSortKey` order (`modules/Rulebook.Generate`, compared ordinally), the order every generated file follows. |
| V2 | Matrix rows mirror inventory rows. | Same ids in the same order; every `matrix/<PREFIX>.md` has the ten columns of `00-conventions.md` and every cell equals `matrix.json`; every id has 12 cells in `resolved.json`, keyed `<level>.<stage>` (`essential.default` to `complete.vnext`). |
| V3 | Ladders are monotonic. | strictness(E) ≤ strictness(R) ≤ strictness(S) ≤ strictness(C). |
| V4 | Error is confined. | `Error` in a ladder only when `Family = runtime` or the id is a PerTenantExtensionCop or AppSourceCop rule with an Error default; in `vNext` only for `Family = future-error`. `Default` is always `=`. |
| V5 | Contradictions and LC0089i. | LC0089i resolves to `None` in all 12 cells. Every `contradicts:` flag has a row in `overlaps.md`, and the two sides are never both active in one cell. |
| V6 | Twins are declared and exported. | Every `twin:` flag on a PTE id names an AS id that carries the mirror flag; a PTE id has at most one twin; every pair appears in the twins table of `overlaps.md`; `matrix/twins.json` lists exactly these pairs with `values` = `both, appsource, pte`; both sides of a pair follow their native ladder unless an override row applies. |
| V7 | Native severity of the cop-specific sets. | `Family = marketplace` and AS0003, AS0091 are `None` in every `essential` cell and equal their native Recommended action at `recommended.default`; `Family = pte-only` follows its native ladder; every other PerTenantExtensionCop or AppSourceCop Error default is `Error` in all 12 cells unless an override row applies. |
| V8 | Every basis resolves. | Every `Basis` token appears as a row in `02-placement-algorithm.md`; every rule row names a `DR-nnn` that exists in `decisions.md` and is not marked Superseded; every non-superseded `DR-nnn` is referenced somewhere in `02-placement-algorithm.md`. |
| V9 | Justifications are well-formed. | 1 to 120 characters, no `|`, no line break, ending in `; <Basis>`. |
| V10 | Stages never activate. | If `<level>.default` is `None` then `<level>.ci` and `<level>.vnext` are `None` for that id. |
| V11 | Levels are cumulative. | For every stage and every id: an id active at a level is active at the next level of the shipped ladder, and strictness never decreases from a level to the next. Shipped set only; an organization repository does not enforce this (D26). |
| V12 | Fixed rule rows are deterministic. | Rows sharing a family or decision row with a fixed ladder have identical ladders. |
| V13 | Delta files compose to the matrix, endpoints are sparse. | Build the files of `composition.md` from the matrix rows: the root `base/essential.ruleset.json` (ids whose Essential action differs from the analyzer default, `Default` if `Enabled`, else `None`), the deltas `recommended`, `strict`, `complete` (ids whose action differs from the level below), and `stages/ci.json`, `stages/vnext.json` (ids whose `CI` or `vNext` column is not `=`). Compose per the resolution recipe (chain, then stage where the chain result is not `None`): the result equals `resolved.json` in all 12 cells of every id; no delta entry equals the value the chain already gives; each stage file holds exactly its non-`=` ids. Derive the 12 endpoints by dropping every id whose action equals the analyzer default: no endpoint entry equals the default, endpoint plus defaults reproduces the cell, LC0054 and LC0089i appear in no endpoint, no file has `includedRuleSets` or `generalAction`. |
| V14 | README counts are current. | `matrix/counts.md` has 12 count rows and every one appears verbatim in `README.md`. |

## Running

```powershell
pwsh tools/rulebook/Extract-Inventory.ps1   # inventory/*.md, inventory.json (merges annotations.json)
pwsh tools/rulebook/Build-Matrix.ps1        # matrix/*.md, matrix.json, resolved.json, twins.json, counts.md, 02-placement-algorithm.md
pwsh tools/rulebook/Test-Rulebook.ps1       # V1..V14
```

## After the generator exists

Three checks belong to the follow-up task that writes the `.ruleset.json` files and are not part of this folder:

- Regenerate every level file, stage file and endpoint from the matrix with `twins` at `both`, empty overrides and quarantine, and diff the endpoint `rules` arrays with `resolved.json` minus the defaults (the same comparison as V13, now on real files). Run the Rulebook validate action (WP03): schema, unique ids, every listed id in the catalog, no listed id at its default, no includes.
- Compile a sample AL project with `alc /ruleset:<endpoint URL> /enableexternalrulesets` on `recommended.ci` and confirm that exactly one HTTP request is made, that AL1033 is absent and that a known diagnostic (for example AL0432 on an obsolete-pending field) is reported at Info.
- Compile a per-tenant sample (`idRanges` 50000..99999) against `recommended.ci` with `"suppressWarnings": ["AS0084", "AS0013"]` in `app.json` and confirm that neither is reported, then against `essential.ci` with an override that lists AS0013 and confirm that `suppressWarnings` no longer removes it (route B works only for unlisted ids).

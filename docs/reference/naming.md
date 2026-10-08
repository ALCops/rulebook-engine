# Naming and file schemas of an organization rulebook repository

The file names, slugs, URLs and JSON schemas of an organization rulebook repository. Every work package that reads or writes these files (WP03 generate and validate, WP04 template content, WP07 update, WP08 scan, WP09 change rule, WP15 apply) follows this page.

> **Status:** binding since WP02 ([#4](https://github.com/ALCops/rulebook-engine/issues/4)). The names, the slug rule, the `default` suffix rule, the URL scheme and the schema files under [`schemas/`](../../schemas/) are fixed; a change is a pull request that changes this page, the schema and its fixtures together. The design behind them is [ARCHITECTURE.md](../ARCHITECTURE.md) sections 4, 5 and 8; the generator contract is [rulebook/composition.md](../rulebook/composition.md).

---

## Contents

1. [Slugs](#1-slugs)
2. [File names](#2-file-names)
3. [The `default` suffix rule](#3-the-default-suffix-rule)
4. [URL scheme and hosts](#4-url-scheme-and-hosts)
5. [Shipped endpoints and skeletons](#5-shipped-endpoints-and-skeletons)
6. [Schemas](#6-schemas)
7. [Examples](#7-examples)
8. [Reserved names](#8-reserved-names)

---

## 1. Slugs

A level or stage is identified by its `name` in `.github/Rulebook-Settings.json` (D28). The **slug** is that name lowercased and must match `^[a-z0-9-]+$`: letters, digits and hyphens, no spaces, no dots. The settings schema enforces the equivalent pattern `^[A-Za-z0-9-]+$` on every `name` and `basedOn` before lowercasing.

- Slugs are unique within `levels` and within `stages`, compared after lowercasing (C5; a schema cannot compare items case-insensitively).
- The slug is the only spelling in file names, URLs, override selectors, quarantine policy values and keys of generated JSON (`strict.ci`). The `name` keeps its casing in prose, in the file-level `name` property of generated files and on the index page.
- `basedOn` names a level file and is matched case-insensitively against the name: `"basedOn": "Essential"` is `base/essential.ruleset.json`.
- Shipped slugs: levels `essential`, `recommended`, `strict`, `complete`; stages `default`, `ci`, `vnext`.

## 2. File names

Paths in an organization rulebook repository. Class is what the update workflow does with the file ([ARCHITECTURE.md](../ARCHITECTURE.md) section 7.3); profile is the schema the file is validated against (section 6).

| Path | Content | Class | Schema |
|---|---|---|---|
| `.github/Rulebook-Settings.json` | Template URL and sha, base URL, publish target, quarantine policy, twins setting, `levels`, `stages`, the write token secret name, commit options, site, `update.schedule`, `scan.schedule`, `unusedRulebookFiles` (repository-relative paths with `/`, such as `stages/vnext.json`; a bare file name is rejected, [#49](https://github.com/ALCops/rulebook-engine/issues/49)). | settings | `rulebook-settings.schema.json` |
| `base/<level>.ruleset.json` | One per level: the ids the level changes relative to its `basedOn` level, a root level relative to the analyzer defaults. Shipped: `essential`, `recommended`, `strict`, `complete`. | system (shipped), org-owned (custom) | `ruleset.delta.schema.json` |
| `base/twins.json` | The PerTenantExtensionCop/AppSourceCop twin pairs (D23). | system | `rulebook-twins.schema.json` |
| `stages/<stage>.json` | One per non-default stage: the ids the stage changes. Shipped: `ci`, `vnext`. `stages/default.json` must not exist (C6). | system (shipped), org-owned (custom) | `ruleset.delta.schema.json` |
| `overrides.json` | Organization overrides with level and stage selectors. | org-owned | `rulebook-overrides.schema.json` |
| `quarantine.<stage>.json` | Ids held at `None` for that stage, written by the scan. One per stage, `quarantine.default.json` included. | org-owned | `rulebook-quarantine.schema.json` |
| `catalog/diagnostics.json` | Every known id with its analyzer default (D24). | org-owned | `rulebook-catalog.schema.json` |
| `catalog/scan-state.json` | The package version the scan recorded last per package and channel. Created by the first scan (WP08), never shipped. | org-owned | `rulebook-scan-state.schema.json` |
| `rulesets/<level>.ruleset.json`, `rulesets/<level>.<stage>.ruleset.json` | The generated endpoints, written by `Update-RulebookEndpoints` (WP03) in id order. `levels x stages` files. | generated | `ruleset.endpoint.schema.json` |
| `skeletons/<level>.<stage>.ruleset.json` | One include of the endpoint with `{BASEURL}`; project exceptions go into `rules`. `levels x stages` files. | generated (from the settings, by every update) | `ruleset.skeleton.schema.json` |
| `skeletons/README.md` | Explains the skeletons next to them (WP06). Not published; exempt from C11 by its exact name, as `README.md` in `rulesets/` is. | system | none |
| `.github/workflows/ScanDiagnostics.yaml` | The diagnostic scan (WP08): dispatch inputs `includePrerelease`, `directCommit`; `schedule:` written by the update from `scan.schedule` (shipped daily, `17 4 * * *`). Scan branch `scan-diagnostics/<branch>`, rebuilt by every run. | system | none |
| `.github/workflows/UpdateRulebookSystemFiles.yaml` | The update workflow (WP07): dispatch inputs `templateUrl`, `downloadLatest`, `directCommit`; `schedule:` written by the update from `update.schedule`. Update branch `update-rulebook-system-files/<branch>/<yyMMddHHmmss>`. | system | none |
| `.rulebook/<stage>.ruleset.json` in an AL project | A published skeleton with `{BASEURL}` resolved, written by the init script `scripts/Get-RulebookSkeletons.ps1` or downloaded by hand. One per stage. Not part of the rulebook repository. | not managed | `ruleset.skeleton.schema.json` |

The **profile follows the folder**: `base/*.ruleset.json` and `stages/*.json` are delta, `rulesets/` is endpoint, `skeletons/` is skeleton. `base/`, `stages/`, `rulesets/` and `skeletons/` are flat. A file in `base/` or `stages/` that the template does not ship is org-owned by that fact.

## 3. The `default` suffix rule

The `default` stage has no file and no suffix in `rulesets/`; that is the only place where the literal `default` is dropped. Everywhere else it is written:

| Where | Spelling |
|---|---|
| Endpoint | `rulesets/strict.ruleset.json` (dropped) |
| Skeleton | `skeletons/strict.default.ruleset.json` |
| Quarantine file | `quarantine.default.json` |
| AL project copy | `.rulebook/default.ruleset.json` |
| Override selector | `"stages": ["default"]` |
| Quarantine policy value | `"stages": ["default", "ci"]` in `settings.quarantine` |
| Key of generated JSON | `strict.default` |
| Matrix column | `Default` |

## 4. URL scheme and hosts

```
<baseUrl>/rulesets/<level>.ruleset.json            default stage
<baseUrl>/rulesets/<level>.<stage>.ruleset.json    every other stage
```

The published layout (Publish, WP05 and WP06) is exactly these files plus the rendered skeletons, the manifest and an index page:

```
<baseUrl>/index.html                               (also served at <baseUrl>/) one table per stage, one row per level
<baseUrl>/rulesets/<level>[.<stage>].ruleset.json  the levels x stages endpoints, as committed
<baseUrl>/skeletons/<level>.<stage>.ruleset.json   the skeletons with {BASEURL} replaced by baseUrl
<baseUrl>/rulebook.json                            the levels and stages, machine-readable (D43); read by the init script
```

Nothing else is published: not `base/`, `stages/`, `catalog/`, the settings, `skeletons/README.md` or a stray file in `rulesets/`. The dashboard (WP14) extends `<baseUrl>/rulebook.json` and adds `<baseUrl>/catalog/diagnostics.json` and the site pages.

- `baseUrl` is `https://` with a DNS host name and an optional numeric port (no user info), has no query, fragment, `.` and `..` segments, quotes, backslashes or control characters (it is written into the skeleton JSON as it is) and never ends with a slash (settings schema and C5), or empty until the organization sets it: the template ships `""` and Publish fails until it is set. It is rendered into skeletons and docs, never into `rulesets/`.
- The URL is unversioned (D8). A future version prefix would go between `baseUrl` and `rulesets/`, so nothing else is ever placed at that position.
- There is no segment for the kind of extension (D21).
- Hosts: the compiler fetches through Microsoft's anti-SSRF policy. `*.github.io` (the `pages` target) and `raw.githubusercontent.com` (the `dist-repo` target) pass with `/enableexternalrulesets`, with one request per compile and no redirect ([spike a](spikes/a-hosts-and-skeleton-include.md)). Custom domains, Azure static websites and gist raw URLs are not tested.

## 5. Shipped endpoints and skeletons

The 12 endpoints of the shipped set (4 levels x 3 stages):

| Level | `default` | `ci` | `vnext` |
|---|---|---|---|
| essential | `rulesets/essential.ruleset.json` | `rulesets/essential.ci.ruleset.json` | `rulesets/essential.vnext.ruleset.json` |
| recommended | `rulesets/recommended.ruleset.json` | `rulesets/recommended.ci.ruleset.json` | `rulesets/recommended.vnext.ruleset.json` |
| strict | `rulesets/strict.ruleset.json` | `rulesets/strict.ci.ruleset.json` | `rulesets/strict.vnext.ruleset.json` |
| complete | `rulesets/complete.ruleset.json` | `rulesets/complete.ci.ruleset.json` | `rulesets/complete.vnext.ruleset.json` |

The 12 skeletons, the stage suffix always written:

| Level | `default` | `ci` | `vnext` |
|---|---|---|---|
| essential | `skeletons/essential.default.ruleset.json` | `skeletons/essential.ci.ruleset.json` | `skeletons/essential.vnext.ruleset.json` |
| recommended | `skeletons/recommended.default.ruleset.json` | `skeletons/recommended.ci.ruleset.json` | `skeletons/recommended.vnext.ruleset.json` |
| strict | `skeletons/strict.default.ruleset.json` | `skeletons/strict.ci.ruleset.json` | `skeletons/strict.vnext.ruleset.json` |
| complete | `skeletons/complete.default.ruleset.json` | `skeletons/complete.ci.ruleset.json` | `skeletons/complete.vnext.ruleset.json` |

An organization that adds or removes levels or stages gets exactly `levels x stages` of each (C11).

## 6. Schemas

The schemas live in the engine under `schemas/` and are served from the `v1` release branch over raw URLs. Draft 2020-12. The `v1` URLs go live with WP13 ([#15](https://github.com/ALCops/rulebook-engine/issues/15)); until then they return 404, and the tests validate against the local files.

| File | URL | Validates |
|---|---|---|
| `ruleset.schema.json` | `https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.schema.json` | Any ruleset file (hub: holds the three profiles as `$defs` and accepts a file that matches any of them) |
| `ruleset.delta.schema.json` | `https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.delta.schema.json` | `base/<level>.ruleset.json`, `stages/<stage>.json` |
| `ruleset.endpoint.schema.json` | `https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.endpoint.schema.json` | `rulesets/*.ruleset.json` |
| `ruleset.skeleton.schema.json` | `https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.skeleton.schema.json` | `skeletons/*.ruleset.json`, `.rulebook/*.ruleset.json` |
| `rulebook-overrides.schema.json` | `https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-overrides.schema.json` | `overrides.json` |
| `rulebook-quarantine.schema.json` | `https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-quarantine.schema.json` | `quarantine.<stage>.json` |
| `rulebook-twins.schema.json` | `https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-twins.schema.json` | `base/twins.json` and the engine's `docs/rulebook/matrix/twins.json` |
| `rulebook-catalog.schema.json` | `https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-catalog.schema.json` | `catalog/diagnostics.json` |
| `rulebook-settings.schema.json` | `https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-settings.schema.json` | `.github/Rulebook-Settings.json` |
| `rulebook-scan-state.schema.json` | `https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-scan-state.schema.json` | `catalog/scan-state.json` (closed) |

A tool that validates files in an organization repository uses the profile file for the folder; the hub accepts a file that matches any profile (an endpoint rule with a `justification` passes it through the delta profile), so it is for editors only and is never the `$schema` of a generated file.

The ruleset profiles:

| Profile | Folders | Required | Forbidden | `justification` on a rule |
|---|---|---|---|---|
| delta | `base/`, `stages/` | `name`, `rules` | `includedRuleSets`, `generalAction` | optional (D40) |
| endpoint | `rulesets/` | `name`, `rules` | `includedRuleSets`, `generalAction`, `justification` | forbidden |
| skeleton | `skeletons/`, `.rulebook/` | `name`, exactly one `includedRuleSets` entry with action `Default` and a `path` | `generalAction` | optional |

Every rule is `{ id, action }` plus the optional `justification` where allowed, nothing else. `id` matches `^[A-Z]{2,3}[0-9]{4}i?$` (`PTE0011`, `LC0089i`); `action` is `Error`, `Warning`, `Info`, `Hidden` or `None`, never `Default`. Overrides selectors are arrays only: `["*"]` or a non-empty list of distinct slugs. A quarantine entry has no `action`.

`$schema` in a file:

- The settings file carries the settings schema URL; the update workflow refreshes it.
- The shipped `base/*.ruleset.json` and `stages/*.json` carry the delta profile URL, so an editor validates a hand-edited level or stage file.
- The shipped `base/twins.json` carries the twins schema URL; the WP04 template generator (`Build-RulebookBase`) writes it. The engine's `docs/rulebook/matrix/twins.json`, written by `tools/rulebook/Build-Matrix.ps1`, carries none: it is a build input of the engine, never edited in an organization repository, and the tests validate it against the local schema file ([#43](https://github.com/ALCops/rulebook-engine/issues/43)).
- The shipped seed `catalog/diagnostics.json` carries the catalog schema URL; the shipped `overrides.json` and `quarantine.<stage>.json` carry the overrides and quarantine schema URLs, with an empty `rules` array.
- Every schema allows an optional `$schema` string, the endpoint and skeleton profiles included, but the generator never writes one into an endpoint or a skeleton: the compiler fetches those files and they stay minimal.

No schema file has an `$id`. `Test-Json -SchemaFile` (pwsh 7.6) resolves a relative `$ref` to a sibling file, such as the profile files' `"$ref": "ruleset.schema.json#/$defs/delta"`, only when the schema has no absolute `$id`; with an `https://` `$id` it fails to parse the schema. Each schema says so in its `$comment`. Every pattern ends with `(?![\s\S])` instead of `$`, because in .NET (`Test-Json`) `$` also matches before a trailing newline, while `\z` would be a literal `z` in the ECMA-262 regexes editors use; the lookahead means end of string in both. The input schemas are self-contained and repeat the shared definitions (`diagnosticId`, `ruleAction`, `slug`); the test suite checks they stay identical.

What the schemas cannot check, and the validation check that does (ARCHITECTURE.md section 5.3):

| Rule | Check |
|---|---|
| No id twice in one file | C2 |
| Slugs unique per array after lowercasing; `basedOn` resolves to an existing `base/<slug>.ruleset.json` without a cycle; quarantine policy values name stages from the settings | C5 |
| Every listed level and non-default stage has its file; `stages/default.json` does not exist | C6 |
| Every id exists in the catalog | C7 |
| Override selectors name slugs from the settings (the schema checks only their shape) | C10 |
| No endpoint entry equals the catalog default; exactly `levels x stages` endpoints and skeletons, and no other file in `rulesets/` or `skeletons/` except `README.md` | C11 |
| `count` in `base/twins.json` equals the number of pairs | C14 |
| Every `quarantine.<x>.json` names a stage of the settings | C16 |

The settings schema is closed: an unknown key at the top level or in `publish`, `quarantine`, `commitOptions`, `site`, `update` or `scan` is an error, and a work package that needs a new key adds it to the schema in its own pull request. `publish.target` requires its own fields (`dist-repo`: `repository`, `branch`; `azure-blob`: `storageAccount`, `container`; `gist`: `gistId`); the fields of another target are allowed and ignored. The catalog schema is minimal: `id`, `defaultSeverity` and `enabledByDefault` are required per entry, the other known fields are typed (the scan fields of WP08 included: `firstStableVersion`, `advertised`, `deprecated` and the closed `defaultChanges` elements), and a later scan may add more. The scan-state schema is closed.

The fixtures under `tests/fixtures/schemas/<valid|invalid>/<schema-basename>/<reason>.json` show what each schema accepts and rejects; `tests/Schemas.Tests.ps1` runs them.

## 7. Examples

Each example is a valid fixture, quoted as is.

Level file, `tests/fixtures/schemas/valid/ruleset.delta/level-recommended.json`:

```json
{
  "name": "Rulebook Recommended",
  "description": "Level recommended, basedOn essential. Lists the ids whose action differs from essential. Generated from docs/rulebook; do not edit.",
  "rules": [
    { "id": "AL0200", "action": "Warning", "justification": "Compiler warning at author severity from Recommended; D-01" },
    { "id": "AS0084", "action": "Error", "justification": "Needs AppSourceCop.json or marketplace manifest fields; off at Essential, native from Recommended; F-07" }
  ]
}
```

Stage file, `tests/fixtures/schemas/valid/ruleset.delta/stage-ci.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.delta.schema.json",
  "name": "Rulebook stage CI",
  "description": "Stage ci. Applied on top of every level where the level result is not None. Generated from docs/rulebook; do not edit.",
  "rules": [
    { "id": "AL0432", "action": "Info", "justification": "Replacement may not exist yet; advisory in CI; F-05" },
    { "id": "AL0603", "action": "Info", "justification": "Implicit conversion; advisory in CI; D-01" }
  ]
}
```

Endpoint, `tests/fixtures/schemas/valid/ruleset.endpoint/endpoint-strict-ci.json`:

```json
{
  "name": "Rulebook Strict / CI",
  "description": "Level strict, stage ci, twins both. Generated from base/essential.ruleset.json, base/recommended.ruleset.json, base/strict.ruleset.json plus stages/ci.json, overrides.json and quarantine.ci.json; do not edit. Ids at their analyzer default are not listed.",
  "rules": [
    { "id": "AL0432", "action": "Info" },
    { "id": "AA0001", "action": "Warning" }
  ]
}
```

Skeleton, `tests/fixtures/schemas/valid/ruleset.skeleton/skeleton-baseurl-placeholder.json`:

```json
{
  "name": "Rulebook Strict / CI",
  "description": "Copy into your AL project and point al.ruleSetPath or the AL-Go rulesetFile at it. Add project exceptions to rules; they override the endpoint.",
  "includedRuleSets": [ { "action": "Default", "path": "{BASEURL}/rulesets/strict.ci.ruleset.json" } ],
  "rules": []
}
```

Overrides, `tests/fixtures/schemas/valid/rulebook-overrides/entries-with-justification.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-overrides.schema.json",
  "rules": [
    { "id": "AA0072", "action": "Warning", "levels": ["*"], "stages": ["*"], "justification": "House style" },
    { "id": "AL0432", "action": "None", "levels": ["essential", "recommended"], "stages": ["ci"], "justification": "Backlog DEV-1234" }
  ]
}
```

Quarantine, `tests/fixtures/schemas/valid/rulebook-quarantine/one-entry.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-quarantine.schema.json",
  "rules": [
    { "id": "LC0099", "justification": "New in alcops.analyzers 1.4.0-beta.1 (prerelease), quarantined 2026-10-01. Review and adopt." }
  ]
}
```

Twin pairs, `tests/fixtures/schemas/valid/rulebook-twins/shipped-shape.json`:

```json
{
  "generatedBy": "tools/rulebook/Build-Matrix.ps1",
  "setting": "twins",
  "values": ["both", "appsource", "pte"],
  "count": 2,
  "pairs": [
    { "pte": "PTE0011", "appsource": "AS0048", "title": "The publisher name is too long" },
    { "pte": "PTE0003", "appsource": "AS0061", "title": "Procedures must not subscribe to CompanyOpen events" }
  ]
}
```

Catalog, `tests/fixtures/schemas/valid/rulebook-catalog/minimal.json`:

```json
{
  "version": 1,
  "diagnostics": [
    { "id": "AL0432", "defaultSeverity": "Warning", "enabledByDefault": true },
    { "id": "LC0054", "defaultSeverity": "Info", "enabledByDefault": false }
  ]
}
```

Settings with only the required keys, `tests/fixtures/schemas/valid/rulebook-settings/minimal-required.json` (the template's full file is `template-default.json` next to it and the example in [ARCHITECTURE.md](../ARCHITECTURE.md) section 8):

```json
{
  "templateUrl": "https://github.com/ALCops/rulebook@main",
  "baseUrl": "https://contoso.github.io/rulebook",
  "publish": { "target": "pages" },
  "quarantine": { "stages": null, "prereleaseStages": null },
  "levels": [ { "name": "Essential" } ],
  "stages": [ { "name": "default" } ]
}
```

## 8. Reserved names

| Name | Owner | Note |
|---|---|---|
| `schemas/rulebook-changeset.schema.json` | WP15 ([#17](https://github.com/ALCops/rulebook-engine/issues/17)) | The change set the dashboard submits and ChangeRule builds ([dashboard.md](../dashboard.md) section 6). `justification` is optional (D37). |
| The path segment between `baseUrl` and `rulesets/` | a future major version | Kept free for a version prefix (section 4). |

# Configuration dependencies

Rules that only work, or only make sense, when a configuration file provides input. The ruleset does not gate on configuration; the matrix places these rules assuming the configuration exists, and this file says what happens when it does not. The `Config` column of the inventory carries the same tokens.

## 1. AppSourceCop.json

| Token | Key | Ids | Without the key |
|---|---|---|---|
| `AppSourceCop.json:baseline` | `baselinePackageCachePath` (plus `name`, `publisher`, `version` of the previous release) | All `breaking-change` rules (see `inventory/AS.md`), AS0011, AS0098, AS0099 through the upgrade validator | Silent: there is nothing to compare against. AS0003 or AS0091 fire only when a baseline is configured but cannot be loaded. |
| `AppSourceCop.json:mandatoryAffixes` | `mandatoryAffixes` | AS0011, AS0054, AS0079, AS0098, AS0150, AS0151 | AS0054 itself fires ("configuration must specify affixes"); the others are silent. This is why the whole set is `marketplace`, `None` at Essential and native from Recommended (DR-019): a project without affixes either configures them or opts out of AS0054. |
| `AppSourceCop.json:supportedCountries` | `supportedCountries` | AS0055, AS0056, AS0057, AS0087 | AS0055 (Hidden by default) reports the missing list; AS0057 needs XLIFF files as well. |
| `AppSourceCop.json:additiveChangeValidation` | `additiveChangeValidationAbsoluteFolderPath` | AS0131, AS0132, AS0133 | Silent. All three are Hidden by default and reach `Info` only in Complete. |
| `AppSourceCop.json:obsoleteTag` | `obsoleteTagVersion`, `obsoleteTagMinAllowedMajorMinor`, `obsoleteTagAllowedVersions`, `obsoleteTagPattern` | AS0072 to AS0076, AS0105 | AS0075 works without configuration; AS0072 to AS0074 and AS0076 are Hidden by default and only fire when a tag policy exists; AS0105 compares against `obsoleteTagMinAllowedMajorMinor`. |

Recommended `AppSourceCop.json` per kind of project:

```json
// AppSource submission
{ "mandatoryAffixes": ["ABC"], "supportedCountries": ["US", "GB"],
  "name": "My App", "publisher": "My Publisher", "version": "1.0.0.0",
  "baselinePackageCachePath": ".alpackages/baseline",
  "obsoleteTagMinAllowedMajorMinor": "26.0" }

// per-tenant extension: keep the file if you want breaking-change checks from Recommended;
// add "mandatoryAffixes" if you use affixes, otherwise opt out of AS0054 (see the template's docs/pte-or-appsource.md)
{ "name": "My App", "publisher": "My Publisher", "version": "1.0.0.0",
  "baselinePackageCachePath": ".alpackages/baseline" }
```

## 2. app.json

| Ids | What is read |
|---|---|
| AS0013, AS0014, AS0084, AS0099, PTE0001, PTE0002, PTE0022, PTE0023 | `idRanges` (`AS0084` also compares against the AppSource allocated range) |
| AS0015 | `features` contains `TranslationFile` |
| AS0047, AS0048, AS0104, PTE0010, PTE0011, PTE0015 | `name`, `publisher` |
| AS0051, AS0052, AS0092 | Marketplace fields: `contextSensitiveHelpUrl`, `url`, `EULA`, `privacyStatement`, `help`, `applicationInsightsConnectionString` |
| AS0053, PTE0005 | `target` |
| AS0081, AS0126 | `internalsVisibleTo` |
| AS0085, AS0100, PTE0020 | `application` versus an explicit Base Application dependency |
| PTE0009 | Properties not allowed in a per-tenant extension |

## 3. alcops.json (ALCops)

| Token | Ids | Built-in default |
|---|---|---|
| `alcops.json:CognitiveComplexityThreshold` | LC0089, LC0089i, LC0090 | 15 |
| `alcops.json:CyclomaticComplexityThreshold` | LC0009, LC0010 | 8 |
| `alcops.json:MaintainabilityIndexThreshold` | LC0007, LC0008 | 20 |
| `alcops.json:LanguagesToTranslate` | LC0091 | none: the rule is silent until languages are listed |
| `alcops.json:NamingPatterns` | LC0092 | none: silent until patterns are configured |
| `alcops.json:SubscriberNamingPattern`, `alcops.json:KnownAcronyms` | LC0098 | built-in pattern |
| `alcops.json:UseSequentialGuidScope` | PC0029 | key fields only |
| `alcops.json:ToolTipAllowedPunctuations` | AC0014 | period |
| `alcops.json:StatementBlockSpacing` | FC0007 | built-in spacing |

CM0001 reports an `alcops.json` that cannot be loaded and is `Warning` at every level and stage: a broken configuration silently disables rules, which a pipeline must not accept.

## 4. XLIFF translation files

AS0057, AS0087, AS0125 and LC0091 read the `Translations/*.xlf` files of the project and are silent without them. The compiler warnings AL0472, AL0473, AL0479, AL1029 and AL1030 report problems inside those files and are relaxed to `Info` in the `CI` stage (`stages/ci.json`) because a translation round-trip is usually a separate process from the code change.

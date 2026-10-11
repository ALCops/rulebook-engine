# Per-tenant extension or AppSource app?

Rulebook does not ask. Rulebook assumes both Microsoft cops are enabled, PerTenantExtensionCop and AppSourceCop, and runs nearly every rule at the severity its author chose. Some of those rules were written for one kind of extension only and contradict each other: a per-tenant extension must use object ids in 50000..99999 (PTE0001) while an AppSource app must not (AS0084). Your project decides which side applies, and this page shows the three ways to do that.

> **Status:** written 2026-10-01 alongside decisions [D21](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0021-no-target-dimension-one-ladder-per-rule-both-microsoft-cops.md), [D22](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0022-sparse-endpoints-an-id-at-its-analyzer-default-is-not-listed.md) and [D23](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0023-twin-pairs-are-an-organization-setting.md) of the engine (index: [rulebook-engine/docs/adr](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/README.md)). The compiler behaviour it relies on is verified in the engine's [compiler-ruleset-internals.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md), section 8. The id lists below are derived from the engine's inventory families `pte-only` and `marketplace` and from its twins table; a change there is a change here.

## Contents

1. [Why Rulebook enables both cops](#1-why-rulebook-enables-both-cops)
2. [What contradicts](#2-what-contradicts)
3. [Route A: disable a cop](#3-route-a-disable-a-cop)
4. [Route B: suppressWarnings in app.json](#4-route-b-suppresswarnings-in-appjson)
5. [Route C: a project ruleset file](#5-route-c-a-project-ruleset-file)
6. [Ready-made lists](#6-ready-made-lists)
7. [The twins setting](#7-the-twins-setting)
8. [Troubleshooting](#8-troubleshooting)

## 1. Why Rulebook enables both cops

Microsoft ships two cops that know the rules of the two marketplaces: PerTenantExtensionCop for extensions installed in one customer's environment, AppSourceCop for apps published on AppSource. Most of their rules are good practice for everyone (ApplicationArea on controls, no CompanyOpen subscribers, permission sets per table), and both cops carry upgrade and extensibility checks that save you a broken update later. Rulebook therefore assumes you run both, at the severities Microsoft chose:

```json
{
    "al.enableCodeAnalysis": true,
    "al.codeAnalyzers": [
        "${CodeCop}",
        "${UICop}",
        "${PerTenantExtensionCop}",
        "${AppSourceCop}"
    ]
}
```

What Rulebook does not do is guess which kind of extension a project is and hide the other cop's rules for it. That was a separate dimension of every endpoint in an earlier design and it tripled the number of files for a decision the project can make better, in one line, on its own side. The price is that you see a handful of contradicting diagnostics until you opt out of them. The tables below tell you which ones.

Two facts make the opt-out cheap:

- A Rulebook endpoint lists only the rules whose severity differs from the analyzer default. A rule at its native severity, which is what the contradicting blockers are, is not in the file at all. Four rules of section 2 are the exception: PTE0023, AS0151, AS0055 and AS0057 are raised above their default and listed from Strict upward (see section 4).
- The compiler merges `suppressWarnings` from `app.json` with the ruleset by taking the stricter of the two, after the ruleset is loaded, and "suppressed" is never stricter. So `suppressWarnings` switches off exactly the rules the endpoint does not list, and has no effect on the rules it does list.

## 2. What contradicts

Rules that fire in a project they were not written for. "From" is the first Rulebook level that enables the rule.

### Rules written for per-tenant extensions, hitting AppSource apps

| Id | Title | Default | From | Why it bites an AppSource app |
|---|---|---|---|---|
| PTE0001 | Object ID must be in free range (50000..99999) | Error | Essential | AppSource ids live in the partner's range, 1000000 and up. |
| PTE0002 | Field ID must be in free range (50000..99999) | Error | Essential | Same for table extension fields. |
| PTE0009 | This app.json property must not be used for per-tenant extensions (`helpBaseUrl`, `supportedLocales`) | Error | Essential | AppSource apps use these properties. |
| PTE0010 | The extension name is too long (50 characters) | Error | Essential | AppSourceCop allows 200 (AS0047). Only bites names longer than 50. |
| PTE0013 | Entitlements cannot be defined in an extension | Error | Essential | AppSource apps may define entitlements. |
| PTE0024 | Moving tables or fields is not allowed on per-tenant extensions | Error | Essential | AppSourceCop validates moves instead of forbidding them. |
| PTE0023 | The enum ordinal value should be within the allowed range | Info | Recommended | Checks against the per-tenant range. Listed from Strict upward (Warning): use route C (project ruleset) there, `suppressWarnings` is a silent no-op. |

### Rules written for AppSource apps, hitting per-tenant extensions

| Id | Title | Default | From | Why it bites a per-tenant extension |
|---|---|---|---|---|
| AS0013 | The field identifier must be within the allowed range | Error | Essential | A table extension field outside `idRanges` fires AS0013. The message also names 50000..99999, but only AS0084 checks that range. (Per the code, 1..49999 is also accepted when the extended table is in the same app or has the same publisher; not observed.) |
| AS0084 | The ID range assigned to the extension must be within the allowed range | Error | Recommended | Requires `idRanges` inside the partner's AppSource range and outside 50000..99999. |
| AS0054 | The AppSourceCop configuration must specify the set of affixes | Error | Recommended | Fires in every project without `mandatoryAffixes` in `AppSourceCop.json`. Configure affixes or opt out. |
| AS0011, AS0098, AS0079, AS0150, AS0151 | Affix rules | Error, Warning, Warning, Error, Info | Recommended | Only fire once affixes are configured. Keep them if you use affixes. AS0151 is listed from Strict upward (Warning): use route C (project ruleset) there, `suppressWarnings` is a silent no-op. |
| AS0051 | Manifest property is required for AppSource submission (EULA, privacy statement, help, logo, ...) | Error | Recommended | Marketplace listing fields. |
| AS0052 | The property `url` must be set to a valid URL | Error | Recommended | Marketplace listing field. |
| AS0092 | The app.json file must specify an Azure Application Insights resource | Warning | Recommended | Required for AppSource, optional elsewhere. |
| AS0015 | TranslationFile must be enabled | Error | Recommended | Required for AppSource. |
| AS0055, AS0056, AS0057 | Supported countries and their translations | Hidden, Warning, Hidden | Recommended | Need `supportedCountries` in `AppSourceCop.json`. AS0055 and AS0057 are listed from Strict upward (Info): use route C (project ruleset) there, `suppressWarnings` is a silent no-op. |
| AS0003, AS0091 | The previous version (or its dependencies) could not be found | Error | Recommended | Only fire when a baseline is configured in `AppSourceCop.json` but cannot be loaded. Fix the baseline rather than opting out. |

### Rules that exist in both cops (twins)

Seventeen checks are implemented twice with the same title, for example PTE0011 and AS0048 (publisher name too long) or PTE0008 and AS0062 (ApplicationArea required). With both cops enabled you get two diagnostics for one finding. These are not contradictions; both sides agree. Section 7 explains how an organization keeps one side.

Not in any list: PTE0005 and AS0053 both demand a cloud compilation target, PTE0004 and AS0103 both want permission sets per table, and so on. Those apply to every project.

## 3. Route A: disable a cop

Remove the cop that does not apply from `al.codeAnalyzers` in `.vscode/settings.json`, and from the analyzer list of your pipeline (AL-Go `enableAppSourceCop` and `enablePerTenantExtensionCop` settings, the ALOps task inputs, or the `/analyzer:` switches of `alc`).

```json
{
    "al.enableCodeAnalysis": true,
    "al.codeAnalyzers": [
        "${CodeCop}",
        "${UICop}",
        "${PerTenantExtensionCop}"
    ]
}
```

This is the wrecking ball. It removes the contradicting rules and also every good-practice rule of that cop, including its side of the seventeen twins. If your organization has set `twins` to anything but `both` (section 7), a project that disables a cop loses the twin checks entirely: the remaining cop's side is switched off by the setting and the other cop is not running. Rulebook cannot see your analyzer list, so it cannot warn you. Use route A only when you really want nothing from that cop, and keep `twins` at `both`.

## 4. Route B: suppressWarnings in app.json

List the ids in `suppressWarnings` of `app.json`. Despite the property's name, this suppresses analyzer diagnostics of any severity, Error included; only compiler errors cannot be suppressed.

```json
{
  "id": "1d002f53-6fc2-4293-aedd-8041e7ccdc37",
  "name": "ALCops.Demo",
  "publisher": "Arthur van de Vondervoort",
  "version": "1.0.0.0",
  "application": "28.0.0.0",
  "platform": "28.0.0.0",
  "runtime": "17.0",
  "idRanges": [
    {
      "from": 50000,
      "to": 99999
    }
  ],
  "features": [
    "NoImplicitWith",
    "TranslationFile",
    "NoPromotedActionProperties"
  ],
  "suppressWarnings": [
    "AS0013",
    "AS0084",
    "AS0054",
    "AS0051",
    "AS0052",
    "AS0092"
  ]
}
```

This is the simple route, and it works under one condition: **the id must not be listed in the endpoint you compile against.** The compiler loads the ruleset first and then merges `suppressWarnings` by keeping the stricter value per id, and a suppression is never stricter than anything, so a listed id keeps the endpoint's action. Rulebook endpoints list only the rules whose action differs from the analyzer default. Every rule in section 2 except four runs at its native severity from the level that enables it, so from that level on it is not listed and route B works. PTE0023, AS0151, AS0055 and AS0057 are listed from Strict upward (PTE0023 and AS0151 at Warning, AS0055 and AS0057 at Info): use route C (project ruleset) there, `suppressWarnings` is a silent no-op. Two cases where it silently does nothing:

- **The endpoint lists the id.** At Essential most marketplace checks (AS0084, AS0054, AS0051, ...) are explicitly `None`, so they are listed, and at Essential you do not need to suppress them anyway. If your organization overrides one of these ids in its `overrides.json`, it becomes listed and only route C works for it.
- **Your project ruleset file lists the id.** A rule in the `rules` of your own ruleset file (route C) is a ruleset entry like any other.

To know what an endpoint lists, open it: the URL in your skeleton file returns the JSON. The Rulebook index page shows the number of listed ids per endpoint.

## 5. Route C: a project ruleset file

Create a ruleset file in your project, include the endpoint, and put your opt-outs in `rules`. Point `al.ruleSetPath` (VS Code) or `rulesetFile` (AL-Go) at the file. Rulebook publishes a skeleton per endpoint under `skeletons/` that already has the include; copy it as `.rulebook/<stage>.ruleset.json` (`default`, `ci`, `vnext` with the shipped stages).

```json
{
    "name": "My Project",
    "includedRuleSets": [
        {
            "action": "Default",
            "path": "https://contoso.github.io/rulebook/rulesets/recommended.ci.ruleset.json"
        }
    ],
    "rules": [
        {
            "id": "AS0084",
            "action": "None",
            "justification": "Per-tenant extension: the ID range [50000..99999] is intentional, the AppSource range does not apply."
        },
        {
            "id": "AS0013",
            "action": "None",
            "justification": "Per-tenant extension: field ids are in the free range on purpose."
        }
    ]
}
```

This is the flexible route. A file's own `rules` overwrite whatever its includes say, up or down, so it works for every id: the contradicting blockers, a rule your organization has overridden, and any project-specific exception. One file per stage, because each stage points at a different endpoint; the `rules` array is repeated, so an opt-out goes into every stage's file. The init script downloads the files of your level into `.rulebook/`; layout, settings and exceptions are in [al-project.md](al-project.md). The compiler still makes exactly one HTTP request, for the included endpoint. `justification` is ignored by the compiler and read by your colleagues.

## 6. Ready-made lists

Copy the list for your kind of project. Route B is shown for `app.json`, route C for the `rules` array of your project ruleset file. Both lists assume Recommended or higher; at Essential most marketplace checks are off already.

### I build per-tenant extensions

```json
{ "suppressWarnings": [ "AS0013", "AS0084", "AS0054", "AS0051", "AS0052", "AS0092", "AS0015" ] }
```

```json
[
  { "id": "AS0013", "action": "None", "justification": "PTE: field ids in the free range 50000..99999" },
  { "id": "AS0084", "action": "None", "justification": "PTE: idRanges in the free range 50000..99999" },
  { "id": "AS0054", "action": "None", "justification": "PTE: no mandatory affixes configured" },
  { "id": "AS0051", "action": "None", "justification": "PTE: no marketplace listing fields" },
  { "id": "AS0052", "action": "None", "justification": "PTE: no marketplace url" },
  { "id": "AS0092", "action": "None", "justification": "PTE: Application Insights not mandatory" },
  { "id": "AS0015", "action": "None", "justification": "PTE: TranslationFile not mandatory" }
]
```

Keep AS0054 (and do not list it) if you use affixes: add `mandatoryAffixes` to `AppSourceCop.json` and AS0011 and AS0098 will guard them. Keep `TranslationFile` enabled and drop AS0015 from the list if you translate.

### I build AppSource apps

```json
{ "suppressWarnings": [ "PTE0001", "PTE0002", "PTE0009", "PTE0013", "PTE0024", "PTE0023", "PTE0010" ] }
```

```json
[
  { "id": "PTE0001", "action": "None", "justification": "AppSource: object ids in the partner range" },
  { "id": "PTE0002", "action": "None", "justification": "AppSource: field ids in the partner range" },
  { "id": "PTE0009", "action": "None", "justification": "AppSource: helpBaseUrl and supportedLocales are used" },
  { "id": "PTE0013", "action": "None", "justification": "AppSource: entitlements are defined" },
  { "id": "PTE0024", "action": "None", "justification": "AppSource: table moves are validated by AppSourceCop" },
  { "id": "PTE0023", "action": "None", "justification": "AppSource: enum ordinals in the partner range" },
  { "id": "PTE0010", "action": "None", "justification": "AppSource: extension name may exceed 50 characters" }
]
```

Drop PTE0010 from the list if your name is 50 characters or shorter; the rule then never fires. PTE0023 is listed from Strict upward: at Strict and Complete its `suppressWarnings` entry is a silent no-op, so use the route C entry there.

### Mixed organizations

An organization that builds both kinds keeps `twins` at `both` and lets every project pick its list. An organization that builds only one kind can put the same opt-outs into its `overrides.json` once, for every level and stage, so projects need nothing; the ids then become listed at `None` in every endpoint and route B is no longer needed for them.

## 7. The twins setting

The seventeen twin pairs report every finding twice when both cops run. Your Rulebook repository has one setting for that in `.github/Rulebook-Settings.json`:

```json
{
  "twins": "both"
}
```

| Value | Effect | Use when |
|---|---|---|
| `both` | Nothing changes; both sides are active at their native severity. | The default. Mandatory when any project runs only one of the two cops (route A). |
| `appsource` | The PerTenantExtensionCop side of every pair is written at `None` in every endpoint. | Every project runs AppSourceCop. |
| `pte` | The AppSourceCop side of every pair is written at `None` in every endpoint. | Every project runs PerTenantExtensionCop. |

The pair list ships with your repository as `base/twins.json` and is updated by the Update Rulebook System Files workflow when Microsoft adds a pair. The setting only touches the twins; the contradicting blockers of section 2 are not pairs and still need the lists of section 6.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| AS0084 is still reported after adding it to `suppressWarnings`. | The endpoint you compile against lists AS0084 (for example because your organization overrides it), and a listed id keeps the endpoint's action. | Open the endpoint URL and search for the id. If it is listed, use route C. |
| Both PTE0011 and AS0048 are reported for the same publisher name. | Twins; both cops are on and `twins` is `both`. | Expected with both cops. Fix the finding once, or set `twins` in the organization settings if every project runs both cops the same way. |
| PTE0011 (twin of AS0048) disappeared after I disabled AppSourceCop. | `twins` is `appsource`, so the PerTenantExtensionCop side of every pair is `None` in every endpoint; with AppSourceCop off, neither side reports. | Keep `twins` at `both` when projects disable a cop. |
| Rules the endpoint switches off or changes (for example the marketplace checks at Essential) are suddenly reported at their default severities. | The ruleset failed to load (AL1033: unreachable or invalid endpoint; AL0767: external rulesets disabled) and every rule fell back to its analyzer default severity. | Fix the endpoint or enable external rulesets in the consumer. Pipelines should treat AL1033 as a failure. |
| A rule I suppressed in `app.json` works in VS Code but not in the pipeline, or the other way round. | Different stages point at different endpoints; one of them lists the id. | Compare the two endpoints, or move the opt-out into the `rules` of both project ruleset files. |

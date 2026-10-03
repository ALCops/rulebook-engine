# Overlaps between rules

Pairs of diagnostics that report the same construct, extend each other, or contradict each other, with the resolution the matrix applies. The `Flags` column of the inventory carries the same pairs as `twin:`, `extends:`, `complements:` and `contradicts:` tokens.

## 1. Kinds and resolutions

| Kind | Meaning | Resolution |
|---|---|---|
| `twin` | A PerTenantExtensionCop rule and an AppSourceCop rule with the identical title and check. Both fire when both cops are loaded. | Both sides are active at their native ladder (DR-020). An organization that builds only one kind of extension picks a side with the `twins` setting (`both`, `appsource`, `pte`) of its Rulebook repository; the generator writes the other side at `None`. The pairs are exported to `matrix/twins.json`; check V6 keeps flags, table and export in sync. |
| `extends` | An ALCops rule that fires only in the gap its Microsoft counterpart leaves. | Keep both. The pair never reports the same location twice. |
| `complements` | Two rules that look at the same property from different angles. | Keep both. |
| `contradicts` | Two rules whose fixes pull in opposite directions. | One side loses at every level; recorded as an override with a `DR`. |

## 2. Twins (PerTenantExtensionCop / AppSourceCop)

| PTE | AS | Title | Defaults (PTE / AS) |
|---|---|---|---|
| PTE0003 | AS0061 | Procedures must not subscribe to CompanyOpen events | Error / Error |
| PTE0004 | AS0103 | Table definitions must have a matching permission set | Error / Warning |
| PTE0005 | AS0053 | The compilation target must be allowed in a multi-tenant SaaS environment | Error / Error |
| PTE0008 | AS0062 | Page controls and actions must use the ApplicationArea property | Error / Error |
| PTE0010 | AS0047 | The extension name is too long | Error / Error |
| PTE0011 | AS0048 | The publisher name is too long | Error / Error |
| PTE0012 | AS0081 | InternalsVisibleTo should not be used as a security feature | Warning / Warning |
| PTE0014 | AS0094 | Permission Sets should not be defined in XML files | Warning / Warning |
| PTE0015 | AS0104 | The extension name is not valid | Error / Error |
| PTE0016 | AS0110 | Permission set extensions should not include permissions for objects defined in another application | Warning / Warning |
| PTE0017 | AS0111 | Permission set extensions should not include permission sets defined in another application | Warning / Warning |
| PTE0018 | AS0112 | Permission set extensions should not include permission sets which include permissions for objects defined in another application | Warning / Warning |
| PTE0019 | AS0113 | Permission set extensions should not include wildcard permissions | Warning / Warning |
| PTE0021 | AS0008 | Defining reserved namespaces is not allowed | Error / Error |
| PTE0022 | AS0099 | The member ID should be within the allowed range | Info (off) / Info |
| PTE0025 | AS0130 | Avoid using duplicate object names | Warning / Warning |
| PTE0026 | AS0138 | Table fields should use the AllowInCustomizations property | Hidden / Hidden |

Unpaired PerTenantExtensionCop rules: PTE0001, PTE0002, PTE0009, PTE0013, PTE0023, PTE0024 (`pte-only`: native at every level, an AppSource project opts out) and PTE0006, PTE0007, PTE0020 (`general`, valid for everyone).

Related but not twins (different checks, both stay active, DR-020):

| PTE | AS | Why not a twin |
|---|---|---|
| PTE0006 (encryption key functions must not be invoked) | AS0060 (unsafe methods) | AS0060 covers a wider set of methods; PTE0006 is one of them. |
| PTE0007 (test assertions in a non-test context) | AS0058 | Same intent, different detection; the AS side skips test apps differently. |
| PTE0020 (use `application` instead of an explicit Base Application dependency) | AS0085, AS0100 | AS0085 also covers System Application; AS0100 makes `application` mandatory. |

## 2a. Contradictions between the two cops

These pairs pull in opposite directions by design and are not resolved by the matrix. Both sides run at their native severity (DR-018); the project that is hit by the wrong side opts out (route A, B or C of the template's `docs/pte-or-appsource.md`).

| PerTenantExtensionCop | AppSourceCop | Conflict |
|---|---|---|
| PTE0001 (object id in 50000..99999) | AS0084 (`idRanges` inside the partner's AppSource range and outside 50000..99999) | Mutually exclusive id ranges. AS0084 is `marketplace` and starts at Recommended; PTE0001 is Error from Essential. |
| PTE0002 (field id in 50000..99999) | AS0013 (field id inside `idRanges`, outside 50000..99999) | Same conflict on fields; both Error from Essential. |
| PTE0009 (`helpBaseUrl`, `supportedLocales` not allowed) | AS0051 (marketplace manifest fields required) | A property one cop forbids, the other expects. |
| PTE0010 (extension name at most 50 characters) | AS0047 (at most 200) | Different limits; a 60-character name passes AS0047 and fails PTE0010. |
| PTE0024 (moving tables or fields not allowed) | AS0116 to AS0122, AS0141, AS0142 (validate moves) | One cop forbids what the other validates. |

## 3. Extends and complements (ALCops / Microsoft)

| ALCops | Microsoft | Kind | Scope split |
|---|---|---|---|
| PC0034 | AA0131 | extends | PC0034 checks placeholder counts only where AA0131 is silent: zero substitution arguments and `Confirm`. |
| PC0022 | AA0139 | extends | PC0022 checks possible overflow on `Validate`, `SetFilter`, `Get` and label translations, which AA0139 does not cover. |
| PC0030 | AA0242 | complements | PC0030 fires when `SetLoadFields` is absent; AA0242 fires when it is present but incomplete. |
| LC0095 | AA0137 | extends | LC0095 reports unreferenced parameters on internal and public procedures; AA0137 covers local procedures. |
| LC0099 | AA0137 | extends | LC0099 reports unreferenced parameters on event subscribers. |
| LC0092 | AA0102 | complements | LC0092 exempts API page controls so that AA0102's camelCase rule wins there. |
| AC0027 | AA0074 | complements | Both concern label and variable naming; AC0027 adds the ALCops naming conventions. |
| AC0026 | AS0138, PTE0026 | complements | AC0026 checks `AllowInCustomizations` only for fields omitted from the page; AS0138 and PTE0026 check every field. |

## 4. Contradictions

| Loser | Winner | Why | Resolution |
|---|---|---|---|
| LC0054 (use the standard `I` prefix for interface names) | AS0011, AS0098 (mandatory affixes) | An AppSource affix must be the first characters of the name, so `I` cannot be. Outside AppSource the rule is opinionated style. | LC0054 is `None` at every level (OV-05, DR-005). |

Evaluated and found not to contradict anything: LC0097 (avoid mixing `exit()` and named return assignments) and FC0007 (blank line between statement blocks). Both stay opt-in and appear at `Info` in Complete only (OV-07, DR-007). LC0089i (cognitive complexity increments) is not a contradiction but pure noise next to LC0089 and LC0090, and is `None` everywhere (OV-06, DR-006).

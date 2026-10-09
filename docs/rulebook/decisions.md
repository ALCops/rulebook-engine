# Placement decision records

Rationale for every override row and for every membership judgment that the placement algorithm cannot derive from analyzer metadata alone. A matrix row's `Basis` points at a rule row in `02-placement-algorithm.md`; the override rows point here.

Format: decision, rationale, rule rows affected. A record that no longer drives a rule row carries a **Superseded** line pointing at its successor; the record itself is never edited (same rule as `docs/adr/`). Records DR-001 to DR-017 date from 2026-09-29, DR-018 to DR-021 from the interview of 2026-10-01 that removed the target dimension (D21). The second interview of 2026-10-01 (D25 to D30) renamed the stages to `default`, `CI` and `vNext` and replaced the `L<n>` ids by the level names; records that use the old spellings carry a **Note** line and keep their meaning.

### DR-001 AS0075 and AS0099 are Hidden in the appsource target

- **Superseded** by DR-021 (2026-10-01): there is no appsource target; the adjustment applies to every project.
- **Decision:** the `AppSource` column of AS0075 (obsolete reason must be set) and AS0099 (member ID should be within the allowed range) is `Hidden` at every level.
- **Rationale:** Microsoft's own AppSource validation ruleset (`navcontainerhelper/AppHandling/appsource.default.ruleset.json`) hides both: the obsolete reason is good practice but not enforced on submission, and the ID-range info fires on enum values constrained by Dataverse integration. Following the validation ruleset means the `appsource` target reports exactly what the marketplace checks. Outside `appsource` both rules follow their decision rows.
- **Affects:** OV-01 (historical).

### DR-002 AS0089 is Warning in the appsource target

- **Superseded** by DR-021 (2026-10-01).
- **Decision:** AS0089 (removing a page customization, an entitlement or a control add-in) is `Warning` at every level in `appsource` instead of its Error default.
- **Rationale:** the same validation ruleset lowers it because AL currently offers no way to obsolete these objects; blocking a submission on something that cannot be done differently is wrong.
- **Affects:** OV-02 (historical).

### DR-003 UICop "web client does not support" rules are Warning from Essential

- **Decision:** AW0001, AW0002, AW0003, AW0004, AW0008, AW0012, AW0016 and AW0017 are `Warning` at every level in every target.
- **Rationale:** each one describes a control the web client silently drops or renders wrongly. The user never sees an error; the feature is simply missing. That is a shipping defect, so it belongs in Essential even though the author severity is Warning.
- **Affects:** OV-03.

### DR-004 LC0043 (SecretText) is Warning from Essential

- **Decision:** LC0043 is `Warning` at every level in every target.
- **Rationale:** a credential held in `Text` is visible in the debugger and in telemetry. Security findings do not wait for Recommended.
- **Affects:** OV-04.

### DR-005 LC0054 is None everywhere

- **Decision:** LC0054 (use the standard `I` prefix for interface object names) is `None` at every level in every target.
- **Rationale:** AppSourceCop's mandatory-affix rules (AS0011, AS0098) require the affix to be the first characters of every object name, so an interface cannot start with `I`. Outside AppSource the rule is a naming opinion that ALCops ships disabled. A rule that can never be satisfied in one target and is optional in the others does not belong in a shared ladder.
- **Affects:** OV-05. See `overlaps.md` section 4.

### DR-006 LC0089i is None everywhere

- **Decision:** LC0089i (cognitive complexity increment) is `None` at every level.
- **Rationale:** it emits one Info per increment inside a procedure. LC0089 (the metric) and LC0090 (the threshold) carry the same signal without the noise.
- **Affects:** OV-06.

### DR-007 LC0097 and FC0007 are Info in Complete only

- **Decision:** LC0097 (avoid mixing `exit()` and named return assignments) and FC0007 (blank line between statement blocks) are `None` up to Strict and `Info` in Complete.
- **Rationale:** both were checked for contradictions with other enabled rules and none was found, so they stay in Complete as the opt-in style rules they are. They are named here because the interview singled them out as candidates for exclusion.
- **Affects:** OV-07.

### DR-008 AS0003 and AS0091 are None outside appsource

- **Superseded** by DR-019 (2026-10-01): off at Essential, native from Recommended, for every project.
- **Decision:** AS0003 (previous version not found) and AS0091 (dependencies of the previous version not found) are `None` in `pte` and `all` and `Error` in `appsource`.
- **Rationale:** they fire when a baseline is configured but cannot be loaded. Only a marketplace submission makes the baseline mandatory; a per-tenant project that opts into breaking-change checks should not have a broken build because a cache folder is empty.
- **Affects:** OV-08 (historical).

### DR-009 The runtime whitelist

- **Decision:** family `runtime`, and with it the only `Error` in the generic ladder, contains PC0002, PC0003, PC0004, PC0007, PC0008, PC0013, PC0015, PC0018, PC0025, PC0032, AA0105, AA0106, AA0475 and AW0007.
- **Rationale:** every PlatformCop Error is by ALCops' own severity policy a definite runtime failure. Of the six CodeCop Errors, AA0105 (page part refers to parent page), AA0106 (API page refers to the same subpage twice) and AA0475 (Truncate outside its supported cases) fail at runtime; AA0251 and AA0252 (external business event obsoletion and moves) and AA0476 (AI test configuration) are design and upgrade rules and go to Warning from Recommended (D-04). AW0007 (repeater with FlowFilter fields) is the one UICop Error and the web client fails to render the page.
- **Affects:** F-03, D-04.

### DR-010 The marketplace-only set

- **Superseded** by DR-019 (2026-10-01) for the placement; the family membership stated here still holds and is maintained in `inventory/annotations.json`.
- **Decision:** family `marketplace` contains AS0011, AS0015, AS0051, AS0052, AS0054, AS0055, AS0056, AS0057, AS0079, AS0084, AS0092, AS0098, AS0150 and AS0151.
- **Rationale:** these need `mandatoryAffixes` or `supportedCountries` in `AppSourceCop.json`, an AppSource-allocated ID range, or marketplace-only manifest fields (translation file feature, EULA, privacy statement, help and Application Insights). Without that configuration they either cannot fire or report that the configuration is missing. AS0013 (field ID within `idRanges`) and AS0014 (manifest contains `idRanges`) are kept general because every app.json has ID ranges; AS0100 (`application` property) is kept general because it holds for per-tenant extensions too.
- **Affects:** F-07 (historical).

### DR-011 The PTE-only set and the twin policy

- **Superseded** by DR-018 (pte-only placement) and DR-020 (twins) on 2026-10-01; the family membership stated here still holds.
- **Decision:** family `pte-only` contains PTE0001, PTE0002, PTE0009, PTE0013, PTE0023 and PTE0024. Twin pairs (identical title in PerTenantExtensionCop and AppSourceCop) are resolved per target: `pte` activates the PTE side, `appsource` and `all` activate the AS side. The three unpaired but general rules PTE0006, PTE0007 and PTE0020 follow the decision rows in `all` and are `None` in `appsource`.
- **Rationale:** the 50000 range, the entitlement ban and the moved-table ban are facts about per-tenant extensions only. Twins fire twice when both cops are loaded, and all ten analyzers are always loaded; picking the native side per target keeps one diagnostic per finding. `all` uses the AppSourceCop side because that cop carries the fuller rule set.
- **Affects:** F-08, F-09, F-10, D-09, D-10, T-4 of the 2026-09-29 algorithm (historical). See `overlaps.md` section 2.

### DR-012 Essential enables nothing that is not a blocker

- **Note** (2026-10-01): `L1` is the Essential level; the `L<n>` ids were removed by D28. Placement unchanged.
- **Decision:** rules outside the Essential set are `None` at L1, not `Info`.
- **Rationale:** the interview asked for a bare minimum. Showing several hundred Info diagnostics in the editor is not a minimum; it is Recommended with the enforcement removed. A team that starts at Essential sees only what blocks it and grows into Recommended when the pipeline is clean.
- **Affects:** F-01, F-02, F-06, F-09, D-01, D-06 to D-09, D-12 to D-14.

### DR-013 PlatformCop is on from Essential

- **Note** (2026-10-01): `L1` is the Essential level; the `L<n>` ids were removed by D28. Placement unchanged.
- **Decision:** every default-on PlatformCop rule is active at L1: Warning defaults at Warning, Info defaults at Info.
- **Rationale:** PlatformCop reports constructs the platform rejects, ignores or executes differently from what the code says. That is the definition of "cannot ship without", regardless of the author severity.
- **Affects:** D-10, D-11.

### DR-014 AppSourceCop practice outside appsource: advisory then blocking, never Error

- **Superseded** by DR-018 (2026-10-01): without a target there is no "outside appsource"; AppSourceCop Error defaults are native blockers.
- **Decision:** in `pte` and `all`, every AppSourceCop Error or Warning default follows `None/Info/Warning/Warning`.
- **Rationale:** upgrade and extensibility rules are valid practice for everyone, but a per-tenant project controls its environment and can run an upgrade codeunit or a manual fix when a breaking change is intentional. Info at Recommended makes the practice visible; Warning at Strict makes it a gate; Error is reserved for the target where the marketplace enforces it.
- **Affects:** D-11, D-12, T-1, T-3 of the 2026-09-29 algorithm (historical).

### DR-015 Compiler Info never escalates; compiler Hidden surfaces only in Complete

- **Decision:** `INF_*` compiler diagnostics stay Info at every level; `HDN_*` are Hidden until Complete, where they are Info.
- **Rationale:** compiler infos describe the build (renamed dependency, translations included, debugging flags) rather than a defect in the code; blocking a pipeline on them makes no sense. The three Hidden codes feed editor code actions (implicit `with`, unused `using`).
- **Affects:** D-02, D-03.

### DR-016 The obsolete family and the CI relaxations

- **Note** (2026-10-01): the `cicd` stage is named `CI` (slug `ci`, file `stages/ci.json`) since D26 and D27. Placement unchanged.
- **Decision:** family `obsolete` contains AL0432, AL0801 and AL1412 (marked for removal, pending move, and the personalization variant). The `cicd` stage additionally relaxes AL0603, AL1026, AL0472, AL0473, AL0479, AL1029 and AL1030 to Info.
- **Rationale:** these are the diagnostics the interview described as "cases where you cannot solve it now": the replacement object is not released, the translation round-trip runs separately from the code change, the XML validation belongs to a report layout owned by someone else. AL0520 and AL1415 (object already obsolete) are not in the family: using a removed object breaks at runtime and stays Warning.
- **Affects:** F-05, S-2.

### DR-017 Compiler future errors are Warning from Essential and Error on vNext

- **Note** (2026-10-01): the `nextmajor` stage is named `vNext` (slug `vnext`, file `stages/vnext.json`) since D26 and D27. Placement unchanged.
- **Decision:** the 92 `WRN_ERR_*` compiler warnings are `Warning` at every level and `Error` in the `nextmajor` stage.
- **Rationale:** the compiler turns each of them into a hard error from a known runtime version. Warning from Essential gives the team the whole runway; Error on vNext shows the exact build that will break.
- **Affects:** F-04, S-3.

### DR-018 The Error defaults of both Microsoft cops are deployment blockers from Essential

- **Decision:** every PerTenantExtensionCop and AppSourceCop rule with an Error default is `Error` at every level, for every project, except the marketplace and baseline-missing checks of DR-019 and the adjustments of DR-021. Family `pte-only` (PTE0001, PTE0002, PTE0009, PTE0013, PTE0023, PTE0024) follows its native ladder at every level. The three CodeCop and UICop Error defaults that are not runtime failures keep the downgrade of DR-009 (D-04).
- **Rationale:** Rulebook no longer knows whether a project is a per-tenant extension or an AppSource app (D21). Each cop's Error defaults are the deployment blockers of one kind of extension; hiding them for the other kind was the job of the target. A project that is hit by the wrong cop's blocker (a per-tenant project on AS0084, an AppSource project on PTE0001) opts out by `suppressWarnings`, by a project ruleset rule or by disabling the cop. Breaking-change rules (family `breaking-change`, mostly Error) are silent without a configured baseline, so native severity costs nothing until a team opts into them.
- **Affects:** D-05, F-08. Supersedes DR-011 (placement) and DR-014.

### DR-019 Marketplace-only checks and baseline-missing diagnostics start at Recommended

- **Decision:** family `marketplace` (the 14 ids of DR-010) and AS0003, AS0091 are `None` at Essential and follow their native ladder from Recommended.
- **Rationale:** AS0054 ("the AppSourceCop configuration must specify affixes") and AS0051 (mandatory marketplace manifest fields) fire in every project that has no `AppSourceCop.json` or no EULA, privacy statement, help and logo. Essential must stay usable for a project without any AppSource configuration; from Recommended the project is expected either to configure or to opt out. AS0003 and AS0091 only fire when a baseline is configured but cannot be loaded, which is a broken setup worth an Error once a team has opted into breaking-change checks.
- **Affects:** F-07, OV-08. Supersedes DR-008 and the placement half of DR-010.

### DR-020 Twins are both active; the organization picks a side

- **Decision:** the 17 twin pairs of `overlaps.md` section 2 are both active at their native ladder. An organization that builds only one kind of extension sets `twins` to `appsource` or `pte` in its Rulebook settings, and the generator writes the other side at `None` in every endpoint (D23). The pairs are exported to `matrix/twins.json`. PTE0006/AS0060, PTE0007/AS0058 and PTE0020/AS0085 cover related ground but check different things (encryption-key functions versus unsafe methods, test assertions in the same area, the `application` property versus an explicit Base Application dependency) and are not twins.
- **Rationale:** with both cops enabled a twin reports twice. Dropping one side in the matrix would silently lose the check for a project that disables the other cop, which is the opt-out route Rulebook itself documents. Which side to keep is an organization-wide decision and is cheap to apply at generation time.
- **Affects:** `matrix/twins.json`, section 5 of `02-placement-algorithm.md`. Supersedes the twin policy of DR-011.

### DR-021 Microsoft's AppSource validation adjustments apply to every project

- **Decision:** AS0075 and AS0099 are `None/Hidden/Hidden/Hidden`; AS0089 is `Warning` at every level.
- **Rationale:** `navcontainerhelper/AppHandling/appsource.default.ruleset.json` is the ruleset Microsoft runs on a submission. It hides AS0075 and AS0099 (good practice, not enforced; enum values constrained by Dataverse) and lowers AS0089 because AL offers no way to obsolete the objects it reports. Without a target the only sensible reading of "native AppSource severity" is what the marketplace itself checks, so the adjustments apply everywhere. `None` instead of `Hidden` at Essential keeps DR-012.
- **Affects:** OV-01, OV-02. Supersedes DR-001 and DR-002.

### DR-022 AA0021 is Info at Recommended (throwaway, WP10 live run)

- **Decision:** AA0021 is `None/Info/Warning/Warning`.
- **Rationale:** a throwaway placement change for card (a) of the WP10 live run (#12), to prove that a placement change reaches an organization through the update; reverted on the same branch before the merge.
- **Affects:** OV-09.

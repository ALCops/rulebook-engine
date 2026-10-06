#requires -Version 7.4
<#
.SYNOPSIS
  Regenerates the generated files of template/ from docs/rulebook: base/, stages/, catalog/diagnostics.json,
  skeletons/ and rulesets/.
.DESCRIPTION
  Runs, in order, Build-RulebookBase (base/), Build-RulebookStages (stages/), Build-RulebookCatalog
  (catalog/diagnostics.json), New-RulebookSkeleton (skeletons/, from .github/Rulebook-Settings.json) and
  Update-RulebookEndpoints (rulesets/). Writes only files whose bytes differ and prints one line per change, or
  "template: current". Outputs the change objects. With -WhatIf nothing is written and the changes are still
  listed: on the committed template/ an empty list means the template is current. The hand-written files (the
  settings, overrides.json, the quarantine files, README.md and the workflows) are never touched.
  See docs/reference/template-content.md.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RulebookDir = (Join-Path $PSScriptRoot '..' '..' 'docs' 'rulebook'),
    [string]$TemplateDir = (Join-Path $PSScriptRoot '..' '..' 'template')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'modules' 'Rulebook.Generate.psd1') -Force
Import-Module (Join-Path $PSScriptRoot '..' '..' 'modules' 'Rulebook.Template.psd1') -Force
$RulebookDir = (Resolve-Path -LiteralPath $RulebookDir).ProviderPath
$TemplateDir = (Resolve-Path -LiteralPath $TemplateDir).ProviderPath

# Module functions do not see this script's preference variables, so -WhatIf is passed on explicitly.
$whatIf = [bool]$WhatIfPreference
$changes = @(
    Build-RulebookBase -RulebookDir $RulebookDir -OutputPath (Join-Path $TemplateDir 'base') -WhatIf:$whatIf
    Build-RulebookStages -RulebookDir $RulebookDir -OutputPath (Join-Path $TemplateDir 'stages') -WhatIf:$whatIf
    Build-RulebookCatalog -RulebookDir $RulebookDir -OutputPath (Join-Path $TemplateDir 'catalog' 'diagnostics.json') -WhatIf:$whatIf
    New-RulebookSkeleton -SettingsPath (Join-Path $TemplateDir '.github' 'Rulebook-Settings.json') -OutputPath (Join-Path $TemplateDir 'skeletons') -WhatIf:$whatIf
    Update-RulebookEndpoints -RepositoryRoot $TemplateDir -WhatIf:$whatIf
)

if ($changes.Count -eq 0) {
    Write-Host 'template: current'
} else {
    foreach ($change in $changes) { Write-Host "template: $($change.File) ($($change.Change))" }
}
$changes

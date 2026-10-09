#requires -Version 7.4
<#
.SYNOPSIS
  Regenerates the generated files of template/ from docs/rulebook: base/, stages/, catalog/diagnostics.json,
  skeletons/ and rulesets/, and the pages of the shipped levels in docs/levels/.
.DESCRIPTION
  Runs, in order, Build-RulebookBase (base/), Build-RulebookStages (stages/), Build-RulebookCatalog
  (catalog/diagnostics.json), New-RulebookSkeleton (skeletons/, from .github/Rulebook-Settings.json),
  Update-RulebookEndpoints (rulesets/) and New-RulebookLevelDocs (the level pages and their README.md index in
  -LevelDocsDir, default docs/levels/ of this repository: the one output outside template/, D49). Writes only files
  whose bytes differ and prints one line per change, or "template: current". Outputs the change objects. With
  -WhatIf nothing is written and the changes are still listed: on the committed template/ and docs/levels/ an empty
  list means both are current. -LevelDocsDir must be a folder of generated pages only: New-RulebookLevelDocs
  refuses a folder holding any other Markdown file. The hand-written files (the settings, overrides.json, the
  quarantine files, README.md and the workflows) are never touched. See docs/reference/template-content.md and
  docs/authoring-levels.md.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RulebookDir = (Join-Path $PSScriptRoot '..' '..' 'docs' 'rulebook'),
    [string]$TemplateDir = (Join-Path $PSScriptRoot '..' '..' 'template'),
    [string]$LevelDocsDir = (Join-Path $PSScriptRoot '..' '..' 'docs' 'levels')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'modules' 'Rulebook.Generate.psd1') -Force
Import-Module (Join-Path $PSScriptRoot '..' '..' 'modules' 'Rulebook.Template.psd1') -Force
Import-Module (Join-Path $PSScriptRoot '..' '..' 'modules' 'Rulebook.Levels.psd1') -Force
$RulebookDir = (Resolve-Path -LiteralPath $RulebookDir).ProviderPath
$TemplateDir = (Resolve-Path -LiteralPath $TemplateDir).ProviderPath
# The folder may not exist yet; New-RulebookLevelDocs creates it.
$LevelDocsDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LevelDocsDir)

# Module functions do not see this script's preference variables, so -WhatIf and -Confirm are passed on explicitly.
# A step that throws leaves the files of the earlier steps written; fix the input and run again.
$common = @{ WhatIf = [bool]$WhatIfPreference; Confirm = ($ConfirmPreference -eq 'Low') }
$changes = @(
    Build-RulebookBase -RulebookDir $RulebookDir -OutputPath (Join-Path $TemplateDir 'base') @common
    Build-RulebookStages -RulebookDir $RulebookDir -OutputPath (Join-Path $TemplateDir 'stages') @common
    Build-RulebookCatalog -RulebookDir $RulebookDir -OutputPath (Join-Path $TemplateDir 'catalog' 'diagnostics.json') @common
    New-RulebookSkeleton -SettingsPath (Join-Path $TemplateDir '.github' 'Rulebook-Settings.json') -OutputPath (Join-Path $TemplateDir 'skeletons') @common
    Update-RulebookEndpoints -RepositoryRoot $TemplateDir @common
)
$pageChanges = @(New-RulebookLevelDocs -RepositoryRoot $TemplateDir -OutputPath $LevelDocsDir -GeneratedBy 'tools/rulebook/Build-Template.ps1' @common)

if ($changes.Count + $pageChanges.Count -eq 0) {
    Write-Host 'template: current'
} else {
    foreach ($change in $changes) { Write-Host "template: $($change.File) ($($change.Change))" }
    foreach ($change in $pageChanges) { Write-Host "level pages: $($change.Path) ($($change.Change))" }
}
$changes
$pageChanges

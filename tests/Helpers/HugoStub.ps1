#requires -Version 7.4
# A stand-in for the hugo executable (WP14, #16): Build-RulebookSite and Publish.ps1 run it through -HugoPath, so the
# Pester suites need no Hugo. It takes Hugo's arguments as they are (--source <site> --destination <folder>
# --baseURL <url> ...), appends them to $env:HUGO_STUB_LOG (one line, tab-separated) when that is set, and writes into
# the destination what the shipped site writes, from <site>/data/rulebook.json: index.html with the matrix marker of the
# first stage, stages/<slug>/index.html, levels/<slug>/index.html, setup/index.html with the init command of the first
# level, rules/<id lowercased>/index.html and the four assets.
# $env:HUGO_STUB_NOMARKER set: index.html without the marker. $env:HUGO_STUB_EXIT set: prints 25 lines and exits with it.

$arguments = @($args | ForEach-Object { [string]$_ })
if (-not [string]::IsNullOrEmpty($env:HUGO_STUB_LOG)) {
    [System.IO.File]::AppendAllText($env:HUGO_STUB_LOG, ($arguments -join "`t") + "`n")
}
if (-not [string]::IsNullOrEmpty($env:HUGO_STUB_EXIT)) {
    foreach ($number in 1..25) { Write-Output "stub line $number" }
    exit ([int]$env:HUGO_STUB_EXIT)
}

function Get-ArgumentValue {
    param([string]$Name)
    $at = [array]::IndexOf($arguments, $Name)
    if ($at -lt 0 -or $at -ge $arguments.Count - 1) { throw "hugo stub: $Name is missing" }
    return $arguments[$at + 1]
}

$source = Get-ArgumentValue '--source'
$destination = Get-ArgumentValue '--destination'
$data = Get-Content -LiteralPath (Join-Path $source 'data' 'rulebook.json') -Raw | ConvertFrom-Json -AsHashtable
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-Page {
    param([string]$Path, [string]$Text)
    $file = Join-Path $destination $Path
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $file))
    [System.IO.File]::WriteAllText($file, $Text, $utf8)
}

$first = $data['stages'][0]['slug']
$marker = if ([string]::IsNullOrEmpty($env:HUGO_STUB_NOMARKER)) { " data-rulebook-matrix=`"$first`"" } else { '' }
Write-Page 'index.html' "<!DOCTYPE html>`n<section$marker>stub</section>`n"
foreach ($stage in $data['stages']) { Write-Page "stages/$($stage['slug'])/index.html" "<section data-rulebook-matrix=`"$($stage['slug'])`">stub</section>`n" }
foreach ($level in $data['levels']) { Write-Page "levels/$($level['slug'])/index.html" "<h1>$($level['name'])</h1>`n" }
Write-Page 'setup/index.html' "<h1 id=`"al-project`">Set up an AL project</h1>`n<pre><code>./Get-RulebookSkeletons.ps1 -BaseUrl $($data['baseUrl']) -Level $($data['levels'][0]['slug']) -Ref $($data['engineRef'])</code></pre>`n"
foreach ($rule in $data['rules']) { Write-Page "rules/$(([string]$rule['id']).ToLowerInvariant())/index.html" "<h1>$($rule['id'])</h1>`n" }
foreach ($asset in 'css/site.css', 'js/matrix.js', 'js/cart-core.mjs', 'js/cart.mjs') { Write-Page $asset "/* stub */`n" }
Write-Output 'Start building sites (stub)'
exit 0

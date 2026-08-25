# Publishes a web copy of today's brief to the user's own artifact URL.
# Opt-in: does nothing unless the data folder holds a publish.json like
#   { "url": "https://claude.ai/code/artifact/<id>" }
# The page published here is built from briefs\<date>.json, NOT from the app's
# own brief-app.html - that file is installed program content, shared by every
# user and read-only in a packaged install.
# Started detached by daily-brief.ps1: the morning plan is readable the moment
# the brief json lands, so nobody waits on a web copy.
# ASCII-only on purpose (PS 5.1 encoding).
param(
    [string]$Today = (Get-Date -Format 'yyyy-MM-dd')
)

& chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
$log  = Join-Path $base 'publish-run.log'
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

$cfgPath = Join-Path $base 'publish.json'
if (-not (Test-Path $cfgPath)) { exit 0 }
try {
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    [IO.File]::WriteAllText($log, '[fatal] publish.json is not valid JSON', $utf8NoBom)
    exit 2
}
$url = [string]$cfg.url
if (-not $url) { exit 0 }

$briefPath = Join-Path $base ('briefs\' + $Today + '.json')
if (-not (Test-Path $briefPath)) {
    [IO.File]::WriteAllText($log, ('[skip] no brief for ' + $Today), $utf8NoBom)
    exit 0
}
$brief = Get-Content $briefPath -Raw -Encoding UTF8 | ConvertFrom-Json

try {
    . (Join-Path $PSScriptRoot 'claude-path.ps1')   # sets $claude
} catch {
    [IO.File]::WriteAllText($log, ('[fatal] ' + $_.Exception.Message), $utf8NoBom)
    exit 3
}

# ---------- build the standalone page ----------
# Plain string building, no templating engine: the page is a handful of
# sections and every value comes from one small json.
function Esc([string]$s) {
    return ($s + '').Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine('<title>' + (Esc ([string]$brief.dateLabel)) + '</title>')
$null = $sb.AppendLine('<style>')
$null = $sb.AppendLine(':root { --bg:#0F1216; --surface:#171B22; --border:#262C36; --text:#E6E9EF; --muted:#98A2B3; --accent:#7AA2F7; --crit:#F7768E; --warn:#E0AF68; }')
$null = $sb.AppendLine('@media (prefers-color-scheme: light) { :root:not([data-theme="dark"]) { --bg:#FFFFFF; --surface:#F5F7FA; --border:#DFE3EA; --text:#1A1E26; --muted:#5A6472; } }')
$null = $sb.AppendLine(':root[data-theme="dark"] { --bg:#0F1216; --surface:#171B22; --border:#262C36; --text:#E6E9EF; --muted:#98A2B3; }')
$null = $sb.AppendLine('body { background: var(--bg); color: var(--text); font: 15px/1.55 system-ui, "Segoe UI", sans-serif; margin: 0 auto; max-width: 46rem; padding: 2rem 1.2rem 4rem; }')
$null = $sb.AppendLine('h1 { font-size: 1.5rem; margin: 0 0 0.2rem; } .sub { color: var(--muted); font-size: 0.9rem; margin-bottom: 1.4rem; }')
$null = $sb.AppendLine('h2 { font-size: 1rem; letter-spacing: 0.04em; text-transform: uppercase; color: var(--muted); margin: 2rem 0 0.6rem; }')
$null = $sb.AppendLine('.card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 0.8rem 0.9rem; margin-bottom: 0.6rem; }')
$null = $sb.AppendLine('.card h3 { margin: 0 0 0.3rem; font-size: 0.98rem; } .card p { margin: 0; color: var(--muted); font-size: 0.9rem; }')
$null = $sb.AppendLine('.badge { float: right; font-size: 0.76rem; color: var(--accent); border: 1px solid var(--border); border-radius: 999px; padding: 0.05rem 0.5rem; }')
$null = $sb.AppendLine('.w-crit { border-left: 3px solid var(--crit); } .w-warn { border-left: 3px solid var(--warn); } .w-note { border-left: 3px solid var(--border); }')
$null = $sb.AppendLine('ul { padding-left: 1.1rem; } li { margin-bottom: 0.3rem; }')
$null = $sb.AppendLine('</style>')
$null = $sb.AppendLine('<h1>' + (Esc ([string]$brief.dateLabel)) + '</h1>')
$null = $sb.AppendLine('<div class="sub">' + (Esc ([string]$brief.date)) + '</div>')
if ($brief.tldr) { $null = $sb.AppendLine('<p>' + (Esc ([string]$brief.tldr)) + '</p>') }

if (@($brief.tasks).Count -gt 0) {
    $null = $sb.AppendLine('<h2>tasks</h2>')
    foreach ($t in @($brief.tasks)) {
        $null = $sb.AppendLine('<div class="card">')
        if ($t.badge) { $null = $sb.AppendLine('<span class="badge">' + (Esc ([string]$t.badge)) + '</span>') }
        $null = $sb.AppendLine('<h3>' + (Esc ([string]$t.title)) + '</h3>')
        $null = $sb.AppendLine('<p>' + (Esc ([string]$t.desc)) + '</p>')
        $null = $sb.AppendLine('</div>')
    }
}

if (@($brief.warnings).Count -gt 0) {
    $null = $sb.AppendLine('<h2>warnings</h2>')
    foreach ($w in @($brief.warnings)) {
        $sev = [string]$w.sev
        if ($sev -ne 'crit' -and $sev -ne 'warn') { $sev = 'note' }
        $null = $sb.AppendLine('<div class="card w-' + $sev + '">')
        $null = $sb.AppendLine('<h3>' + (Esc ([string]$w.label)) + '</h3>')
        $null = $sb.AppendLine('<p>' + (Esc ([string]$w.text)) + '</p>')
        $null = $sb.AppendLine('</div>')
    }
}

foreach ($pair in @(@('recap', $brief.recap), @('assessment', $brief.assessment))) {
    $items = @($pair[1])
    if ($items.Count -eq 0) { continue }
    $null = $sb.AppendLine('<h2>' + $pair[0] + '</h2><ul>')
    foreach ($line in $items) { $null = $sb.AppendLine('<li>' + (Esc ([string]$line)) + '</li>') }
    $null = $sb.AppendLine('</ul>')
}

$pagePath = Join-Path $base ('publish-' + $Today + '.html')
[IO.File]::WriteAllText($pagePath, $sb.ToString(), $utf8NoBom)

# ---------- publish ----------
$prompt = (Get-Content (Join-Path $app 'prompt-publish.md') -Raw -Encoding UTF8).
    Replace('{{FILE}}', $pagePath).
    Replace('{{URL}}', $url)

Set-Location $base
$ErrorActionPreference = 'Continue'
# Only the Artifact tool, 3 turns max - the cheapest run in the app.
$claudeArgs = @(
    '-p',
    '--model', 'haiku',
    '--allowedTools', 'Artifact',
    '--add-dir', $base,
    '--allow-dangerously-skip-permissions',
    '--dangerously-skip-permissions',
    '--max-turns', '3',
    '--output-format', 'json'
)
$prompt | & $claude @claudeArgs 2>&1 | Out-File $log -Encoding utf8

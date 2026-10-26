# Publishes a web copy of today's brief to ONE private Claude Doc on claude.ai,
# replaced every morning.
# Opt-in: does nothing unless the data folder holds a publish.json. Its "doc"
# key is the doc's link (or id); without one (a fresh config, or a legacy
# { "url": <artifact> } one) the run creates the doc and this script writes
# its link back into publish.json, keeping every other key, so the next run
# updates the same doc instead of making a second one.
# The text is built here from briefs\<date>.json, deterministically. The model
# authors nothing: it only carries this markdown into the doc through the
# claude.ai Claude Docs connector (the Artifact tool does not exist in a
# headless CLI session, which is why publishing never worked before).
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
    $cfg = ([string](Get-Content $cfgPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
} catch {
    [IO.File]::WriteAllText($log, '[fatal] publish.json is not valid JSON', $utf8NoBom)
    exit 2
}
if (-not $cfg) { $cfg = New-Object PSObject }
$doc  = if ($cfg.PSObject.Properties['doc']) { [string]$cfg.doc } else { '' }
$body = if ($cfg.PSObject.Properties['docBody']) { [string]$cfg.docBody } else { '' }

$briefPath = Join-Path $base ('briefs\' + $Today + '.json')
if (-not (Test-Path $briefPath)) {
    [IO.File]::WriteAllText($log, ('[skip] no brief for ' + $Today), $utf8NoBom)
    exit 0
}
$brief = Get-Content $briefPath -Raw -Encoding UTF8 | ConvertFrom-Json

try {
    . (Join-Path $PSScriptRoot 'claude-path.ps1')   # sets $claude
    . (Join-Path $PSScriptRoot 'claude-run.ps1')    # Invoke-ClaudeLean
} catch {
    [IO.File]::WriteAllText($log, ('[fatal] ' + $_.Exception.Message), $utf8NoBom)
    exit 3
}

# ---------- build the markdown ----------
function AsArr($v) {
    if ($null -eq $v) { return @() }
    if ($v -is [array]) { return $v }
    if ($v -is [string]) { return @($v) }
    if ($v -is [PSCustomObject] -and @($v.PSObject.Properties).Count -eq 0) { return @() }
    return @($v)
}
# One line per item, and no Claude Docs chip tokens: the doc would try to
# resolve "<?claude block ...?>" as a chip that was never declared.
function Line([string]$s) { return (($s + '') -replace '\s*[\r\n]+\s*', ' ' -replace '<\?claude', '<?').Trim() }

$sb = New-Object System.Text.StringBuilder
$label = Line ([string]$brief.dateLabel)
if (-not $label) { $label = $Today }
$null = $sb.AppendLine('# Daily Brief - ' + $label)
$null = $sb.AppendLine('')
$null = $sb.AppendLine(('Updated {0} for {1}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $Today))
if ($brief.tldr) { $null = $sb.AppendLine(''); $null = $sb.AppendLine((Line ([string]$brief.tldr))) }
$tasks = @(AsArr $brief.tasks)
if ($tasks.Count) {
    $null = $sb.AppendLine(''); $null = $sb.AppendLine('## Today')
    $null = $sb.AppendLine('')
    foreach ($t in $tasks) {
        $badge = if ($t.badge) { ' (' + (Line ([string]$t.badge)) + ')' } elseif ($t.weight) { ' (' + [string]$t.weight + '%)' } else { '' }
        $null = $sb.AppendLine('- **' + (Line ([string]$t.title)) + '**' + $badge + ' - ' + (Line ([string]$t.desc)))
    }
}
$warns = @(AsArr $brief.warnings)
if ($warns.Count) {
    $null = $sb.AppendLine(''); $null = $sb.AppendLine('## Warnings')
    $null = $sb.AppendLine('')
    foreach ($w in $warns) {
        $lbl = Line ([string]$w.label)
        if (-not $lbl) { $lbl = [string]$w.sev }
        $null = $sb.AppendLine('- **' + $lbl + '** (' + [string]$w.sev + '): ' + (Line ([string]$w.text)))
    }
}
$recap = @(AsArr $brief.recap)
if ($recap.Count) {
    $null = $sb.AppendLine(''); $null = $sb.AppendLine('## Recap')
    $null = $sb.AppendLine('')
    foreach ($r in $recap) { $null = $sb.AppendLine('- ' + (Line ([string]$r))) }
}
$ass = @(AsArr $brief.assessment)
if ($ass.Count) {
    $null = $sb.AppendLine(''); $null = $sb.AppendLine('## Is this the right road?')
    foreach ($a in $ass) { $null = $sb.AppendLine(''); $null = $sb.AppendLine((Line ([string]$a))) }
}
$md = $sb.ToString().TrimEnd().Replace("`r`n", "`n")
[IO.File]::WriteAllText((Join-Path $base ('publish-' + $Today + '.md')), $md, $utf8NoBom)

# ---------- publish ----------
# The tool arguments are serialized here, not by the model: a small model
# re-escaping a page of markdown into JSON is where text gets mangled.
$contentJson = ConvertTo-Json $md -Compress
$createArgs = (@{ kind = 'project'; create = @{ name = 'Daily Brief'; doc = @{ markdown = $md } } } | ConvertTo-Json -Depth 6 -Compress)

$raw = [string](Get-Content (Join-Path $app 'prompt-publish.md') -Raw -Encoding UTF8)
$mode = if ($doc) { 'update' } else { 'create' }
# The prompt file holds both procedures; only the one this run needs is sent.
$section = ([regex]::Match($raw, '(?s)<!-- ' + $mode + ' -->(.*?)(<!-- \w+ -->|$)')).Groups[1].Value
$common = ([regex]::Match($raw, '(?s)^(.*?)<!-- ')).Groups[1].Value
$prompt = ($common + $section).
    Replace('{{DOC}}', $doc).
    Replace('{{BODY}}', $body).
    Replace('{{CREATE_CONTAINER}}', $createArgs).
    Replace('{{CONTENT_JSON}}', $contentJson)

Set-Location $base
# Fresh log per publish: Invoke-ClaudeLean appends, and the app reads the last
# CLI envelope in this file.
[IO.File]::WriteAllText($log, ('publish ' + $Today + ' (' + $mode + ')' + "`n"), $utf8NoBom)
# Only the Claude Docs tools the procedure uses. -ClaudeAiConnectors keeps
# the claude.ai connectors (default MCP loading) but still no hooks or user
# settings, so the run sees no personal style instructions.
$schema = '{"type":"object","additionalProperties":false,"properties":{"published":{"type":"boolean"},"doc":{"type":"string"},"body":{"type":"string"},"notices":{"type":"string"}},"required":["published","doc"]}'
$system = 'You copy a prepared document into a Claude Doc with the Claude Docs tools, exactly as instructed, and report the result. You never write or change the document text yourself.'
$lean = @{
    Prompt = $prompt; Log = $log; System = $system; Model = 'haiku'; Schema = $schema
    Tools = 'mcp__claude_ai_Claude_Docs__batch,mcp__claude_ai_Claude_Docs__read,mcp__claude_ai_Claude_Docs__update'
    MaxTurns = 8; ClaudeAiConnectors = $true
}
$res = Invoke-ClaudeLean @lean
if (-not $res.ok) {
    Add-Content $log ('[warn] publish failed: ' + $res.error)
    exit 0
}
if (-not $res.data.published) {
    Add-Content $log '[warn] publish failed: the model reported the doc as not updated'
}

# A created doc is remembered, or tomorrow's run would create a second one.
# Every other key in publish.json is kept as the user wrote it.
$newDoc = ([string]$res.data.doc).Trim()
$newBody = ([string]$res.data.body).Trim()
# Only an id may land in publish.json: the model once wrote its whole
# explanation into body, which then broke every later update.
if ($newBody -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{3,63}$') {
    if ($newBody) { Add-Content $log '[warn] model returned a body id that is not an id - ignored' }
    $newBody = ''
}
if ($res.data.PSObject.Properties['notices'] -and ([string]$res.data.notices).Trim()) {
    # dropped_with = the old blocks this run deleted on purpose: expected, not a failure.
    Add-Content $log ('[info] doc update notices: ' + ([string]$res.data.notices).Trim())
}
if ($newDoc -and (($newDoc -ne $doc) -or ($newBody -and $newBody -ne $body))) {
    if ($cfg.PSObject.Properties['doc']) { $cfg.doc = $newDoc }
    else { $cfg | Add-Member -NotePropertyName doc -NotePropertyValue $newDoc }
    if ($newBody) {
        if ($cfg.PSObject.Properties['docBody']) { $cfg.docBody = $newBody }
        else { $cfg | Add-Member -NotePropertyName docBody -NotePropertyValue $newBody }
    }
    [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 6), $utf8NoBom)
    Add-Content $log ('[info] publish.json now points at ' + $newDoc)
} elseif ($mode -eq 'create') {
    Add-Content $log '[warn] doc created but no link came back - publish.json unchanged'
}

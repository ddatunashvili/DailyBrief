# Daily briefing generator: runs Claude Code headless, writes today's briefing, opens it.
# Launched by the Electron shell (with -NoShow) or standalone. ASCII-only on purpose (PS 5.1 encoding).
param(
    [switch]$NoShow,
    # Replan: throw away today's briefing and regenerate it. Claude sees
    # done\<today>.json (checked-off tasks) and plans the remaining day.
    [switch]$Force
)

# Force real UTF-8 as early as possible, before anything else runs, so no
# child process in the claude.cmd -> node chain can inherit a stale codepage.
& chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
$today  = Get-Date -Format 'yyyy-MM-dd'
$brief  = Join-Path $base "briefings\$today.md"
$log    = Join-Path $base 'last-run.log'
try {
    . (Join-Path $PSScriptRoot 'claude-path.ps1')   # sets $claude
} catch {
    # No working claude CLI: leave a log, or the app journals a run that never
    # happened as a success.
    [IO.File]::WriteAllText($log, ('[fatal] ' + $_.Exception.Message), (New-Object Text.UTF8Encoding $false))
    exit 3
}

function Show-Brief([string]$Path) {
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA',
        '-File', (Join-Path $app 'show-brief.ps1'), '-Path', "`"$Path`""
    )
}

# Already generated today (e.g. second logon): nothing to do unless replanning.
if (Test-Path $brief) {
    if ($Force) {
        Remove-Item $brief -Force
    } else {
        # Nothing to do today. Written down on purpose: an early exit that
        # left last-run.log untouched made the app re-journal the PREVIOUS
        # run's tokens and cost as a brand new successful run.
        [IO.File]::WriteAllText($log, 'skipped: brief for today already exists - zero AI tokens spent', (New-Object Text.UTF8Encoding $false))
        if (-not $NoShow) { Show-Brief $brief }
        exit 0
    }
}

# One digest in, one json out. The model used to open the registry, the board,
# the snapshots and yesterday's brief one Read at a time and then write five
# files - eleven round trips for work the scripts can do in half a second.
$digestPath = Join-Path $base ("brief-digest-$today.json")
$outPath    = Join-Path $base ("brief-out-$today.json")
if (Test-Path $outPath) { Remove-Item $outPath -Force }

# A replan doesn't need fresh activity data - the snapshots are a morning job.
if (-not $Force) {
    # Snapshot watched folders (dirs.txt) so Claude can diff against previous days
    # and measure real progress without any manual logging.
    $snapDir = Join-Path $base 'snapshots'
    New-Item -ItemType Directory -Force $snapDir | Out-Null
    $snap = Join-Path $snapDir "$today.txt"
    # Directory-level stats only - no file names, no file contents (privacy by design).
    Get-Content (Join-Path $base 'dirs.txt') -Encoding UTF8 |
        Where-Object { $_.Trim() -and (Test-Path $_.Trim()) } |
        ForEach-Object { Get-ChildItem $_.Trim() -Recurse -File -ErrorAction SilentlyContinue } |
        Group-Object DirectoryName |
        ForEach-Object {
            $latest = ($_.Group | Measure-Object LastWriteTime -Maximum).Maximum
            $bytes  = ($_.Group | Measure-Object Length -Sum).Sum
            '{0:yyyy-MM-dd HH:mm}  {1,5} files  {2,14:N0} B  {3}' -f $latest, $_.Count, $bytes, $_.Name
        } |
        Sort-Object -Descending |
        Out-File $snap -Encoding utf8
    # Top active directories. Scored from the project registry (which the app
    # refreshes every 30 minutes), not from a fresh recursive scan of every
    # work root - that scan alone took four minutes of the morning run.
    $topFile = Join-Path $base 'top-dirs.txt'
    & (Join-Path $app 'discover-dirs.ps1') -OutFile $topFile -Top 10
    if (Test-Path $topFile) {
        Copy-Item $topFile (Join-Path $snapDir "activity-$today.txt") -Force
    }

    # Keep two weeks of each snapshot series (file snapshots and activity lists).
    Get-ChildItem $snapDir -File |
        Group-Object { $_.Name -replace '\d{4}-\d{2}-\d{2}', '' } |
        ForEach-Object { $_.Group | Sort-Object Name -Descending | Select-Object -Skip 14 | Remove-Item -Force }
}

$digestArgs = @{ Out = $digestPath; Today = $today }
if ($Force) { $digestArgs['Replan'] = $true }
& (Join-Path $app 'brief-digest.ps1') @digestArgs | Out-File $log -Encoding utf8

$promptFile = if ($Force) { 'prompt-replan.md' } else { 'prompt.md' }
# The exact per-run file names go INTO the prompt: left to guess, the model
# spends turns listing the folder and can write where nothing looks for it.
$prompt = (Get-Content (Join-Path $app $promptFile) -Raw -Encoding UTF8).
    Replace('{{DATA}}', $base).
    Replace('{{TODAY}}', $today).
    Replace('{{DIGEST}}', ("brief-digest-$today.json")).
    Replace('{{OUT}}', ("brief-out-$today.json"))

Set-Location $base
# Continue, not Stop: PS 5.1 turns native stderr lines into ErrorRecords that would abort the run.
# Args as an array, not backtick continuations - a stray space after a backtick silently drops flags.
$ErrorActionPreference = 'Continue'
# One read and one write is the whole job now, so the turn budget that used to
# absorb eleven tool calls is a ceiling, not a plan.
$maxTurns = if ($Force) { '5' } else { '8' }
# No --add-dir: the model only ever touches the two files above, both in cwd.
# --dangerously-skip-permissions: headless run, no one to answer prompts.
# Prompt goes via stdin: it contains quotes that PS 5.1 mangles as an argument,
# which silently breaks every flag after it.
# sonnet for the daily brief and replans: language quality matters here.
# --effort low: the judgment is in the digest and the rules, not in the
# deliberation. At the default effort the run spent six thousand tokens
# thinking - most of the morning's wall clock - to reach the same plan.
$claudeArgs = @(
    '-p',
    '--model', 'sonnet',
    '--effort', 'low',
    '--allowedTools', 'Read,Write',
    '--allow-dangerously-skip-permissions',
    '--dangerously-skip-permissions',
    '--max-turns', $maxTurns,
    '--output-format', 'json'
)
$prompt | & $claude @claudeArgs 2>&1 | Out-File $log -Encoding utf8 -Append
$ErrorActionPreference = 'Stop'

# Every file the run produces is written here, from that one json.
& (Join-Path $app 'brief-apply.ps1') -In $outPath -Today $today 2>&1 |
    ForEach-Object { Add-Content $log ([string]$_) }

Add-Content $log ('[timing] total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)

# Today's brief lives in briefs\<date>.json and the app reads it from there
# over IPC. The page itself is installed program content - shared by every
# user on the machine, read-only inside the packaged asar - so the run must
# never write into it. Validate the JSON here instead: a broken file is worth
# a log line now rather than an empty page at 8am.
$briefReady = $false
$briefJsonPath = Join-Path $base ('briefs\' + $today + '.json')
try {
    if (Test-Path $briefJsonPath) {
        $null = (Get-Content $briefJsonPath -Raw -Encoding UTF8).Trim() | ConvertFrom-Json
        $briefReady = $true
    } else {
        Add-Content $log '[warn] briefs json for today not found; app has nothing new to show'
    }
} catch {
    Add-Content $log ('[warn] briefs json for today is not valid JSON: ' + $_.Exception.Message)
}

# Optional follow-up run: publish a web copy of today's brief. Off unless this
# user dropped a publish.json in their data folder (it holds their own artifact
# URL), because publishing is personal - one account, one link.
if ($briefReady -and (Test-Path (Join-Path $base 'publish.json'))) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (Join-Path $app 'publish-page.ps1'), '-Today', $today
    )
}

if (Test-Path $brief) {
    if (-not $NoShow) { Show-Brief $brief }
} else {
    # Claude failed to produce the briefing. Surface the log only when running
    # standalone - in app mode (-NoShow) the app is the only UI, no popups.
    if (-not $NoShow) { Show-Brief $log }
}

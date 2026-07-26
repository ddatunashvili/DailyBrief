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
$base   = 'C:\Users\davit\OneDrive\Desktop\DailyBriefApp\core'
$today  = Get-Date -Format 'yyyy-MM-dd'
$brief  = Join-Path $base "briefings\$today.md"
$log    = Join-Path $base 'last-run.log'
$claude = 'C:\Users\davit\AppData\Roaming\nvm\v22.22.3\claude.cmd'

function Show-Brief([string]$Path) {
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA',
        '-File', (Join-Path $base 'show-brief.ps1'), '-Path', "`"$Path`""
    )
}

# Already generated today (e.g. second logon): nothing to do unless replanning.
if (Test-Path $brief) {
    if ($Force) {
        Remove-Item $brief -Force
    } else {
        if (-not $NoShow) { Show-Brief $brief }
        exit 0
    }
}

# Replan uses a slim prompt: no snapshots, no history, fewer files, fewer turns.
$promptFile = if ($Force) { 'prompt-replan.md' } else { 'prompt.md' }
$prompt = (Get-Content (Join-Path $base $promptFile) -Raw -Encoding UTF8).Replace('{{TODAY}}', $today)

# Snapshots and activity discovery recurse whole work roots - slow. A replan
# doesn't need fresh activity data, so only the full morning run does this.
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
    # Discover the top 20 most actively used directories (Recent items + fresh edits)
    # and keep a dated copy so Claude can track where time actually goes day to day.
    $topFile = Join-Path $base 'top-dirs.txt'
    & (Join-Path $base 'discover-dirs.ps1') -OutFile $topFile -Top 10
    if (Test-Path $topFile) {
        Copy-Item $topFile (Join-Path $snapDir "activity-$today.txt") -Force
    }

    # Keep two weeks of each snapshot series (file snapshots and activity lists).
    Get-ChildItem $snapDir -File |
        Group-Object { $_.Name -replace '\d{4}-\d{2}-\d{2}', '' } |
        ForEach-Object { $_.Group | Sort-Object Name -Descending | Select-Object -Skip 14 | Remove-Item -Force }
}

Set-Location $base
# Continue, not Stop: PS 5.1 turns native stderr lines into ErrorRecords that would abort the run.
# Args as an array, not backtick continuations - a stray space after a backtick silently drops flags.
$ErrorActionPreference = 'Continue'
# No --add-dir: Claude only sees the DailyBrief folder (directory stats),
# never the user's actual files.
$maxTurns = if ($Force) { '12' } else { '22' }
# --add-dir: brief-app.html lives one level above core (the cwd).
# --dangerously-skip-permissions: headless run, no one to answer prompts;
# the prompt files strictly limit what may be written.
# Prompt goes via stdin: it contains quotes that PS 5.1 mangles as an argument,
# which silently breaks every flag after it.
# sonnet for the daily brief and replans: language quality matters here.
# The mechanical flows (checks, publish) stay on haiku - cheapest/fastest.
$claudeArgs = @(
    '-p',
    '--model', 'sonnet',
    '--allowedTools', 'Read,Write,Edit,Glob,Grep',
    '--add-dir', 'C:\Users\davit\OneDrive\Desktop\DailyBriefApp',
    '--allow-dangerously-skip-permissions',
    '--dangerously-skip-permissions',
    '--max-turns', $maxTurns,
    '--output-format', 'json'
)
$prompt | & $claude @claudeArgs 2>&1 | Out-File $log -Encoding utf8
$ErrorActionPreference = 'Stop'

Add-Content $log ('[timing] total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)

# Inject today's brief JSON (written by Claude, small file) into the app
# page's BRIEF block. Claude never reads the big HTML - the script splices,
# which is the main token saver of the daily run.
$injected = $false
try {
    $appPage = 'C:\Users\davit\OneDrive\Desktop\DailyBriefApp\brief-app.html'
    $briefJsonPath = Join-Path $base ('briefs\' + $today + '.json')
    if (Test-Path $briefJsonPath) {
        $json = (Get-Content $briefJsonPath -Raw -Encoding UTF8).Trim()
        $null = $json | ConvertFrom-Json   # validate before touching the page
        $html = Get-Content $appPage -Raw -Encoding UTF8
        $pattern = '/\*BRIEF-DATA-START\*/[\s\S]*?/\*BRIEF-DATA-END\*/'
        $replacement = "/*BRIEF-DATA-START*/`nconst BRIEF = " + $json + ";`n/*BRIEF-DATA-END*/"
        # Scriptblock evaluator: replacement text must be literal ($ in JSON is not a group ref).
        $newHtml = [regex]::Replace($html, $pattern, { param($m) $replacement })
        [IO.File]::WriteAllText($appPage, $newHtml, (New-Object Text.UTF8Encoding $false))
        $injected = $true
    } else {
        Add-Content $log '[warn] briefs json for today not found; app page not updated'
    }
} catch {
    Add-Content $log ('[warn] BRIEF injection failed: ' + $_.Exception.Message)
}

# Tiny follow-up run: publish the updated page to the fixed artifact URL.
# Only the Artifact tool, 3 turns max - costs almost nothing.
if ($injected) {
    $pubPrompt = Get-Content (Join-Path $base 'prompt-publish.md') -Raw -Encoding UTF8
    $ErrorActionPreference = 'Continue'
    $pubArgs = @(
        '-p',
        '--model', 'haiku',
        '--allowedTools', 'Artifact',
        '--add-dir', 'C:\Users\davit\OneDrive\Desktop\DailyBriefApp',
        '--allow-dangerously-skip-permissions',
        '--dangerously-skip-permissions',
        '--max-turns', '3',
        '--output-format', 'json'
    )
    $pubPrompt | & $claude @pubArgs 2>&1 | Out-File $log -Encoding utf8 -Append
    $ErrorActionPreference = 'Stop'
}

if (Test-Path $brief) {
    if (-not $NoShow) { Show-Brief $brief }
} else {
    # Claude failed to produce the briefing. Surface the log only when running
    # standalone - in app mode (-NoShow) the app is the only UI, no popups.
    if (-not $NoShow) { Show-Brief $log }
}

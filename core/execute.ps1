# The one run that writes code in a REAL project instead of the board.
# Everything else in this app reads a digest and returns a patch; this one
# gets Bash and Edit inside the task's linked folder. Two guards make that
# safe enough to leave running unattended:
#   1. it refuses any folder that is not a git repo - without git there is no
#      way back
#   2. it works on its own branch, dailybrief/<taskid>, so "git checkout -"
#      undoes everything, including whatever was already uncommitted
# It never commits and never pushes: the diff is left in the working tree and
# VS Code (opened before the model starts) shows it live in Source Control.
# ASCII-only on purpose (PS 5.1 encoding).
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$RunId = ''
)

& chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$base   = 'C:\Users\davit\OneDrive\Desktop\DailyBriefApp\core'
. (Join-Path $PSScriptRoot 'claude-path.ps1')   # sets $claude
$now = Get-Date -Format 'yyyy-MM-dd HH:mm'
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

$runToken  = if ($RunId) { $RunId } else { [guid]::NewGuid().ToString('N').Substring(0, 8) }
$log       = Join-Path $base ("execute-run-$runToken.log")
$outPath   = Join-Path $base ("execute-out-$runToken.json")
$kanbanPath = Join-Path $base 'kanban.json'
if (Test-Path $outPath) { Remove-Item $outPath -Force }

# git talks on stderr even when it succeeds ("Switched to a new branch"), and
# under ErrorActionPreference=Stop PowerShell turns that into a terminating
# NativeCommandError - the run died right after creating its branch. Every git
# call goes through here: stderr is captured as plain text, never as an error.
function Git-Quiet([string[]]$gitArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git @gitArgs 2>&1 | ForEach-Object { [string]$_ }
        return (($out -join "`n")).Trim()
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Git-Lines([string[]]$gitArgs) {
    $text = Git-Quiet $gitArgs
    if (-not $text) { return @() }
    return @($text -split "`r?`n" | Where-Object { $_.Trim() })
}

function AsArr($v) {
    if ($null -eq $v) { return @() }
    if ($v -is [array]) { return $v }
    if ($v -is [string]) { return @($v) }
    if ($v -is [PSCustomObject] -and @($v.PSObject.Properties).Count -eq 0) { return @() }
    return @($v)
}

# Every early exit still has to land in the task's comment thread, or the user
# is left staring at a card that says nothing happened for no stated reason.
function Post-Note([string]$text, [string]$noteOnly) {
    $mutex = New-Object System.Threading.Mutex($false, 'DailyBriefKanbanWrite')
    $got = $false
    try {
        $got = $mutex.WaitOne(30000)
        $fresh = ([string](Get-Content $kanbanPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $t = $fresh.tasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
        if (-not $t) { return }
        if ($text) {
            $cs = @()
            if ($t.PSObject.Properties['comments'] -and $t.comments) { $cs = @($t.comments) }
            $cs += (New-Object PSObject -Property @{ by = 'ai'; text = $text; at = $stamp; state = 'applied' })
            if ($t.PSObject.Properties['comments']) { $t.comments = $cs } else { $t | Add-Member -NotePropertyName comments -NotePropertyValue $cs }
        }
        if ($noteOnly) {
            $ns = @()
            if ($t.PSObject.Properties['aiNotes'] -and $t.aiNotes) { $ns = @($t.aiNotes) }
            $ns += (New-Object PSObject -Property @{ text = $noteOnly; at = $now })
            if ($ns.Count -gt 10) { $ns = @($ns | Select-Object -Last 10) }
            if ($t.PSObject.Properties['aiNotes']) { $t.aiNotes = $ns } else { $t | Add-Member -NotePropertyName aiNotes -NotePropertyValue $ns }
        }
        $t.updatedAt = $stamp
        [IO.File]::WriteAllText($kanbanPath, ($fresh | ConvertTo-Json -Depth 10), $utf8NoBom)
    } catch {
        Add-Content $log ('[warn] note failed: ' + $_.Exception.Message)
    } finally {
        if ($got) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Georgian UI strings live in a UTF-8 JSON file: this script stays ASCII so
# PS 5.1 (which reads a BOM-less .ps1 as ANSI) can never mangle them.
$STR = @{
    noTask    = 'task not found'
    noDir     = 'no folder linked - nothing to work in'
    noGit     = 'not a git repo - refusing to edit without an undo path'
    branchNo  = 'could not switch to branch'
    noSummary = 'run finished without a summary - check the diff'
    noteHead  = 'executed'
    noteFiles = 'dirty files'
}
$strPath = Join-Path $base 'strings-execute.json'
if (Test-Path $strPath) {
    try {
        $sj = ([string](Get-Content $strPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        foreach ($k in @($sj.PSObject.Properties.Name)) { $STR[$k] = [string]$sj.$k }
    } catch {}
}

# ---------- the task ----------
$kanban = ([string](Get-Content $kanbanPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
$task = $kanban.tasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
if (-not $task) {
    [IO.File]::WriteAllText($log, 'skipped: task not found - zero AI tokens spent', $utf8NoBom)
    exit 0
}

$dirs = @(AsArr $task.dirs | Where-Object { $_ })
$dir = if ($dirs.Count -gt 0) { [string]$dirs[0] } else { '' }
if (-not $dir -or -not (Test-Path $dir)) {
    [IO.File]::WriteAllText($log, 'skipped: no linked folder - zero AI tokens spent', $utf8NoBom)
    Post-Note $STR.noDir ''
    exit 0
}

# ---------- guard 1: git, or there is no undo ----------
$isGit = (Git-Quiet @('-C', $dir, 'rev-parse', '--is-inside-work-tree')) -eq 'true'
if (-not $isGit) {
    [IO.File]::WriteAllText($log, 'skipped: not a git repo - refusing to edit without an undo path', $utf8NoBom)
    Post-Note $STR.noGit ''
    exit 0
}

# ---------- guard 2: a branch of its own ----------
# Uncommitted work travels with the checkout, which is what we want: the user
# keeps their changes and can drop everything the model did with one checkout.
$startBranch = Git-Quiet @('-C', $dir, 'rev-parse', '--abbrev-ref', 'HEAD')
$branch = 'dailybrief/' + $TaskId
$exists = Git-Quiet @('-C', $dir, 'rev-parse', '--verify', '--quiet', $branch)
if ($exists) { $null = Git-Quiet @('-C', $dir, 'checkout', $branch) }
else { $null = Git-Quiet @('-C', $dir, 'checkout', '-b', $branch) }
$nowBranch = Git-Quiet @('-C', $dir, 'rev-parse', '--abbrev-ref', 'HEAD')
if ($nowBranch -ne $branch) {
    [IO.File]::WriteAllText($log, ('skipped: could not switch to {0} (still on {1})' -f $branch, $nowBranch), $utf8NoBom)
    Post-Note ($STR.branchNo + ' ' + $branch) ''
    exit 0
}

$dirtyBefore = @(Git-Lines @('-C', $dir, 'status', '--porcelain')).Count

# ---------- VS Code first, so the user watches it happen ----------
$codeExe = ''
$cmd = Get-Command 'code.cmd' -ErrorAction SilentlyContinue
if ($cmd) { $codeExe = $cmd.Source }
if (-not $codeExe) {
    $guess = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
    if (Test-Path $guess) { $codeExe = $guess }
}
if ($codeExe) {
    try { Start-Process -FilePath $codeExe -ArgumentList @('--reuse-window', $dir) -WindowStyle Hidden }
    catch { Add-Content $log ('[warn] VS Code did not open: ' + $_.Exception.Message) }
} else {
    Add-Content $log '[warn] code.cmd not found - working without an editor window'
}

# ---------- the brief the model works from ----------
$subtasks = @()
if ($task.PSObject.Properties['subtasks'] -and $task.subtasks) {
    $subtasks = @($task.subtasks | Select-Object -First 20 | ForEach-Object {
        '{0} {1}' -f $(if ($_.done) { '[x]' } else { '[ ]' }), [string]$_.text
    })
}
$comments = @()
if ($task.PSObject.Properties['comments'] -and $task.comments) {
    $comments = @($task.comments | Select-Object -Last 6 | ForEach-Object {
        '{0}: {1}' -f [string]$_.by, [string]$_.text
    })
}

$briefLines = @(
    ('TASK: ' + [string]$task.title),
    ('DESC: ' + [string]$task.desc),
    ('DIR: ' + $dir),
    ('BRANCH: ' + $branch + ' (started from ' + $startBranch + ')'),
    'CHECKLIST:'
) + @($subtasks | ForEach-Object { '  ' + $_ }) + @('COMMENTS:') + @($comments | ForEach-Object { '  ' + $_ })
$briefText = ($briefLines -join "`r`n")

$prompt = (Get-Content (Join-Path $base 'prompt-execute.md') -Raw -Encoding UTF8).
    Replace('{{NOW}}', $now).
    Replace('{{BRIEF}}', $briefText).
    Replace('{{DIR}}', $dir).
    Replace('{{BRANCH}}', $branch).
    Replace('{{OUT}}', $outPath)

# ---------- run, inside the project ----------
Set-Location $dir
$ErrorActionPreference = 'Continue'
# The only run with Bash and Edit. --max-turns is the real cost ceiling here:
# each turn can read files and run commands, so this is 10-40x a check.
$claudeArgs = @(
    '-p',
    '--model', 'sonnet',
    '--allowedTools', 'Read,Write,Edit,Bash,Glob,Grep',
    '--allow-dangerously-skip-permissions',
    '--dangerously-skip-permissions',
    '--max-turns', '40',
    '--output-format', 'json'
)
$prompt | & $claude @claudeArgs 2>&1 | Out-File $log -Encoding utf8
$ErrorActionPreference = 'Stop'
Set-Location $base

# ---------- report back to the card ----------
$dirtyAfter = @(Git-Lines @('-C', $dir, 'status', '--porcelain')).Count
$changed = $dirtyAfter - $dirtyBefore
$summary = ''
$doneTexts = @()
if (Test-Path $outPath) {
    try {
        $out = ([string](Get-Content $outPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $summary = [string]$out.summary
        $doneTexts = @(AsArr $out.subtasksDone | ForEach-Object { [string]$_ })
    } catch {
        Add-Content $log '[warn] summary file is not valid JSON'
    }
    Remove-Item $outPath -Force -ErrorAction SilentlyContinue
}
if (-not $summary) { $summary = $STR.noSummary }

$noteText = '{0} | branch: {1} | {2}: {3}' -f $STR.noteHead, $branch, $STR.noteFiles, $dirtyAfter

$mutex = New-Object System.Threading.Mutex($false, 'DailyBriefKanbanWrite')
$got = $false
try {
    $got = $mutex.WaitOne(30000)
    $fresh = ([string](Get-Content $kanbanPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $t = $fresh.tasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
    if ($t) {
        # Tick off only the steps the model reported by their exact text: the
        # checklist is matched by text everywhere else in this app too.
        if ($doneTexts.Count -gt 0 -and $t.PSObject.Properties['subtasks'] -and $t.subtasks) {
            foreach ($s in @($t.subtasks)) {
                if ($doneTexts -contains [string]$s.text) { $s.done = $true }
            }
        }
        $cs = @()
        if ($t.PSObject.Properties['comments'] -and $t.comments) { $cs = @($t.comments) }
        $cs += (New-Object PSObject -Property @{ by = 'ai'; text = $summary; at = $stamp; state = 'applied' })
        if ($t.PSObject.Properties['comments']) { $t.comments = $cs } else { $t | Add-Member -NotePropertyName comments -NotePropertyValue $cs }
        $ns = @()
        if ($t.PSObject.Properties['aiNotes'] -and $t.aiNotes) { $ns = @($t.aiNotes) }
        $ns += (New-Object PSObject -Property @{ text = $noteText; at = $now })
        if ($ns.Count -gt 10) { $ns = @($ns | Select-Object -Last 10) }
        if ($t.PSObject.Properties['aiNotes']) { $t.aiNotes = $ns } else { $t | Add-Member -NotePropertyName aiNotes -NotePropertyValue $ns }
        # The task is never closed here on purpose: done is the user's call
        # after reading the diff.
        $t.updatedAt = $stamp
        [IO.File]::WriteAllText($kanbanPath, ($fresh | ConvertTo-Json -Depth 10), $utf8NoBom)
    }
} catch {
    Add-Content $log ('[warn] result merge failed: ' + $_.Exception.Message)
} finally {
    if ($got) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

Add-Content $log ('[branch] {0} | files dirty before/after: {1}/{2} (delta {3})' -f $branch, $dirtyBefore, $dirtyAfter, $changed)
Add-Content $log ('[timing] execute total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)

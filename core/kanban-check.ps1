# Fast kanban check with minimal AI tokens. The script does the heavy lifting:
# it compresses task + linked-folder activity into check-digest-<runid>.json,
# Claude reads ONLY that and writes a tiny check-patch-<runid>.json, and the
# script applies the patch to kanban.json. -TaskId scopes to one task;
# -Replan re-plans it; -Generate proposes brand-new tasks from overall
# trajectory instead of per-task activity. -RunId lets several of these run
# at once (main.js assigns one per concurrent AI process) without their
# digest/patch/log files colliding.
# ASCII-only on purpose (PS 5.1 encoding).
param(
    [string]$TaskId = '',
    [switch]$Replan,
    [switch]$Generate,
    [string]$RunId = ''
)

# Force real UTF-8 as early as possible, before anything else runs, so no
# child process in the claude.cmd -> node chain can inherit a stale codepage.
& chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$base   = 'C:\Users\davit\OneDrive\Desktop\DailyBriefApp\core'
$claude = 'C:\Users\davit\AppData\Roaming\nvm\v22.22.3\claude.cmd'
$now = Get-Date -Format 'yyyy-MM-dd HH:mm'
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Norm-Title([string]$s) { return ($s + '').Trim().ToLowerInvariant() }
function Read-TextFile([string]$name) {
    $p = Join-Path $base $name
    if (Test-Path $p) { return (Get-Content $p -Raw -Encoding UTF8) }
    return ''
}

# Per-run file names: several checks can be in flight at once (main.js caps
# concurrency), each with its own RunId, so they never touch each other's
# digest/patch/log.
$runToken   = if ($RunId) { $RunId } else { [guid]::NewGuid().ToString('N').Substring(0, 8) }
$log        = Join-Path $base ("check-run-$runToken.log")
$digestPath = Join-Path $base ("check-digest-$runToken.json")
$patchPath  = Join-Path $base ("check-patch-$runToken.json")
if (Test-Path $patchPath) { Remove-Item $patchPath -Force }

# ---------- Build the compressed digest (script-side, zero AI tokens) ----------
$kanbanPath = Join-Path $base 'kanban.json'
$kanban = Get-Content $kanbanPath -Raw -Encoding UTF8 | ConvertFrom-Json

$archTitles = @()
if ($kanban.PSObject.Properties['archive'] -and $kanban.archive) {
    $archTitles = @($kanban.archive | ForEach-Object { [string]$_.title })
}
$doneTitlesAll = @(@($kanban.tasks | Where-Object { $_.done } | ForEach-Object { [string]$_.title } | Select-Object -First 15) + @($archTitles | Select-Object -First 15))

if ($Generate) {
    # ---------- Trajectory digest: overall direction, not recent-file activity ----------
    # Content is embedded directly (not left for Claude to Read) so the run
    # stays within the same tiny --max-turns budget as a normal check.
    $digest = @{
        now = $now
        target = 'GENERATE'
        goals = Read-TextFile 'GOALS.md'
        state = Read-TextFile 'STATE.md'
        progress = Read-TextFile 'PROGRESS.md'
        topDirsText = Read-TextFile 'top-dirs.txt'
        activeTitles = @($kanban.tasks | ForEach-Object { [string]$_.title })
        doneTitles = $doneTitlesAll
    }
    [IO.File]::WriteAllText($digestPath, ($digest | ConvertTo-Json -Depth 6), $utf8NoBom)
} else {
    # Activity source is the background monitor's event log (<=30 min stale, no
    # rescans here) - the Windows Recent folder is empty on this machine, so the
    # discover-dirs Quick signal is useless for checks.
    $events = @()
    foreach ($d in @((Get-Date), (Get-Date).AddDays(-1))) {
        $f = Join-Path $base ('analytics\' + $d.ToString('yyyy-MM-dd') + '.jsonl')
        if (Test-Path $f) {
            Get-Content $f -Encoding UTF8 | ForEach-Object {
                if ($_.Trim()) { try { $events += ($_ | ConvertFrom-Json) } catch {} }
            }
        }
    }

    $activeTasks = @($kanban.tasks | Where-Object { -not $_.done })
    if ($TaskId) { $activeTasks = @($activeTasks | Where-Object { $_.id -eq $TaskId }) }

    $digestTasks = @(foreach ($t in $activeTasks) {
        $dirs = @()
        if ($t.PSObject.Properties['dirs'] -and $t.dirs) { $dirs = @($t.dirs) }
        $changes = @()
        $changeCount = 0
        if ($dirs.Count -gt 0) {
            $matched = @($events | Where-Object {
                $full = [string]$_.project + '\' + [string]$_.file
                $hit = $false
                foreach ($dd in $dirs) {
                    if ($full.StartsWith($dd + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
                        [string]$_.project -eq $dd -or
                        ([string]$_.project).StartsWith($dd + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $hit = $true; break }
                }
                $hit
            })
            $changeCount = $matched.Count
            $changes = @($matched | Sort-Object ts -Descending | Select-Object -First 5 |
                ForEach-Object { @{ file = [string]$_.file; ts = [string]$_.ts } })
        }
        $comments = @()
        if ($t.PSObject.Properties['comments'] -and $t.comments) {
            $comments = @($t.comments | Where-Object { $_.by -eq 'user' } |
                Select-Object -Last 2 | ForEach-Object { [string]$_.text })
        }
        $desc = [string]$t.desc
        if ($desc.Length -gt 200 -and -not $Replan) { $desc = $desc.Substring(0, 200) }

        # Baseline diff from the folder scanner (git-aware, most precise signal).
        $scanDiff = $null
        $scanPath = Join-Path $base ('scans\' + [string]$t.id + '.json')
        if ($dirs.Count -gt 0) {
            if (Test-Path $scanPath) {
                try {
                    $scan = Get-Content $scanPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $sdir = [string]$scan.dir
                    if ($scan.isGit -and (Test-Path $sdir)) {
                        $range = [string]$scan.head + '..HEAD'
                        $newCommits = @(git -C $sdir log --oneline $range 2>$null | Select-Object -First 10 | ForEach-Object { [string]$_ })
                        $changedFiles = @(git -C $sdir diff --name-only $range 2>$null | Select-Object -First 15 | ForEach-Object { [string]$_ })
                        $dirtyNow = @(git -C $sdir status --porcelain 2>$null | Select-Object -First 15 | ForEach-Object { [string]$_ })
                        $scanDiff = @{
                            kind = 'git'; branch = [string]$scan.branch; sinceBaseline = [string]$scan.scannedAt
                            newCommits = $newCommits; changedFiles = $changedFiles
                            dirtyNow = $dirtyNow; dirtyBefore = $scan.dirtyCount
                        }
                    } elseif ((-not $scan.isGit) -and (Test-Path $sdir)) {
                        $old = @{}
                        foreach ($line in @($scan.files)) {
                            $parts = ([string]$line).Split('|')
                            if ($parts.Count -ge 2) { $old[$parts[0]] = $parts[1] }
                        }
                        $newFiles = New-Object System.Collections.Generic.List[string]
                        $modFiles = New-Object System.Collections.Generic.List[string]
                        Get-ChildItem $sdir -Recurse -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.FullName -notmatch 'node_modules|\\\.git|__pycache__|\\\.venv|\\dist\\|\\coverage\\|Cache' } |
                            Select-Object -First 2000 |
                            ForEach-Object {
                                $rel = if ($_.FullName.Length -gt $sdir.Length + 1) { $_.FullName.Substring($sdir.Length + 1) } else { $_.Name }
                                $mt = $_.LastWriteTime.ToString('yyyy-MM-ddTHH:mm')
                                if (-not $old.ContainsKey($rel)) { $newFiles.Add($rel) }
                                elseif ($old[$rel] -ne $mt) { $modFiles.Add($rel) }
                            }
                        $scanDiff = @{
                            kind = 'files'; sinceBaseline = [string]$scan.scannedAt
                            newCount = $newFiles.Count; modifiedCount = $modFiles.Count
                            newFiles = @($newFiles | Select-Object -First 10)
                            modifiedFiles = @($modFiles | Select-Object -First 10)
                        }
                    }
                } catch { $scanDiff = $null }
            }
            # Advance the baseline: next check diffs from this moment.
            & (Join-Path $base 'scan-folder.ps1') -TaskId ([string]$t.id) -Dir ([string]$dirs[0])
        }

        $subtasks = @()
        if ($t.PSObject.Properties['subtasks'] -and $t.subtasks) {
            $subtasks = @($t.subtasks | Select-Object -First 15 |
                ForEach-Object { @{ text = [string]$_.text; done = [bool]$_.done } })
        }
        @{
            id = [string]$t.id; title = [string]$t.title; status = [string]$t.status
            desc = $desc; dirs = $dirs; subtasks = $subtasks
            changeCount = $changeCount; changes = $changes; comments = $comments
            scanDiff = $scanDiff
        }
    })

    # Top active projects from monitor events (count of changed files per project).
    $topDirs = @($events | Group-Object project | Sort-Object Count -Descending |
        Select-Object -First 6 | ForEach-Object { '{0}x {1}' -f $_.Count, $_.Name })

    # Token saver: if there is zero activity anywhere (no monitor events, no
    # baseline diffs), there is nothing for the AI to conclude - skip the run
    # entirely and spend zero tokens. This applies to a plain check whether
    # it's global or scoped to one task's dead folder - a task-replan is an
    # explicit user request to rethink the plan, so it always runs.
    $signal = $events.Count -gt 0
    foreach ($dt in $digestTasks) {
        if ($dt.changeCount -gt 0) { $signal = $true }
        if ($dt.scanDiff) {
            foreach ($k in @('newCommits', 'changedFiles', 'dirtyNow', 'newFiles', 'modifiedFiles')) {
                if ($dt.scanDiff.ContainsKey($k) -and @($dt.scanDiff[$k]).Count -gt 0) { $signal = $true }
            }
        }
    }
    $skipEligible = -not ($TaskId -and $Replan)
    if ($skipEligible -and -not $signal) {
        $msg = 'skipped: no activity since last check - zero AI tokens spent' + "`r`n" +
            ('[timing] check total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)
        [IO.File]::WriteAllText($log, $msg, $utf8NoBom)
        exit 0
    }

    $digest = @{
        now = $now
        target = if ($TaskId) { $TaskId } else { 'ALL' }
        topDirs = $topDirs
        tasks = $digestTasks
        doneTitles = $doneTitlesAll
    }
    [IO.File]::WriteAllText($digestPath, ($digest | ConvertTo-Json -Depth 6), $utf8NoBom)
}

# ---------- Claude: digest in, tiny patch out ----------
$promptFile = if ($Generate) { 'prompt-task-generate.md' }
              elseif ($Replan -and $TaskId) { 'prompt-task-replan.md' }
              else { 'prompt-check.md' }
$prompt = (Get-Content (Join-Path $base $promptFile) -Raw -Encoding UTF8).Replace('{{NOW}}', $now)

Set-Location $base
$ErrorActionPreference = 'Continue'
# Prompt goes via stdin: it contains quotes that PS 5.1 mangles as an argument,
# which silently breaks every flag after it.
$claudeArgs = @(
    '-p',
    '--model', 'haiku',
    '--allowedTools', 'Read,Write',
    '--allow-dangerously-skip-permissions',
    '--dangerously-skip-permissions',
    '--max-turns', '5',
    '--output-format', 'json'
)
$prompt | & $claude @claudeArgs 2>&1 | Out-File $log -Encoding utf8
$ErrorActionPreference = 'Stop'

# ---------- Apply the patch (only the script ever rewrites kanban.json) ----------
# Several checks can finish around the same time, each with its own patch.
# A named mutex serializes the read-merge-write against kanban.json so no
# run's update is silently clobbered by another's; the fresh re-read inside
# the lock picks up whatever the last writer (if any) just saved.
if (Test-Path $patchPath) {
    $mutex = New-Object System.Threading.Mutex($false, 'DailyBriefKanbanWrite')
    $gotLock = $false
    try {
        $patch = Get-Content $patchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $valid = @('urgent', 'important', 'planning', 'delayed')
        $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')

        $gotLock = $mutex.WaitOne(30000)
        if (-not $gotLock) { throw 'kanban.json lock timeout' }
        $fresh = Get-Content $kanbanPath -Raw -Encoding UTF8 | ConvertFrom-Json

        foreach ($u in @($patch.updates)) {
            if (-not $u -or -not $u.id) { continue }
            $t = $fresh.tasks | Where-Object { $_.id -eq $u.id } | Select-Object -First 1
            if (-not $t) { continue }
            if ($u.PSObject.Properties['note'] -and $u.note) {
                $note = New-Object PSObject -Property @{ text = [string]$u.note; at = $now }
                $notes = @()
                if ($t.PSObject.Properties['aiNotes'] -and $t.aiNotes) { $notes = @($t.aiNotes) }
                $notes += $note
                if ($notes.Count -gt 10) { $notes = @($notes | Select-Object -Last 10) }
                if ($t.PSObject.Properties['aiNotes']) { $t.aiNotes = $notes }
                else { $t | Add-Member -NotePropertyName aiNotes -NotePropertyValue $notes }
            }
            # Hard rule: the AI may never downgrade a task the user marked urgent.
            if ($u.PSObject.Properties['status'] -and $valid -contains $u.status -and $t.status -ne 'urgent') { $t.status = [string]$u.status }
            if ($u.PSObject.Properties['desc'] -and $u.desc) { $t.desc = [string]$u.desc }
            if ($u.PSObject.Properties['subtasks'] -and $u.subtasks) {
                # Keep done-state of subtasks whose text survived the replan.
                $oldDone = @{}
                if ($t.PSObject.Properties['subtasks'] -and $t.subtasks) {
                    foreach ($os in $t.subtasks) { if ($os.done) { $oldDone[[string]$os.text] = $true } }
                }
                $newSubs = @($u.subtasks | Select-Object -First 30 | ForEach-Object {
                    $txt = [string]$_
                    New-Object PSObject -Property @{ text = $txt; done = [bool]$oldDone[$txt] }
                })
                if ($t.PSObject.Properties['subtasks']) { $t.subtasks = $newSubs }
                else { $t | Add-Member -NotePropertyName subtasks -NotePropertyValue $newSubs }
            }
            if ($u.PSObject.Properties['done'] -and $u.done -eq $true) { $t.done = $true }
            $t.updatedAt = $stamp
        }

        # Dedupe against ids (tasks + archive) and normalized titles (tasks +
        # archive + done) so a reworded near-duplicate can't slip through.
        $freshArchive = if ($fresh.PSObject.Properties['archive'] -and $fresh.archive) { @($fresh.archive) } else { @() }
        $existingIds = @(@($fresh.tasks | ForEach-Object { [string]$_.id }) + @($freshArchive | ForEach-Object { [string]$_.id }))
        $existingTitlesNorm = @(@($fresh.tasks | ForEach-Object { Norm-Title $_.title }) + @($freshArchive | ForEach-Object { Norm-Title $_.title }))
        foreach ($n in @($patch.newTasks)) {
            if (-not $n -or -not $n.id -or -not $n.title) { continue }
            $nTitleNorm = Norm-Title $n.title
            if ($existingIds -contains [string]$n.id -or $existingTitlesNorm -contains $nTitleNorm) { continue }
            $nt = New-Object PSObject -Property @{
                id = [string]$n.id; title = [string]$n.title; desc = [string]$n.desc
                status = if ($valid -contains $n.status) { [string]$n.status } else { 'planning' }
                done = $false; createdBy = 'ai'
                createdAt = $stamp; updatedAt = $stamp
                comments = @(); aiNotes = @(); dirs = @()
            }
            $fresh.tasks = @($fresh.tasks) + $nt
            $existingIds += [string]$n.id
            $existingTitlesNorm += $nTitleNorm
        }

        [IO.File]::WriteAllText($kanbanPath, ($fresh | ConvertTo-Json -Depth 10), $utf8NoBom)
        Remove-Item $patchPath -Force
    } catch {
        Add-Content $log ('[warn] patch apply failed: ' + $_.Exception.Message)
    } finally {
        if ($gotLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

Add-Content $log ('[timing] check total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)

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
    [switch]$Command,
    [string]$RunId = ''
)

# Force real UTF-8 as early as possible, before anything else runs, so no
# child process in the claude.cmd -> node chain can inherit a stale codepage.
& chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
$now = Get-Date -Format 'yyyy-MM-dd HH:mm'
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Norm-Title([string]$s) { return ($s + '').Trim().ToLowerInvariant() }

# Georgian UI strings live in a UTF-8 JSON file on purpose: this script stays
# ASCII so PS 5.1 (which reads a BOM-less .ps1 as ANSI) can never mangle them.
$STR = @{ autoBound = 'auto-linked folder:'; commentApplied = 'comment applied.'; commentFailed = 'comment failed.' }
$strPath = Join-Path $app 'strings.json'
if (Test-Path $strPath) {
    try {
        $sj = Get-Content $strPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($sj.PSObject.Properties.Name)) { $STR[$k] = [string]$sj.$k }
    } catch {}
}
function Read-TextFile([string]$name, [int]$MaxChars = 3000) {
    $p = Join-Path $base $name
    if (-not (Test-Path $p)) { return '' }
    # The [string] cast is load-bearing: Get-Content -Raw hands back a string
    # DECORATED with PSPath/PSDrive/Provider note properties, and ConvertTo-Json
    # happily serializes that whole .NET provider graph (observed: a 292 MB
    # digest). The cast turns it back into a plain System.String.
    $text = [string](Get-Content $p -Raw -Encoding UTF8)
    if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) }
    return $text
}

# Per-run file names: several checks can be in flight at once (main.js caps
# concurrency), each with its own RunId, so they never touch each other's
# digest/patch/log.
$runToken   = if ($RunId) { $RunId } else { [guid]::NewGuid().ToString('N').Substring(0, 8) }
$log        = Join-Path $base ("check-run-$runToken.log")
$digestPath = Join-Path $base ("check-digest-$runToken.json")
$patchPath  = Join-Path $base ("check-patch-$runToken.json")
if (Test-Path $patchPath) { Remove-Item $patchPath -Force }

# Resolved only AFTER the log path exists: when no working claude CLI is
# installed this throws, and without the catch the script died leaving no log
# at all - which the app used to journal as a successful run.
try {
    . (Join-Path $PSScriptRoot 'claude-path.ps1')   # sets $claude
} catch {
    [IO.File]::WriteAllText($log, ('[fatal] ' + $_.Exception.Message), $utf8NoBom)
    exit 3
}

# ---------- Build the compressed digest (script-side, zero AI tokens) ----------
$kanbanPath = Join-Path $base 'kanban.json'
# An empty board is a normal state (fresh account, first run), not a crash.
# This used to die inside Get-Content before the log existed, which the app
# then reported as "claude CLI wrote no log".
if (-not (Test-Path $kanbanPath)) {
    $empty = [pscustomobject]@{ tasks = @(); archive = @() }
    [IO.File]::WriteAllText($kanbanPath, ($empty | ConvertTo-Json -Depth 6), $utf8NoBom)
}
try {
    $kanban = Get-Content $kanbanPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    [IO.File]::WriteAllText($log, ('[fatal] kanban.json unreadable: ' + $_.Exception.Message), $utf8NoBom)
    exit 4
}
if (-not $kanban) { $kanban = [pscustomobject]@{ tasks = @(); archive = @() } }

# ---------- project registry (built by discover-projects.ps1, no AI) ----------
$projects = @()
$projectsPath = Join-Path $base 'projects.json'
if (Test-Path $projectsPath) {
    try { $projects = @((Get-Content $projectsPath -Raw -Encoding UTF8 | ConvertFrom-Json).projects) } catch { $projects = @() }
}

# PS 5.1 serializes an EMPTY array inside an object as {}, so a round-tripped
# "no items" list comes back as an empty PSCustomObject. Without this every
# such field would turn into a one-element array holding a junk object.
function AsArr($v) {
    if ($null -eq $v) { return @() }
    if ($v -is [array]) { return $v }
    if ($v -is [string]) { return @($v) }
    if ($v -is [PSCustomObject] -and @($v.PSObject.Properties).Count -eq 0) { return @() }
    return @($v)
}

# One compact card per project: enough for the model to know WHAT the project
# is (stack, readme intent) and what moved in it, without reading any file.
function Project-Card($p, [switch]$Full) {
    $card = @{
        name = [string]$p.name; dir = [string]$p.dir
        stack = AsArr $p.stack; changed14d = [int]$p.changed14d
        lastTouched = [string]$p.lastTouched
    }
    if ($p.isGit) {
        $card.branch = [string]$p.branch
        $card.dirtyCount = [int]$p.dirtyCount
        $card.lastCommits = @(AsArr $p.lastCommits | Select-Object -First 3)
    }
    if ([int]$p.todoCount -gt 0) { $card.todoCount = [int]$p.todoCount }
    if ($Full) {
        $card.readme = [string]$p.readme
        $card.pkgDesc = [string]$p.pkgDesc
        $card.recentFiles = @(AsArr $p.recentFiles | Select-Object -First 6)
        $card.dirtySample = @(AsArr $p.dirtySample | Select-Object -First 6)
        $card.todoSample = @(AsArr $p.todoSample | Select-Object -First 4)
    }
    return $card
}

function Find-ProjectByDir([string]$dir) {
    if (-not $dir) { return $null }
    $sep = [char]92
    foreach ($p in $projects) {
        $pd = [string]$p.dir
        if ($pd -eq $dir -or
            $dir.StartsWith($pd + $sep, [StringComparison]::OrdinalIgnoreCase) -or
            $pd.StartsWith($dir + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $p }
    }
    return $null
}

# ---------- auto-bind: a task with no folder is a dead task ----------
# Checks compare a task against its linked folders, but AI-created tasks were
# born with dirs=[] - so they never collected any evidence and rotted on the
# board. Bind them by matching the task's own words against the registry.
$stopWords = @('project', 'projects', 'src', 'app', 'apps', 'desktop', 'onedrive', 'users', 'davit',
               'com', 'www', 'main', 'master', 'new', 'the', 'and', 'for', 'backup', 'test', 'temp')

# Georgian letters are part of a word here; the range is built from char codes
# so this file needs no non-ASCII byte and no regex escape.
$geoFrom = [char]0x10A0
$geoTo   = [char]0x10FF

function Get-Tokens([string]$s) {
    $m = [regex]::Matches(($s + '').ToLowerInvariant(), "[a-z0-9$geoFrom-$geoTo]{3,}")
    return @($m | ForEach-Object { $_.Value } | Where-Object { $stopWords -notcontains $_ } | Select-Object -Unique)
}

function Guess-Dir([string]$text) {
    $t = ($text + '').ToLowerInvariant()
    if (-not $t) { return '' }
    $best = ''; $bestScore = 0; $tie = $false; $bestAct = -1
    foreach ($p in $projects) {
        $dir = [string]$p.dir
        $score = 0
        if ($t.Contains($dir.ToLowerInvariant())) { $score += 100 }
        $nameLow = ([string]$p.name).ToLowerInvariant()
        if ($nameLow -and $t.Contains($nameLow)) { $score += 40 }
        $leaf = (Split-Path $dir -Leaf).ToLowerInvariant()
        if ($leaf.Length -ge 3 -and $t.Contains($leaf)) { $score += 25 }
        foreach ($tok in (Get-Tokens ([string]$p.name))) { if ($t.Contains($tok)) { $score += 10 } }
        if ($score -gt $bestScore) { $best = $dir; $bestScore = $score; $tie = $false; $bestAct = [int]$p.changed14d }
        elseif ($score -eq $bestScore -and $score -gt 0 -and $best -ne $dir) {
            # Nested repos score identically (Discord_Ge vs Discord_Ge\discord-ge).
            # The more active one is the folder the work actually happens in.
            $sep = [char]92
            if ([int]$p.changed14d -gt $bestAct) { $best = $dir; $bestAct = [int]$p.changed14d; $tie = $false }
            elseif ([int]$p.changed14d -lt $bestAct) { }
            elseif ($dir.StartsWith($best + $sep, [StringComparison]::OrdinalIgnoreCase)) {
                # Equally active nested repos: the inner one is the actual work.
                $best = $dir; $tie = $false
            }
            elseif ($best.StartsWith($dir + $sep, [StringComparison]::OrdinalIgnoreCase)) { $tie = $false }
            else { $tie = $true }
        }
    }
    # An ambiguous guess is worse than none: a wrong folder produces confident
    # nonsense in every later check.
    # One distinctive shared word (a project name) is enough; ties are resolved
    # above by activity, and stop-words keep generic matches out.
    if ($bestScore -ge 10 -and -not $tie) { return $best }
    return ''
}

function Save-Kanban($data) {
    $mx = New-Object System.Threading.Mutex($false, 'DailyBriefKanbanWrite')
    $got = $false
    try {
        $got = $mx.WaitOne(30000)
        [IO.File]::WriteAllText($kanbanPath, ($data | ConvertTo-Json -Depth 10), $utf8NoBom)
    } finally {
        if ($got) { $mx.ReleaseMutex() }
        $mx.Dispose()
    }
}

$bound = $false
foreach ($t in @($kanban.tasks | Where-Object { -not $_.done })) {
    if ($t.PSObject.Properties['dirs'] -and @($t.dirs).Count -gt 0) { continue }
    $guess = Guess-Dir (([string]$t.title) + ' ' + ([string]$t.desc))
    if (-not $guess -or -not (Test-Path $guess)) { continue }
    if ($t.PSObject.Properties['dirs']) { $t.dirs = @($guess) }
    else { $t | Add-Member -NotePropertyName dirs -NotePropertyValue @($guess) }
    $note = New-Object PSObject -Property @{ text = ($STR.autoBound + ' ' + $guess); at = $now }
    $notes = @()
    if ($t.PSObject.Properties['aiNotes'] -and $t.aiNotes) { $notes = @($t.aiNotes) }
    $notes += $note
    if ($t.PSObject.Properties['aiNotes']) { $t.aiNotes = @($notes | Select-Object -Last 10) }
    else { $t | Add-Member -NotePropertyName aiNotes -NotePropertyValue @($notes) }
    # Baseline it immediately, otherwise the first check after binding reports
    # the whole repo as new work.
    $null = & (Join-Path $app 'scan-folder.ps1') -TaskId ([string]$t.id) -Dir $guess 2>$null
    $bound = $true
}
if ($bound) { Save-Kanban $kanban }

$archTitles = @()
if ($kanban.PSObject.Properties['archive'] -and $kanban.archive) {
    $archTitles = @($kanban.archive | ForEach-Object { [string]$_.title })
}
# Only a short "already handled" list: it exists to stop duplicates, and every
# extra title is pure input tokens on every single run.
$doneTitlesAll = @(@($kanban.tasks | Where-Object { $_.done } | ForEach-Object { [string]$_.title } | Select-Object -Last 8) + @($archTitles | Select-Object -Last 6))

if ($Generate) {
    # ---------- Trajectory digest: overall direction, not recent-file activity ----------
    # Content is embedded directly (not left for Claude to Read) so the run
    # stays within the same tiny --max-turns budget as a normal check.
    # Projects are the unit of planning here, not directory byte-scores: each
    # card carries stack, readme intent, recent commits and open TODOs, so the
    # model proposes work that exists instead of narrating folder-size trends.
    $genProjects = @($projects |
        Where-Object { [int]$_.changed14d -gt 0 -or [int]$_.dirtyCount -gt 0 -or [int]$_.todoCount -gt 0 } |
        Sort-Object @{e = { [int]$_.changed14d }; Descending = $true} |
        Select-Object -First 12 |
        ForEach-Object { Project-Card $_ -Full })
    $boundDirs = @($kanban.tasks | Where-Object { -not $_.done } | ForEach-Object { @($_.dirs) } | Where-Object { $_ })

    $digest = @{
        now = $now
        target = 'GENERATE'
        goals = Read-TextFile 'GOALS.md' 1500
        state = Read-TextFile 'STATE.md' 1500
        progress = Read-TextFile 'PROGRESS.md' 800
        projects = $genProjects
        boundDirs = $boundDirs
        activeTitles = @($kanban.tasks | ForEach-Object { [string]$_.title })
        doneTitles = $doneTitlesAll
    }
    [IO.File]::WriteAllText($digestPath, ($digest | ConvertTo-Json -Depth 6), $utf8NoBom)
} elseif ($Command) {
    # The user wrote a comment on a task. That comment is an ORDER inside the
    # task's scope (plan it better / split this / this is done), so it gets its
    # own tiny run with the project card attached.
    $t = @($kanban.tasks | Where-Object { $_.id -eq $TaskId }) | Select-Object -First 1
    if (-not $t) {
        [IO.File]::WriteAllText($log, 'skipped: task not found', $utf8NoBom)
        exit 0
    }
    $pending = @()
    if ($t.PSObject.Properties['comments'] -and $t.comments) {
        $pending = @($t.comments | Where-Object { $_.by -eq 'user' -and $_.state -eq 'new' } |
            Select-Object -Last 5 | ForEach-Object { [string]$_.text })
    }
    if ($pending.Count -eq 0) {
        [IO.File]::WriteAllText($log, 'skipped: no pending comment - zero AI tokens spent', $utf8NoBom)
        exit 0
    }
    $dirs = @()
    if ($t.PSObject.Properties['dirs'] -and $t.dirs) { $dirs = @($t.dirs) }
    $proj = if ($dirs.Count -gt 0) { Find-ProjectByDir ([string]$dirs[0]) } else { $null }
    $subs = @()
    if ($t.PSObject.Properties['subtasks'] -and $t.subtasks) {
        $subs = @($t.subtasks | Select-Object -First 30 | ForEach-Object { @{ text = [string]$_.text; done = [bool]$_.done } })
    }
    $history = @()
    if ($t.PSObject.Properties['comments'] -and $t.comments) {
        $history = @($t.comments | Select-Object -Last 6 | ForEach-Object { @{ by = [string]$_.by; text = [string]$_.text } })
    }
    $digest = @{
        now = $now
        target = 'COMMAND'
        task = @{
            id = [string]$t.id; title = [string]$t.title; desc = [string]$t.desc
            status = [string]$t.status; dirs = $dirs; subtasks = $subs
        }
        commands = $pending
        history = $history
        project = if ($proj) { Project-Card $proj -Full } else { $null }
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
            # $null = : this runs inside the $digestTasks foreach EXPRESSION ?
            # anything it emits (stray output, error records) would be captured
            # into the array and ConvertTo-Json would serialize whole .NET
            # object graphs into the digest (observed: a 391 MB digest file).
            $null = & (Join-Path $app 'scan-folder.ps1') -TaskId ([string]$t.id) -Dir ([string]$dirs[0]) 2>$null
        }

        $subtasks = @()
        if ($t.PSObject.Properties['subtasks'] -and $t.subtasks) {
            $subtasks = @($t.subtasks | Select-Object -First 15 |
                ForEach-Object { @{ text = [string]$_.text; done = [bool]$_.done } })
        }
        # What the linked folder actually IS - without it the model can only
        # comment on how many bytes moved.
        $projCard = $null
        if ($dirs.Count -gt 0) {
            $pp = Find-ProjectByDir ([string]$dirs[0])
            if ($pp) { $projCard = Project-Card $pp -Full:$Replan }
        }

        @{
            id = [string]$t.id; title = [string]$t.title; status = [string]$t.status
            desc = $desc; dirs = $dirs; subtasks = $subtasks
            changeCount = $changeCount; changes = $changes; comments = $comments
            scanDiff = $scanDiff; project = $projCard
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
# A digest is a few KB by design. Anything larger means a serialization bug
# upstream; sending it would burn tokens and fail anyway.
$digestSize = (Get-Item $digestPath -ErrorAction SilentlyContinue).Length
if ($digestSize -gt 1MB) {
    [IO.File]::WriteAllText($log, ('skipped: digest too large ({0:N0} bytes) - not sent to the model' -f $digestSize), $utf8NoBom)
    exit 0
}

$promptFile = if ($Generate) { 'prompt-task-generate.md' }
              elseif ($Command) { 'prompt-task-command.md' }
              elseif ($Replan -and $TaskId) { 'prompt-task-replan.md' }
              else { 'prompt-check.md' }
# The exact per-run file names go INTO the prompt. Left to guess a suffixed
# name, the model spends turns listing the folder and can write the patch
# where the script never looks for it.
$prompt = (Get-Content (Join-Path $app $promptFile) -Raw -Encoding UTF8).
    Replace('{{DATA}}', $base).
    Replace('{{NOW}}', $now).
    Replace('{{DIGEST}}', ("check-digest-$runToken.json")).
    Replace('{{PATCH}}', ("check-patch-$runToken.json"))

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
    '--max-turns', '8',
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
        $valid = @('urgent', 'important', 'planning', 'delayed', 'active')
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
            # A direct order from the user may rewrite the title and override
            # even an urgent status; a routine check may not.
            if ($Command -and $u.PSObject.Properties['title'] -and $u.title) { $t.title = ([string]$u.title).Trim() }
            if ($u.PSObject.Properties['status'] -and $valid -contains $u.status -and ($Command -or $t.status -ne 'urgent')) { $t.status = [string]$u.status }
            if ($u.PSObject.Properties['desc'] -and $u.desc) { $t.desc = [string]$u.desc }
            # The model's answer to the user's comment, posted back into the thread.
            if ($u.PSObject.Properties['reply'] -and $u.reply) {
                $cs = @()
                if ($t.PSObject.Properties['comments'] -and $t.comments) { $cs = @($t.comments) }
                $cs += (New-Object PSObject -Property @{ by = 'ai'; text = [string]$u.reply; at = $stamp; state = 'applied' })
                if ($t.PSObject.Properties['comments']) { $t.comments = $cs }
                else { $t | Add-Member -NotePropertyName comments -NotePropertyValue $cs }
            }
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
            # Bind the folder at birth. A task with dirs=[] never collects any
            # evidence, so every later check has nothing to say about it.
            $newDirs = @()
            if ($n.PSObject.Properties['dir'] -and $n.dir -and (Test-Path ([string]$n.dir))) { $newDirs = @([string]$n.dir) }
            else {
                $g = Guess-Dir (([string]$n.title) + ' ' + ([string]$n.desc) + ' ' + ([string]$n.dir))
                if ($g) { $newDirs = @($g) }
            }
            $ntSubs = @()
            if ($n.PSObject.Properties['subtasks'] -and $n.subtasks) {
                $ntSubs = @($n.subtasks | Select-Object -First 15 |
                    ForEach-Object { New-Object PSObject -Property @{ text = [string]$_; done = $false } })
            }
            $nt = New-Object PSObject -Property @{
                id = [string]$n.id; title = [string]$n.title; desc = [string]$n.desc
                status = if ($valid -contains $n.status) { [string]$n.status } else { 'planning' }
                done = $false; createdBy = 'ai'
                createdAt = $stamp; updatedAt = $stamp
                comments = @(); aiNotes = @(); dirs = $newDirs; subtasks = $ntSubs
            }
            if ($newDirs.Count -gt 0) {
                $null = & (Join-Path $app 'scan-folder.ps1') -TaskId ([string]$n.id) -Dir ([string]$newDirs[0]) 2>$null
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
} else {
    # The prompt asks for the patch file unconditionally - even "nothing
    # changed" is written as {"updates":[]}. No file at all means the model
    # stopped early (turn limit, refusal, crash) and this run changed nothing.
    Add-Content $log '[warn] model wrote no output file'
}

# A comment that orders the work to actually be DONE (not re-planned) comes
# back from the model as execute:true. This run has no tools for that - it can
# only rewrite the board - so it leaves a request behind and main.js launches
# execute.ps1, which gets its own branch, VS Code and Bash inside the project.
if ($Command -and $TaskId -and $patch -and $patch.PSObject.Properties['execute'] -and $patch.execute -eq $true) {
    $req = @{ taskId = $TaskId; at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
    [IO.File]::WriteAllText((Join-Path $base 'execute-request.json'), ($req | ConvertTo-Json -Compress), $utf8NoBom)
    Add-Content $log '[execute] requested by comment'
}

# A pending comment must always end up acknowledged, patch or no patch:
# main.js re-fires a command run for every comment still marked "new", so a
# failed run left un-acked would retrigger itself on every board save.
if ($Command -and $TaskId) {
    $mutex2 = New-Object System.Threading.Mutex($false, 'DailyBriefKanbanWrite')
    $got2 = $false
    try {
        $got2 = $mutex2.WaitOne(30000)
        $fresh2 = Get-Content $kanbanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $t2 = $fresh2.tasks | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
        if ($t2 -and $t2.PSObject.Properties['comments'] -and $t2.comments) {
            $changed = $false
            foreach ($c in @($t2.comments)) {
                if ($c.PSObject.Properties['state'] -and $c.state -eq 'new') {
                    $c.state = 'applied'; $changed = $true
                }
            }
            if ($changed) { [IO.File]::WriteAllText($kanbanPath, ($fresh2 | ConvertTo-Json -Depth 10), $utf8NoBom) }
        }
    } catch {
        Add-Content $log ('[warn] comment ack failed: ' + $_.Exception.Message)
    } finally {
        if ($got2) { $mutex2.ReleaseMutex() }
        $mutex2.Dispose()
    }
}

Add-Content $log ('[timing] check total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)

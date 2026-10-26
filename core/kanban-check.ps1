# Fast kanban check with minimal AI tokens. The script does the heavy lifting:
# it compresses task + linked-folder activity into check-digest-<runid>.json,
# hands that digest to Claude INLINE in a single lean, tool-less call
# (claude-run.ps1) whose answer is schema-validated structured output, writes
# that answer to check-patch-<runid>.json and applies it to kanban.json.
# The model never opens or writes a file: every Read/Write turn used to resend
# the whole CLI context (~96k input tokens for a 14KB digest).
# -TaskId scopes to one task, -TaskIds (comma-separated) to a hand-picked set -
# e.g. one project's cards, which is how the 5-hourly check is sharded: one
# run per project, in parallel. A scoped run sees only its own tasks and their
# project and may never create tasks (it has not seen the rest of the board).
# -Replan re-plans it; -Generate proposes brand-new tasks from overall
# trajectory instead of per-task activity. -NewTasksOnly is the board-wide
# companion of the sharded check: no per-task evidence, only "is there a busy
# working folder no task covers yet" - and when there is none it never calls
# the model at all. -RunId lets several of these run
# at once (main.js assigns one per concurrent AI process) without their
# digest/patch/log files colliding.
# ASCII-only on purpose (PS 5.1 encoding).
param(
    [string]$TaskId = '',
    [string]$TaskIds = '',
    [switch]$Replan,
    [switch]$Generate,
    [switch]$Command,
    [switch]$NewTasksOnly,
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
$idSet = @()
if ($TaskIds) { $idSet = @($TaskIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$scoped = $false   # set by the check branch; Generate/Command are never "scoped checks"

# Which tasks this run actually saw activity for. A routine check may close
# only these: closing a task off a trend ("the folder keeps shrinking") is the
# one thing the prompt forbids and the one thing a model does anyway, so the
# script decides it instead of asking.
$evidenceIds = @{}
$doneNeedsEvidence = $false
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Norm-Title([string]$s) { return ($s + '').Trim().ToLowerInvariant() }

# Generated output is not evidence of anything: one npm build rewrites every
# hashed bundle in assets\ and drowns the five source files that matter.
$NOISE_RE = '(^|/)(node_modules|dist|build|out|vendor|coverage|__pycache__|\.next|\.venv|assets|storage|logs|bootstrap/cache|framework/(views|cache|sessions))/|\.min\.(js|css)$|\.(map|log|lock)$|(^|/)(package-lock\.json|composer\.lock|yarn\.lock)$'
# Separators are normalized first: a character class of escaped
# backslashes is one escaping layer away from silently matching nothing.
function Is-Noise([string]$path) { return (([string]$path).Replace([char]92, '/') -match $NOISE_RE) }

# The names a task itself puts on the table: the files its checklist points at
# (InfoCommand.php), the classes it names (DeployHistory), the columns it adds
# (deploy_logs). Everything a folder-wide diff can be tested against.
function Task-Keywords($t) {
    $parts = @([string]$t.title, [string]$t.desc)
    if ($t.PSObject.Properties['subtasks'] -and $t.subtasks) {
        $parts += @($t.subtasks | ForEach-Object { [string]$_.text })
    }
    $text = ($parts -join ' ')
    $kw = New-Object System.Collections.Generic.List[string]
    $pats = @(
        '[A-Za-z][A-Za-z0-9_\-]{2,}\.(?:blade\.php|tsx|ts|jsx|js|php|vue|py|go|rb|cs|java|kt|scss|css|json|md|ps1|sql|yaml|yml)',
        '\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+\b',
        '\b[a-z][a-z0-9]*_[a-z0-9_]{2,}\b'
    )
    foreach ($p in $pats) {
        foreach ($m in [regex]::Matches($text, $p)) {
            $v = [string]$m.Value
            if ($v.Length -ge 4 -and -not ($kw -contains $v)) { $kw.Add($v) }
        }
    }
    return @($kw)
}

# The same names with the extension dropped: "Invoice.php" also reaches
# InvoiceController.php. Too loose to close a task on, precise enough to be
# worth showing - the model decides which of the two it is looking at.
function Task-Stems([string[]]$kw) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($k in $kw) {
        $stem = [regex]::Replace([string]$k, '\.[A-Za-z0-9.]+$', '')
        if ($stem.Length -ge 5 -and -not ($out -contains $stem)) { $out.Add($stem) }
    }
    return @($out)
}

# Which of the folder's changes name one of those keywords. A shared repo hands
# every one of its tasks the same 8 commits; only this tells them apart.
function Match-Evidence([string[]]$kw, [string[]]$lines) {
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $kw -or $kw.Count -eq 0) { return @() }
    foreach ($line in $lines) {
        $l = [string]$line
        if (-not $l) { continue }
        foreach ($k in $kw) {
            if ($l.IndexOf($k, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $out.Add($l); break }
        }
    }
    return @($out | Select-Object -First 8)
}

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
. (Join-Path $PSScriptRoot 'claude-run.ps1')   # Invoke-ClaudeLean
. (Join-Path $PSScriptRoot 'lock.ps1')         # Invoke-WithBoardLock

# Every read-modify-write of kanban.json runs inside Invoke-WithBoardLock
# (the board.lock file main.js shares) and re-reads the board inside it. Lock
# bodies stay read-apply-write only - never a model call: the lock goes stale
# after 120s. A body runs in a child scope, so anything needed afterwards is
# set with $script: or lives on a reference object.
function Read-Kanban {
    return (([string](Get-Content $kanbanPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json)
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

# Guesses are made on the copy read above (cheap, no lock held); the write
# re-reads kanban.json inside the lock and binds only tasks that are still
# unbound there. Writing back the copy read at startup used to clobber any
# patch another run had applied in between - and with per-project checks
# running in parallel, every shard does this step at the same moment.
$guesses = @{}
foreach ($t in @($kanban.tasks | Where-Object { -not $_.done })) {
    if ($t.PSObject.Properties['dirs'] -and @($t.dirs).Count -gt 0) { continue }
    $guess = Guess-Dir (([string]$t.title) + ' ' + ([string]$t.desc))
    if (-not $guess -or -not (Test-Path $guess)) { continue }
    $guesses[[string]$t.id] = $guess
}
if ($guesses.Count -gt 0) {
    $script:newlyBound = @()
    Invoke-WithBoardLock {
        $fresh = Read-Kanban
        foreach ($t in @($fresh.tasks | Where-Object { -not $_.done })) {
            $tid = [string]$t.id
            if (-not $guesses.ContainsKey($tid)) { continue }
            if ($t.PSObject.Properties['dirs'] -and @($t.dirs).Count -gt 0) { continue }   # a parallel shard got there first
            $guess = $guesses[$tid]
            if ($t.PSObject.Properties['dirs']) { $t.dirs = @($guess) }
            else { $t | Add-Member -NotePropertyName dirs -NotePropertyValue @($guess) }
            $note = New-Object PSObject -Property @{ text = ($STR.autoBound + ' ' + $guess); at = $now }
            $notes = @()
            if ($t.PSObject.Properties['aiNotes'] -and $t.aiNotes) { $notes = @($t.aiNotes) }
            $notes += $note
            if ($t.PSObject.Properties['aiNotes']) { $t.aiNotes = @($notes | Select-Object -Last 10) }
            else { $t | Add-Member -NotePropertyName aiNotes -NotePropertyValue @($notes) }
            $script:newlyBound += ,@($tid, $guess)
        }
        if ($script:newlyBound.Count -gt 0) {
            [IO.File]::WriteAllText($kanbanPath, ($fresh | ConvertTo-Json -Depth 10), $utf8NoBom)
        }
        $script:kanban = $fresh
    }
    # Baseline it immediately, otherwise the first check after binding reports
    # the whole repo as new work. scans\<id>.json is not the board: no lock.
    foreach ($nb in $script:newlyBound) {
        $null = & (Join-Path $app 'scan-folder.ps1') -TaskId ([string]$nb[0]) -Dir ([string]$nb[1]) 2>$null
    }
}

$archTitles = @()
if ($kanban.PSObject.Properties['archive'] -and $kanban.archive) {
    $archTitles = @($kanban.archive | ForEach-Object { [string]$_.title })
}
# Only a short "already handled" list: it exists to stop duplicates, and every
# extra title is pure input tokens on every single run.
$doneTitlesAll = @(@($kanban.tasks | Where-Object { $_.done } | ForEach-Object { [string]$_.title } | Select-Object -Last 8) + @($archTitles | Select-Object -Last 6))

# Activity source is the background monitor's event log (<=30 min stale, no
# rescans here): today and yesterday.
function Get-RecentEvents {
    $evs = New-Object System.Collections.Generic.List[object]
    foreach ($d in @((Get-Date), (Get-Date).AddDays(-1))) {
        $f = Join-Path $base ('analytics\' + $d.ToString('yyyy-MM-dd') + '.jsonl')
        if (Test-Path $f) {
            Get-Content $f -Encoding UTF8 | ForEach-Object {
                if ($_.Trim()) { try { $evs.Add(($_ | ConvertFrom-Json)) } catch {} }
            }
        }
    }
    return $evs.ToArray()
}

# Same folder, or one inside the other: a task on a repo covers its subfolders
# and a task on a subfolder covers the repo it lives in.
function Same-Tree([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return $false }
    $a = $a.TrimEnd([char]92); $b = $b.TrimEnd([char]92); $sep = [char]92
    return ($a -eq $b -or
        $a.StartsWith($b + $sep, [StringComparison]::OrdinalIgnoreCase) -or
        $b.StartsWith($a + $sep, [StringComparison]::OrdinalIgnoreCase))
}

# Reworded near-duplicates ("Finish Reviews pagination" vs "Reviews pagination
# finished") slip past an exact-title compare. Word overlap catches them.
# 0.75, not lower: "board lock in main.js" vs "board lock in lock.ps1" share
# 4 of 6 words and are two different jobs.
function Similar-Title([string]$a, [string]$b) {
    $ta = @(Get-Tokens $a); $tb = @(Get-Tokens $b)
    if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return $false }
    $common = @($ta | Where-Object { $tb -contains $_ }).Count
    $union = @(@($ta) + @($tb) | Select-Object -Unique).Count
    return ($union -gt 0 -and ($common / $union) -ge 0.75)
}

if ($NewTasksOnly) {
    # ---------- New-task digest: busy folders vs what the board already covers ----------
    # No per-task evidence at all: the per-project shards handled that. This
    # run only answers "is real work happening somewhere no task covers?"
    $events = @(Get-RecentEvents)
    $open = @($kanban.tasks | Where-Object { -not $_.done })
    $closed = @($kanban.tasks | Where-Object { $_.done })
    $arch = @()
    if ($kanban.PSObject.Properties['archive'] -and $kanban.archive) { $arch = @($kanban.archive) }
    $arch = @($arch + @(Get-ColdArchive))
    $openDirs = @($open | ForEach-Object { @(AsArr $_.dirs) } | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $closedDirs = @(@($closed) + @($arch) | ForEach-Object { if ($_.PSObject.Properties['dirs']) { @(AsArr $_.dirs) } } | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $closedTitles = @(@($closed) + @($arch) | ForEach-Object { [string]$_.title })

    $top = @($events | Where-Object { -not (Is-Noise ([string]$_.file)) } |
        Group-Object project | Sort-Object Count -Descending | Select-Object -First 6)
    $uncovered = @()
    foreach ($g in $top) {
        $pd = [string]$g.Name
        if (-not $pd) { continue }
        $hit = $false
        foreach ($od in $openDirs) { if (Same-Tree $pd $od) { $hit = $true; break } }
        if (-not $hit) { foreach ($cd in $closedDirs) { if (Same-Tree $pd $cd) { $hit = $true; break } } }
        # A closed task that names the folder covers it too (old tasks may
        # predate folder binding).
        $leaf = (Split-Path $pd -Leaf).ToLowerInvariant()
        if (-not $hit -and $leaf.Length -ge 4) {
            foreach ($ct in $closedTitles) { if (([string]$ct).ToLowerInvariant().Contains($leaf)) { $hit = $true; break } }
        }
        if (-not $hit) {
            $files = @($g.Group | Sort-Object ts -Descending | ForEach-Object { [string]$_.file } | Select-Object -Unique | Select-Object -First 8)
            $card = $null
            $pp = Find-ProjectByDir $pd
            if ($pp) { $card = Project-Card $pp }
            $uncovered += ,@{ dir = $pd; changes = $g.Count; files = $files; project = $card }
        }
    }
    # Deterministic short-circuit: every busy folder already has a task (or a
    # closed one) - nothing a model could add, so none is called.
    if ($uncovered.Count -eq 0) {
        $msg = 'skipped: every active folder is covered by a task - zero AI tokens spent' + "`r`n" +
            ('[timing] check total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)
        [IO.File]::WriteAllText($log, $msg, $utf8NoBom)
        exit 0
    }
    $newDirs = @($uncovered | ForEach-Object { [string]$_.dir })
    $digest = @{
        now = $now
        target = 'NEWTASKS'
        uncovered = $uncovered
        topDirs = @($top | ForEach-Object { '{0}x {1}' -f $_.Count, $_.Name })
        openTasks = @($open | ForEach-Object { @{ title = [string]$_.title; dir = [string]@(AsArr $_.dirs)[0] } })
        doneTitles = @($closedTitles | Select-Object -Last 20)
    }
    [IO.File]::WriteAllText($digestPath, ($digest | ConvertTo-Json -Depth 6), $utf8NoBom)
} elseif ($Generate) {
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
    $events = @(Get-RecentEvents)

    $activeTasks = @($kanban.tasks | Where-Object { -not $_.done })
    if ($TaskId) {
        $activeTasks = @($activeTasks | Where-Object { $_.id -eq $TaskId })
    } elseif ($idSet.Count -gt 0) {
        # A picked set: the same per-task digest as a full check, only over these.
        $activeTasks = @($activeTasks | Where-Object { $idSet -contains [string]$_.id })
        if ($activeTasks.Count -eq 0) {
            [IO.File]::WriteAllText($log, 'skipped: none of the picked tasks are active - zero AI tokens spent', $utf8NoBom)
            exit 0
        }
    }

    # How many live cards watch each folder. One card alone owns everything its
    # folder does; four cards in one repo own nothing until a name matches.
    $dirTaskCount = @{}
    foreach ($at in @($kanban.tasks | Where-Object { -not $_.done })) {
        if ($at.PSObject.Properties['dirs'] -and $at.dirs) {
            foreach ($dd in @($at.dirs)) {
                $k = ([string]$dd).ToLowerInvariant()
                if ($dirTaskCount.ContainsKey($k)) { $dirTaskCount[$k] = $dirTaskCount[$k] + 1 } else { $dirTaskCount[$k] = 1 }
            }
        }
    }

    $projCards = @{}
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
            $ranked = @($matched | Sort-Object ts -Descending)
            $real = @($ranked | Where-Object { -not (Is-Noise ([string]$_.file)) })
            if ($real.Count -gt 0) { $ranked = $real }
            $changes = @($ranked | Select-Object -First 5 |
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
        $commitDetail = @()
        $scanPath = Join-Path $base ('scans\' + [string]$t.id + '.json')
        if ($dirs.Count -gt 0) {
            if (Test-Path $scanPath) {
                try {
                    $scan = Get-Content $scanPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $sdir = [string]$scan.dir
                    if ($scan.isGit -and (Test-Path $sdir)) {
                        $range = [string]$scan.head + '..HEAD'
                        $newCommits = @(git -C $sdir log --oneline $range 2>$null | Select-Object -First 10 | ForEach-Object { [string]$_ })
                        # "feat(billing): a bilingual invoice" names no file, so a
                        # commit can only be tied to a task through what it touched.
                        $commitDetail = @()
                        foreach ($cl in $newCommits) {
                            $h = ([string]$cl).Split(' ')[0]
                            if (-not $h) { continue }
                            $cf = @(git -C $sdir show --pretty=format: --name-only $h 2>$null |
                                Where-Object { $_ } | Select-Object -First 40 | ForEach-Object { [string]$_ })
                            $commitDetail += ,@{ line = [string]$cl; files = $cf }
                        }
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
        }

        $subtasks = @()
        if ($t.PSObject.Properties['subtasks'] -and $t.subtasks) {
            $subtasks = @($t.subtasks | Select-Object -First 15 |
                ForEach-Object { @{ text = [string]$_.text; done = [bool]$_.done } })
        }
        # What the linked folder actually IS - without it the model can only
        # comment on how many bytes moved.
        # One card per project, referenced by name: a project's cards all share
        # one repo, so a per-project shard used to carry the same card N times.
        $projName = $null
        if ($dirs.Count -gt 0) {
            $pp = Find-ProjectByDir ([string]$dirs[0])
            if ($pp) {
                $projName = [string]$pp.name
                if (-not $projCards.ContainsKey($projName)) { $projCards[$projName] = Project-Card $pp -Full:$Replan }
            }
        }

        $hasFolderSignal = $changeCount -gt 0
        if ($scanDiff) {
            foreach ($k in @('newCommits', 'changedFiles', 'dirtyNow', 'newFiles', 'modifiedFiles')) {
                if ($scanDiff.ContainsKey($k) -and @($scanDiff[$k]).Count -gt 0) { $hasFolderSignal = $true }
            }
        }

        # Split the folder's activity into what belongs to THIS task and what
        # merely happened next to it.
        $kw = Task-Keywords $t
        $pool = @()
        if ($scanDiff) {
            foreach ($k in @('changedFiles', 'dirtyNow', 'newFiles', 'modifiedFiles')) {
                if ($scanDiff.ContainsKey($k)) { $pool += @($scanDiff[$k]) }
            }
        }
        $pool += @($changes | ForEach-Object { [string]$_.file })
        $clean = @($pool | Where-Object { -not (Is-Noise ([string]$_)) })
        $myFiles = @(Match-Evidence $kw $clean)
        $nearFiles = @(Match-Evidence (Task-Stems $kw) $clean | Where-Object { $myFiles -notcontains $_ })
        $myCommits = New-Object System.Collections.Generic.List[string]
        foreach ($cd in $commitDetail) {
            $hitFiles = @(Match-Evidence $kw @($cd.files | Where-Object { -not (Is-Noise ([string]$_)) }))
            $subjHit = @(Match-Evidence $kw @([string]$cd.line))
            if ($hitFiles.Count -gt 0) { $myCommits.Add(([string]$cd.line) + ' -> ' + (($hitFiles | Select-Object -First 3) -join ', ')) }
            elseif ($subjHit.Count -gt 0) { $myCommits.Add([string]$cd.line) }
        }
        $myCommits = @($myCommits | Select-Object -First 6)
        $shared = $false
        if ($dirs.Count -gt 0) {
            $dk = ([string]$dirs[0]).ToLowerInvariant()
            if ($dirTaskCount.ContainsKey($dk) -and $dirTaskCount[$dk] -gt 1) { $shared = $true }
        }
        if (($myFiles.Count -gt 0 -or $myCommits.Count -gt 0) -or (-not $shared -and $hasFolderSignal)) {
            $evidenceIds[[string]$t.id] = $true
        }

        @{
            id = [string]$t.id; title = [string]$t.title; status = [string]$t.status
            desc = $desc; dirs = $dirs; subtasks = $subtasks
            changeCount = $changeCount; changes = $changes; comments = $comments
            scanDiff = $scanDiff; project = $projName
            mine = @{ files = $myFiles; commits = $myCommits }
            related = @($nearFiles | Select-Object -First 6)
            sharesFolder = $shared
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
    # A scoped run (one project's shard) asks only about ITS tasks: an event in
    # some other project is not a reason to spend tokens on this one, or every
    # shard would run whenever anything at all moved.
    $scoped = [bool]($TaskId -or $idSet.Count -gt 0)
    $signal = (-not $scoped) -and $events.Count -gt 0
    $doneNeedsEvidence = $true
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
        # Only a whole-board check may propose new tasks: a scoped run has not
        # seen the rest of the board and would duplicate what is already there.
        target = if ($TaskId) { $TaskId } elseif ($idSet.Count -gt 0) { 'SCOPED' } else { 'ALL' }
        tasks = $digestTasks
        projects = @($projCards.Values)
    }
    # topDirs/doneTitles exist only to place and dedupe NEW tasks, which a
    # scoped run may not create - so a shard carries its own tasks and their
    # project, nothing from the rest of the board.
    if (-not $scoped) {
        $digest.topDirs = $topDirs
        $digest.doneTitles = $doneTitlesAll
    }
    [IO.File]::WriteAllText($digestPath, ($digest | ConvertTo-Json -Depth 8), $utf8NoBom)
}
$allowNewTasks = -not ($scoped -and -not ($Replan -and $TaskId))

# ---------- Claude: digest in, tiny patch out ----------
# A digest is a few KB by design. Anything larger means a serialization bug
# upstream; sending it would burn tokens and fail anyway.
$digestSize = (Get-Item $digestPath -ErrorAction SilentlyContinue).Length
if ($digestSize -gt 1MB) {
    [IO.File]::WriteAllText($log, ('skipped: digest too large ({0:N0} bytes) - not sent to the model' -f $digestSize), $utf8NoBom)
    exit 0
}

$promptFile = if ($NewTasksOnly) { 'prompt-task-newtasks.md' }
              elseif ($Generate) { 'prompt-task-generate.md' }
              elseif ($Command) { 'prompt-task-command.md' }
              elseif ($Replan -and $TaskId) { 'prompt-task-replan.md' }
              else { 'prompt-check.md' }
$isTaskReplan = [bool]($Replan -and $TaskId)
$isRoutineCheck = -not ($Generate -or $Command -or $isTaskReplan -or $NewTasksOnly)
$valid = @('urgent', 'important', 'planning', 'delayed', 'active')

# The digest goes INTO the prompt, compressed: no Read turn, no file path for
# the model to get wrong. The pretty file stays on disk for the "show context"
# view in the app. {{DIGEST}} is replaced last so nothing inside the digest is
# ever mistaken for a placeholder.
$digestJson = $digest | ConvertTo-Json -Depth 8 -Compress
$prompt = ([string](Get-Content (Join-Path $app $promptFile) -Raw -Encoding UTF8)).
    Replace('{{NOW}}', $now).
    Replace('{{DIGEST}}', $digestJson)

# ---------- the answer's shape, enforced by the CLI (--json-schema) ----------
function S-Str { return @{ type = 'string' } }
function S-StrArr { return @{ type = 'array'; items = @{ type = 'string' } } }
function S-Obj($props, [string[]]$req) {
    return @{ type = 'object'; properties = $props; required = $req; additionalProperties = $false }
}
$sStatus = @{ type = 'string'; enum = $valid }

if ($NewTasksOnly) {
    # newTasks only: there is no updates field for the model to fill.
    $schema = S-Obj @{
        newTasks = @{ type = 'array'; items = (S-Obj @{
            id = (S-Str); title = (S-Str); desc = (S-Str); status = $sStatus; dir = (S-Str); subtasks = (S-StrArr)
        } @('id', 'title', 'desc', 'dir', 'subtasks')) }
    } @('newTasks')
} elseif ($Generate) {
    $schema = S-Obj @{
        newTasks = @{ type = 'array'; items = (S-Obj @{
            id = (S-Str); title = (S-Str); desc = (S-Str); status = $sStatus; dir = (S-Str); subtasks = (S-StrArr)
        } @('id', 'title', 'desc', 'dir', 'subtasks')) }
    } @('newTasks')
} elseif ($Command) {
    $schema = S-Obj @{
        updates = @{ type = 'array'; items = (S-Obj @{
            id = (S-Str); title = (S-Str); desc = (S-Str); status = $sStatus; subtasks = (S-StrArr)
            done = @{ type = 'boolean' }; note = (S-Str); reply = (S-Str)
        } @('id', 'reply')) }
        execute = @{ type = 'boolean' }
        newTasks = @{ type = 'array'; items = (S-Obj @{
            id = (S-Str); title = (S-Str); desc = (S-Str); status = $sStatus; dir = (S-Str); subtasks = (S-StrArr)
        } @('id', 'title')) }
    } @('updates')
} elseif ($isTaskReplan) {
    $schema = S-Obj @{
        updates = @{ type = 'array'; items = (S-Obj @{
            id = (S-Str); desc = (S-Str); subtasks = (S-StrArr); status = $sStatus; note = (S-Str)
        } @('id', 'desc', 'subtasks', 'note')) }
        newTasks = @{ type = 'array'; items = (S-Obj @{
            id = (S-Str); title = (S-Str); desc = (S-Str); status = $sStatus
        } @('id', 'title')) }
    } @('updates')
} else {
    $props = @{
        updates = @{ type = 'array'; items = (S-Obj @{
            id = (S-Str); note = (S-Str); status = $sStatus; done = @{ type = 'boolean' }
        } @('id', 'note')) }
    }
    # A scoped shard gets no newTasks field at all: the schema, not the
    # prompt, is what keeps it from inventing tasks it cannot dedupe.
    if ($allowNewTasks) {
        $props.newTasks = @{ type = 'array'; items = (S-Obj @{
            id = (S-Str); title = (S-Str); desc = (S-Str); status = $sStatus; dir = (S-Str)
        } @('id', 'title', 'dir')) }
    }
    $schema = S-Obj $props @('updates')
}
$schemaJson = $schema | ConvertTo-Json -Depth 12 -Compress

# ---------- script-side validation (what a schema cannot express) ----------
# Ids the answer may touch: exactly the tasks this run put in front of it.
$validIds = @()
if ($Command -or $isTaskReplan) { $validIds = @($TaskId) }
elseif (-not ($Generate -or $NewTasksOnly)) { $validIds = @($digestTasks | ForEach-Object { [string]$_.id }) }
$genDirs = @()
if ($Generate) { $genDirs = @($genProjects | ForEach-Object { [string]$_.dir }) }
if ($NewTasksOnly) { $genDirs = $newDirs }

# "grew 3 days running" is the note a model writes when it has nothing to say.
# It is rejected only when it names nothing concrete (file, commit, identifier).
# CONCRETE_RE is matched case-SENSITIVELY: CamelCase is the signal, and the
# default -match would read any capitalised word ("Folder") as an identifier.
$TREND_RE = '(?i)\b(grew|grow(s|ing)?|shr(ink|inks|inking|ank|unk)|score|trend(s|ing)?|in a row|(days?|runs?) running|\d+(st|nd|rd|th) (day|run)|keeps? (growing|shrinking|changing)|(more|less) active|activity (rose|fell|increased|decreased|dropped|grew))\b'
$CONCRETE_RE = '[A-Za-z0-9_\-]+\.[A-Za-z]{1,6}\b|\b[0-9a-f]{7,40}\b|`[^`]+`|\b[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*\b|\b[a-z0-9]+_[a-z0-9_]+\b|\b(feat|fix|chore|refactor|docs|test|build)(\([^)]*\))?:'
$MONITOR_RE = '(?i)\b(check on|keep an eye|monitor|observe|work out what|clarify what|analy[sz]e (the )?(folder|activity))\b'

function Test-Patch($p) {
    $errs = New-Object System.Collections.Generic.List[string]
    if (-not $p) { $errs.Add('the answer was empty'); return $errs.ToArray() }
    $ups = @(AsArr $p.updates | Where-Object { $_ -and $_.PSObject.Properties['id'] })
    $seen = @{}
    foreach ($u in $ups) {
        $id = [string]$u.id
        if (-not $id) { $errs.Add('an update has an empty id'); continue }
        if ($validIds -notcontains $id) { $errs.Add("update id '$id' is not a task in the digest - use only the ids given"); continue }
        $seen[$id] = $true
        if ($u.PSObject.Properties['status'] -and $u.status -and $valid -notcontains [string]$u.status) {
            $errs.Add("update $id has status '$($u.status)' - allowed: " + ($valid -join ', '))
        }
        if ($isRoutineCheck) {
            $note = ([string]$u.note).Trim()
            if (-not $note) { $errs.Add("update $id has an empty note - write one or drop the update") }
            elseif ($note -match $TREND_RE -and $note -cnotmatch $CONCRETE_RE) {
                $errs.Add("update $id note is a size/score trend, not evidence - name the file or commit, or drop the update")
            }
            # The same gate the apply step enforces, surfaced to the model so
            # the retry can fix the rest of the answer instead of losing it.
            if ($u.PSObject.Properties['done'] -and $u.done -eq $true -and -not $evidenceIds.ContainsKey($id)) {
                $errs.Add("update $id sets done but mine.files and mine.commits are empty and the folder is shared - remove done")
            }
        }
        if ($isTaskReplan) {
            if (@(AsArr $u.subtasks | Where-Object { ([string]$_).Trim() }).Count -lt 2) { $errs.Add("update $id needs 3-8 concrete subtasks") }
            if ($u.PSObject.Properties['done']) { $errs.Add('a replan never sets done') }
        }
        if ($Command -and -not ([string]$u.reply).Trim()) { $errs.Add("update $id has an empty reply - reply is required") }
    }
    if (($Command -or $isTaskReplan) -and -not $seen.ContainsKey($TaskId)) {
        $errs.Add("the answer must contain one update with id '$TaskId'")
    }
    $nts = @(AsArr $p.newTasks | Where-Object { $_ -and $_.PSObject.Properties['title'] })
    foreach ($n in $nts) {
        $title = ([string]$n.title).Trim()
        # The digest is inlined as JSON, and the model sometimes copies a path
        # with its JSON escaping ("C:\\Users"). Undo that here instead of
        # spending a retry on it; the fixed value is what gets written.
        if ($n.PSObject.Properties['dir'] -and $n.dir) {
            $fixed = ([string]$n.dir).Replace('\\', '\')
            foreach ($gd in $genDirs) { if ($gd -ieq $fixed) { $fixed = $gd } }
            $n.dir = $fixed
        }
        if (-not $title -or -not ([string]$n.id).Trim()) { $errs.Add('a new task has an empty id or title'); continue }
        if ($title -match $MONITOR_RE) { $errs.Add("new task '$title' is a monitoring/observation task - forbidden") }
        if (($Generate -or $NewTasksOnly) -and $genDirs -notcontains [string]$n.dir) { $errs.Add("new task '$title' has dir '$($n.dir)' - copy one dir exactly from the digest") }
    }
    if ($NewTasksOnly -and @(AsArr $p.updates | Where-Object { $_ }).Count -gt 0) { $errs.Add('this run creates new tasks only - updates are not allowed') }
    if (($Generate -or $NewTasksOnly) -and $nts.Count -gt 3) { $errs.Add('at most 3 new tasks') }
    return $errs.ToArray()
}

# A two-call run would otherwise be billed as its last call only: main.js reads
# usage from the LAST result line in the log. One summed line keeps the AI
# usage page honest; it carries the last call's outcome fields unchanged.
function Write-UsageTotal($envs) {
    if ($envs.Count -lt 2) { return }
    $last = $envs[$envs.Count - 1]
    $sum = [ordered]@{ input_tokens = [int64]0; cache_creation_input_tokens = [int64]0; cache_read_input_tokens = [int64]0; output_tokens = [int64]0 }
    $cost = 0.0; $turns = 0; $ms = [int64]0
    foreach ($e in $envs) {
        if ($e.usage) {
            foreach ($k in @($sum.Keys)) { if ($e.usage.PSObject.Properties[$k]) { $sum[$k] = $sum[$k] + [int64]$e.usage.$k } }
        }
        $cost += [double]$e.total_cost_usd; $turns += [int]$e.num_turns; $ms += [int64]$e.duration_ms
    }
    $agg = [ordered]@{
        type = 'result'; subtype = [string]$last.subtype; is_error = [bool]$last.is_error
        num_turns = $turns; duration_ms = $ms; total_cost_usd = $cost; usage = $sum
        result = ('(usage summed over ' + $envs.Count + ' model calls)')
    }
    if ($last.PSObject.Properties['errors'] -and $last.errors) { $agg.errors = @($last.errors) }
    Add-Content -Path $log -Value ($agg | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8
}

Set-Location $base
$system = 'You are the DailyBrief kanban assistant inside a desktop app pipeline. Everything you need is in the message; you have no tools and need none. Answer only with the structured output. Write in English.'
$envelopes = New-Object System.Collections.Generic.List[object]
$res = Invoke-ClaudeLean -Prompt $prompt -Log $log -System $system -Model 'haiku' -Schema $schemaJson -MaxTurns 3
if ($res.envelope) { $envelopes.Add($res.envelope) }
$errs = @()
if ($res.ok) { $errs = @(Test-Patch $res.data) } else { $errs = @([string]$res.error) }

# One retry, with the reasons attached. A second miss applies nothing: half of
# a wrong answer on the board is worse than no answer.
if ($errs.Count -gt 0) {
    Add-Content $log ('[info] answer rejected, retrying once: ' + ($errs -join ' | '))
    $prevAnswer = '(none)'
    if ($res.data) { $prevAnswer = $res.data | ConvertTo-Json -Depth 10 -Compress }
    $retryPrompt = $prompt + "`n`n## Your previous answer was rejected`n" +
        (($errs | ForEach-Object { '- ' + $_ }) -join "`n") +
        "`n`nPrevious answer:`n" + $prevAnswer +
        "`n`nAnswer again with every listed problem fixed. An update you cannot fix is left out."
    $res = Invoke-ClaudeLean -Prompt $retryPrompt -Log $log -System $system -Model 'haiku' -Schema $schemaJson -MaxTurns 3
    if ($res.envelope) { $envelopes.Add($res.envelope) }
    if ($res.ok) { $errs = @(Test-Patch $res.data) } else { $errs = @([string]$res.error) }
}
Write-UsageTotal $envelopes

# The script writes the patch file from the structured answer - same name and
# shape as when the model wrote it, so everything below is unchanged.
if ($errs.Count -gt 0) {
    Add-Content $log ('[warn] model answer rejected after retry - nothing applied: ' + ($errs -join ' | '))
} else {
    [IO.File]::WriteAllText($patchPath, ($res.data | ConvertTo-Json -Depth 10), $utf8NoBom)
}

# ---------- Apply the patch (only the script ever rewrites kanban.json) ----------
# Several checks can finish around the same time, each with its own patch
# (per-project shards finish together by design). The board lock serializes
# the read-merge-write, and kanban.json is re-read INSIDE it so this run
# merges onto whatever the previous writer just saved instead of the copy it
# read at startup.
$patch = $null
$touched = New-Object System.Collections.Generic.List[string]
if (Test-Path $patchPath) {
    try {
        $patch = ([string](Get-Content $patchPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        $script:newScans = New-Object System.Collections.Generic.List[object]

        Invoke-WithBoardLock {
            $fresh = Read-Kanban

            # Runs that only create tasks never edit existing ones.
            $ups = @($patch.updates)
            if ($Generate -or $NewTasksOnly) { $ups = @() }
            foreach ($u in $ups) {
                if (-not $u -or -not $u.id) { continue }
                # Belt and braces after validation: never touch a task this run
                # did not show the model (a shard must stay inside its project).
                if ($validIds.Count -gt 0 -and $validIds -notcontains [string]$u.id) { continue }
                $t = $fresh.tasks | Where-Object { $_.id -eq $u.id } | Select-Object -First 1
                if (-not $t) { continue }
                $touched.Add([string]$u.id)
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
                # A comment ("this one is finished") is the user's own word and
                # closes the task outright. A routine check has to point at
                # something that moved in the task's own folder; a replan never
                # closes anything.
                if ($u.PSObject.Properties['done'] -and $u.done -eq $true) {
                    if ($isTaskReplan) {
                        Add-Content $log ('[warn] refused done for ' + $u.id + ': a replan never closes a task')
                    } elseif ($doneNeedsEvidence -and -not $Command -and -not $evidenceIds.ContainsKey([string]$u.id)) {
                        Add-Content $log ('[warn] refused done for ' + $u.id + ': no commit/file activity for this task in this run')
                    } else {
                        $t.done = $true
                    }
                }
                $t.updatedAt = $stamp
            }

            # Only a run that saw the whole board may add to it: a per-project
            # shard cannot dedupe against what it was never shown.
            $nts = @($patch.newTasks | Where-Object { $_ })
            if (-not $allowNewTasks -and $nts.Count -gt 0) {
                Add-Content $log ('[info] scoped run: ' + $nts.Count + ' new task(s) ignored')
                $nts = @()
            }
            if ($Generate -or $NewTasksOnly) { $nts = @($nts | Select-Object -First 3) }
            # Dedupe against ids (tasks + archive) and normalized titles (tasks +
            # archive + done) so a reworded near-duplicate can't slip through.
            $freshArchive = if ($fresh.PSObject.Properties['archive'] -and $fresh.archive) { @($fresh.archive) } else { @() }
            $freshArchive = @($freshArchive + @(Get-ColdArchive))
            $existingIds = @(@($fresh.tasks | ForEach-Object { [string]$_.id }) + @($freshArchive | ForEach-Object { [string]$_.id }))
            $existingTitlesNorm = @(@($fresh.tasks | ForEach-Object { Norm-Title $_.title }) + @($freshArchive | ForEach-Object { Norm-Title $_.title }))
            foreach ($n in $nts) {
                if (-not $n -or -not $n.id -or -not $n.title) { continue }
                $nTitleNorm = Norm-Title $n.title
                if ($existingIds -contains [string]$n.id -or $existingTitlesNorm -contains $nTitleNorm) { continue }
                # A split the user ordered in a comment is never "too similar".
                $similar = $false
                if (-not $Command) {
                    foreach ($et in $existingTitlesNorm) { if (Similar-Title $nTitleNorm $et) { $similar = $true; break } }
                }
                if ($similar) { Add-Content $log ('[info] new task skipped, too close to an existing title: ' + $n.title); continue }
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
                if ($newDirs.Count -gt 0) { $script:newScans.Add(@([string]$n.id, [string]$newDirs[0])) }
                $fresh.tasks = @($fresh.tasks) + $nt
                $existingIds += [string]$n.id
                $existingTitlesNorm += $nTitleNorm
            }

            [IO.File]::WriteAllText($kanbanPath, ($fresh | ConvertTo-Json -Depth 10), $utf8NoBom)

            # Folders to re-baseline, read from the board as just written.
            foreach ($tid in @($touched | Select-Object -Unique)) {
                $tt = $fresh.tasks | Where-Object { $_.id -eq $tid } | Select-Object -First 1
                if ($tt -and $tt.PSObject.Properties['dirs'] -and @($tt.dirs).Count -gt 0) {
                    $script:newScans.Add(@([string]$tid, [string]@($tt.dirs)[0]))
                }
            }
        }
        Remove-Item $patchPath -Force

        # Only now does the baseline move, and only for the tasks this run had
        # something to say about (plus newborn tasks). Re-baselining every task
        # on every check let the first run eat the evidence and left every later
        # one blind. scans\ is per task, not the board: done outside the lock.
        foreach ($sc in $script:newScans) {
            $null = & (Join-Path $app 'scan-folder.ps1') -TaskId ([string]$sc[0]) -Dir ([string]$sc[1]) 2>$null
        }
    } catch {
        Add-Content $log ('[warn] patch apply failed: ' + $_.Exception.Message)
    }
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
    try {
        Invoke-WithBoardLock {
            $fresh2 = Read-Kanban
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
        }
    } catch {
        Add-Content $log ('[warn] comment ack failed: ' + $_.Exception.Message)
    }
}

Add-Content $log ('[timing] check total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)

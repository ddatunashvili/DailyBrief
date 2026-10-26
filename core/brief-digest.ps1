# Builds the daily brief digest: everything the morning run needs, compressed
# into ONE json that daily-brief.ps1 inlines into the prompt. That makes this
# file nearly the whole token bill of the run, so every field here is one
# core/prompt.md (or prompt-replan.md) actually reads, and every list is capped
# at what the model can use. Zero AI tokens spent here.
# ASCII-only on purpose (PS 5.1 encoding).
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Today = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$Replan,
    # Full project cards: projects bound to an open task always get one, then
    # the most active ones up to this many in total.
    [int]$MaxFullCards = 6,
    # Active projects past the full-card budget travel as a one-line
    # {name, dir, lastActive}; past this many more they are dropped.
    [int]$MaxSlimCards = 8,
    [int]$ActiveDays = 14
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Every "recent" window is measured from the digest's own day, not the
# clock: a digest built for a past date (replays, the eval harness) must see
# the same board it would have seen that morning.
$refDay = [datetime]::MinValue
if (-not [datetime]::TryParseExact($Today, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$refDay)) { $refDay = (Get-Date).Date }
$refEnd = $refDay.AddDays(1)

# PS 5.1 serializes an EMPTY array inside an object as {}, so a round-tripped
# "no items" list comes back as an empty PSCustomObject.
function AsArr($v) {
    if ($null -eq $v) { return @() }
    if ($v -is [array]) { return $v }
    if ($v -is [string]) { return @($v) }
    if ($v -is [PSCustomObject] -and @($v.PSObject.Properties).Count -eq 0) { return @() }
    return @($v)
}

function Cut([string]$s, [int]$n) {
    $t = ($s + '')
    if ($t.Length -gt $n) { return $t.Substring(0, $n) }
    return $t
}

function Parse-Date([string]$s) {
    $ts = [datetime]::MinValue
    if ($s -and [datetime]::TryParse($s, [ref]$ts)) { return $ts }
    return $null
}

# Markdown the model reads as context: HTML comments are notes for the human
# editing the file, and runs of blank lines are pure tokens. The cut lands on
# a line boundary so no bullet arrives half-written. The [string] cast is
# load-bearing: Get-Content -Raw hands back a string decorated with
# PSPath/Provider note properties, and ConvertTo-Json would serialize that
# whole provider graph.
function Read-Markdown([string]$path, [int]$max) {
    if (-not (Test-Path $path)) { return '' }
    $t =([string](Get-Content $path -Raw -Encoding UTF8)).TrimStart([char]0xFEFF)
    $t = [regex]::Replace($t, '(?s)<!--.*?-->', '')
    $t = [regex]::Replace($t, '[ \t]+(\r?\n)', '$1')
    $t = [regex]::Replace($t, '(\r?\n){3,}', "`n`n").Trim()
    if ($t.Length -le $max) { return $t }
    $cut = $t.LastIndexOf("`n", $max)
    if ($cut -lt ($max / 2)) { $cut = $max }
    # Said in-band: the morning run may rewrite GOALS.md wholesale, and it has
    # to know there is more of the file than it was shown.
    $rest = @($t.Substring($cut) -split "`n" | Where-Object { $_.Trim() }).Count
    return $t.Substring(0, $cut).TrimEnd() + "`n[... $rest more line(s) not shown - keep them unchanged]"
}

# The [string] cast on every line is load-bearing for the same reason as
# above: Get-Content hands back strings DECORATED with PSPath/PSProvider note
# properties, and ConvertTo-Json serializes that entire provider graph instead
# of the line (observed: the digest never finished writing). Score columns are
# space-padded for humans; the padding is collapsed here.
function Read-Lines([string]$path, [int]$count) {
    if (-not (Test-Path $path)) { return @() }
    return @(Get-Content $path -Encoding UTF8 -ErrorAction SilentlyContinue |
        ForEach-Object { (([string]$_).TrimStart([char]0xFEFF) -replace '\s+', ' ').Trim() } |
        Where-Object { $_ } | Select-Object -First $count)
}

# Nulls filtered: an empty pipeline handed over as an argument arrives as
# $null, and @($null) counts one item - it serialized as [null].
function Add-IfAny($map, [string]$key, $value) {
    $v = @(@($value) | Where-Object { $null -ne $_ })
    if ($v.Count -gt 0) { $map[$key] = $v }
}

# Case-insensitive, order-preserving dedupe of a string list.
function Unique-Strings($items) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    return @(@($items) | Where-Object { $_ -and $seen.Add([string]$_) })
}

# Build output and machine-written files say nothing about what the user is
# doing: compiled views, logs, hashed bundles, caches. A recentFiles list
# full of them pushed the real source files out of the five slots it had.
$noiseRe = '(?i)(^|[\\/])(node_modules|vendor|dist|build|out|\.next|\.nuxt|\.cache|cache|logs?|coverage|__pycache__|\.git)([\\/]|$)|[\\/]framework[\\/]views[\\/]|\.(log|map|lock|tmp|pyc)$|[.-][0-9a-f]{8,}\.(js|css|mjs)$|(^|[\\/])[0-9a-f]{32,}\.php$'

# ---------- board ----------
$kanban = $null
try { $kanban = ([string](Get-Content (Join-Path $base 'kanban.json') -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch {}
$allTasks = if ($kanban) { @(AsArr $kanban.tasks) } else { @() }
$archive  = if ($kanban) { @(AsArr $kanban.archive) } else { @() }

# createdBy/updatedAt never reach a decision the prompt asks for, so they stay
# home. Field names below are exactly the ones core/prompt.md lists.
$openTasks = @($allTasks | Where-Object { -not $_.done } | ForEach-Object {
    $t = [ordered]@{
        id = [string]$_.id
        title = [string]$_.title
        status = [string]$_.status
    }
    # 250 is also the most the model may write back into a desc, so a desc it
    # rewrites is never built from less than it is allowed to say.
    $d = Cut ([string]$_.desc) 250
    if ($d) { $t.desc = $d }
    Add-IfAny $t 'dirs' (Unique-Strings (AsArr $_.dirs))
    # Only the open steps matter for planning; a finished checklist item is
    # evidence, so its count travels instead of its text.
    $subs = @(AsArr $_.subtasks)
    if ($subs.Count) {
        $t.subtasksDone = @($subs | Where-Object { $_.done }).Count
        $t.subtasksTotal = $subs.Count
        Add-IfAny $t 'openSubtasks' (@($subs | Where-Object { -not $_.done } | Select-Object -First 8 |
            ForEach-Object { Cut ([string]$_.text) 160 }))
    }
    Add-IfAny $t 'aiNotes' (@(AsArr $_.aiNotes | Select-Object -Last 2 | ForEach-Object { Cut ([string]$_.text) 160 }))
    # David's own words outrank everything else on the card: never trimmed
    # harder than this.
    Add-IfAny $t 'userComments' (@(AsArr $_.comments | Where-Object { [string]$_.by -eq 'user' } |
        Select-Object -Last 3 | ForEach-Object { Cut ([string]$_.text) 300 }))
    $t
})
$openTitles = Unique-Strings @($openTasks | ForEach-Object { [string]$_.title })

# Closed work is planning input (what is already covered) but never plan
# content, so titles are enough - and only while they are still recent.
$cutoff = $refEnd.AddDays(-10)
$doneRecent = Unique-Strings @($allTasks | Where-Object {
    if (-not $_.done) { return $false }
    $ts = Parse-Date ([string]$_.updatedAt)
    if ($ts) { return $ts -gt $cutoff }
    return $true
} | Select-Object -Last 20 | ForEach-Object { Cut ([string]$_.title) 100 })

# Deleted tasks the model must never recreate. The board compactor moves old
# ones to kanban-archive.json, so read both - newest last, like the board.
$archiveAll = @($archive)
try {
    $ka = ([string](Get-Content (Join-Path $base 'kanban-archive.json') -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $archiveAll = @(@(AsArr $ka.archive) + $archiveAll)
} catch {}
$doneSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($x in @($doneRecent) + @($openTitles)) { $null = $doneSet.Add([string]$x) }
$archiveTitles = @(Unique-Strings @($archiveAll | ForEach-Object { Cut ([string]$_.title) 100 }) |
    Where-Object { -not $doneSet.Contains([string]$_) } | Select-Object -Last 20)

# ---------- project registry ----------
$projects = @()
try { $projects = @((([string](Get-Content (Join-Path $base 'projects.json') -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json).projects) } catch {}

# A project is bound when an open task links its folder, or a folder inside it.
$boundDirs = @(foreach ($t in $openTasks) { foreach ($d in @($t.dirs)) { ([string]$d).TrimEnd('\').ToLowerInvariant() } })
function Is-Bound([string]$dir) {
    $p = $dir.TrimEnd('\').ToLowerInvariant()
    foreach ($b in $boundDirs) {
        if ($b -eq $p -or $b.StartsWith($p + '\') -or $p.StartsWith($b + '\')) { return $true }
    }
    return $false
}

# Activity = a commit or real file churn inside the window. A lone mtime is
# not activity: a sync client touching every folder at once made forty
# projects look "active today".
$windowStart = $refEnd.AddDays(-$ActiveDays)
$scored = @(foreach ($p in $projects) {
    if (-not $p.dir) { continue }
    $touched = Parse-Date ([string]$p.lastTouched)
    $committed = Parse-Date ([string]$p.lastCommitAt)
    $last = $touched
    if ($committed -and (-not $last -or $committed -gt $last)) { $last = $committed }
    $recentCommit = ($committed -and $committed -ge $windowStart -and $committed -lt $refEnd)
    $recentChurn = ($touched -and $touched -ge $windowStart -and [int]$p.changed14d -ge 20)
    [pscustomobject]@{
        p = $p; bound = (Is-Bound ([string]$p.dir)); active = ($recentCommit -or $recentChurn)
        last = $last; churn = [int]$p.changed14d
    }
})
# Bound first (the board is asking about them), then by churn, then recency.
$ranked = @($scored | Where-Object { $_.bound -or $_.active } |
    Sort-Object @{e = { [int]$_.bound }; Descending = $true}, @{e = 'churn'; Descending = $true}, @{e = 'last'; Descending = $true})
# Stale registry (the app was off for weeks): nothing is "active", but a plan
# with no project evidence at all is worse than one built on the latest work.
if ($ranked.Count -eq 0) {
    $ranked = @($scored | Where-Object { $_.last } | Sort-Object last -Descending | Select-Object -First 5)
}

$seenDir = @{}
$fullCards = New-Object System.Collections.Generic.List[object]
$slimCards = New-Object System.Collections.Generic.List[object]
foreach ($s in $ranked) {
    $p = $s.p
    $key = ([string]$p.dir).ToLowerInvariant()
    if ($seenDir[$key]) { continue }
    $seenDir[$key] = $true
    if ($s.bound -or $fullCards.Count -lt $MaxFullCards) {
        $c = [ordered]@{
            name = [string]$p.name
            dir = [string]$p.dir
        }
        Add-IfAny $c 'stack' (AsArr $p.stack)
        if ($p.isGit) {
            if ($p.branch) { $c.branch = [string]$p.branch }
            Add-IfAny $c 'lastCommits' (Unique-Strings @(AsArr $p.lastCommits | Select-Object -First 8 | ForEach-Object { Cut ([string]$_) 120 }))
            if ([int]$p.dirtyCount -gt 0) { $c.dirtyCount = [int]$p.dirtyCount }
            Add-IfAny $c 'dirtySample' (@(AsArr $p.dirtySample | Select-Object -First 10 | ForEach-Object { Cut ([string]$_) 120 }))
        }
        $c.changed14d = [int]$p.changed14d
        Add-IfAny $c 'recentFiles' (@(Unique-Strings @(AsArr $p.recentFiles | ForEach-Object { [string]$_ } |
            Where-Object { $_ -notmatch $noiseRe })) | Select-Object -First 8 | ForEach-Object { Cut $_ 120 })
        Add-IfAny $c 'todoSample' (@(AsArr $p.todoSample | Select-Object -First 8 | ForEach-Object { Cut ([string]$_) 140 }))
        $pd = Cut ([string]$p.pkgDesc) 160
        if ($pd) { $c.pkgDesc = $pd }
        # The readme is there for the project's purpose; with a package
        # description already saying it, its opening line is enough.
        $r = Cut ([string]$p.readme) $(if ($pd) { 120 } else { 300 })
        if ($r -and -not ($pd -and $r.Contains($pd))) { $c.readme = $r }
        $fullCards.Add($c)
    } elseif ($slimCards.Count -lt $MaxSlimCards) {
        $slim = [ordered]@{ name = [string]$p.name; dir = [string]$p.dir }
        if ($s.last) { $slim.lastActive = $s.last.ToString('yyyy-MM-dd') }
        $slimCards.Add($slim)
    }
}
# One list, full cards first: daily-brief.ps1 accepts a new task's dir only if
# it is a projects[].dir, so the one-liners must stay in the same field.
$projectCards = @($fullCards.ToArray()) + @($slimCards.ToArray())

# ---------- yesterday: the last brief, and what was ticked off ----------
$lastBrief = $null
$briefsDir = Join-Path $base 'briefs'
if (Test-Path $briefsDir) {
    $prev = @(Get-ChildItem $briefsDir -Filter '*.json' -File |
        Where-Object { $_.BaseName -lt $Today } | Sort-Object Name -Descending | Select-Object -First 1)
    if ($prev.Count) {
        try {
            $pb = ([string](Get-Content $prev[0].FullName -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
            $lastBrief = [ordered]@{
                date = [string]$pb.date
                tldr = Cut ([string]$pb.tldr) 400
                tasks = @(AsArr $pb.tasks | ForEach-Object { Cut ([string]$_.title) 120 })
            }
        } catch {}
    }
}

# A replan happens mid-day: today's brief already exists and the user has
# ticked things off since. That check state is the whole point of the rerun.
$doneToday = @()
$donePath = Join-Path $base ("done\$Today.json")
if (Test-Path $donePath) {
    try {
        $dj = ([string](Get-Content $donePath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        foreach ($prop in @($dj.PSObject.Properties)) {
            if ($prop.Value -eq $true) { $doneToday += [string]$prop.Name }
        }
    } catch {}
}
$todayBrief = $null
$todayBriefPath = Join-Path $briefsDir ($Today + '.json')
if ($Replan -and (Test-Path $todayBriefPath)) {
    try {
        $tb = ([string](Get-Content $todayBriefPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $todayBrief = [ordered]@{
            tldr = Cut ([string]$tb.tldr) 400
            tasks = @(AsArr $tb.tasks | ForEach-Object {
                [ordered]@{ id = [string]$_.id; title = Cut ([string]$_.title) 120; weight = [int]$_.weight }
            })
        }
    } catch {}
}

# ---------- open questions ----------
# `at` is bookkeeping for the app; the model reads text, project and answer.
$questions = @()
try {
    $qj = ([string](Get-Content (Join-Path $base 'questions.json') -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $questions = @(AsArr $qj.questions | ForEach-Object {
        $q = [ordered]@{ id = [string]$_.id; text = Cut ([string]$_.text) 300 }
        if ($_.project) { $q.project = [string]$_.project }
        $a = Cut ([string]$_.answer) 500
        if ($a) { $q.answer = $a }
        $q
    })
} catch {}

# ---------- activity ----------
# A supporting signal only, and the prompt forbids conclusions drawn from a
# score trend - so today's list plus two earlier days is all it gets. Today's
# activity snapshot is a copy of top-dirs.txt, so it is not sent twice.
$topDirs = @(Read-Lines (Join-Path $base 'top-dirs.txt') 8)
$snapDir = Join-Path $base 'snapshots'
$activityHistory = @()
if (Test-Path $snapDir) {
    $files = @(Get-ChildItem $snapDir -Filter 'activity-*.txt' -File |
        Where-Object { ($_.BaseName -replace '^activity-', '') -lt $Today } |
        Sort-Object Name -Descending | Select-Object -First 2)
    foreach ($f in $files) {
        $activityHistory += [ordered]@{
            date = ($f.BaseName -replace '^activity-', '')
            top = @(Read-Lines $f.FullName 5)
        }
    }
}

# No now/today/mode: the prompt already carries the date, and which prompt
# file is used already says which mode this is.
$digest = [ordered]@{}
$g = Read-Markdown (Join-Path $base 'GOALS.md') 2500
if ($g) { $digest.goals = $g }
$st = Read-Markdown (Join-Path $base 'STATE.md') 2500
if ($st) { $digest.state = $st }
$pr = Read-Markdown (Join-Path $base 'PROGRESS.md') 800
if ($pr) { $digest.progress = $pr }
Add-IfAny $digest 'projects' $projectCards
Add-IfAny $digest 'openTasks' $openTasks
Add-IfAny $digest 'doneRecent' $doneRecent
Add-IfAny $digest 'archiveTitles' $archiveTitles
Add-IfAny $digest 'questions' $questions
Add-IfAny $digest 'topDirs' $topDirs
Add-IfAny $digest 'activityHistory' $activityHistory
Add-IfAny $digest 'doneTodayIds' $doneToday
if ($lastBrief) { $digest.lastBrief = $lastBrief }
if ($todayBrief) { $digest.todayBrief = $todayBrief }

# -Compress on purpose: pretty-printed PS JSON is about twice the bytes, and
# every one of those indent spaces is a token the morning run pays for.
[IO.File]::WriteAllText($Out, ($digest | ConvertTo-Json -Depth 8 -Compress), $utf8NoBom)
'digest: {0:N0} bytes, {1} full + {2} one-line projects, {3} open tasks' -f (Get-Item $Out).Length, $fullCards.Count, $slimCards.Count, $openTasks.Count

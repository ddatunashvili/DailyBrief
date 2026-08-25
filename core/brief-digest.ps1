# Builds the daily brief digest: everything the morning run needs, compressed
# into ONE json file so the model reads a single file instead of opening the
# registry, the board, the snapshots and yesterday's brief one call at a time.
# Zero AI tokens spent here. ASCII-only on purpose (PS 5.1 encoding).
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Today = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$Replan
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

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

# The [string] cast is load-bearing: Get-Content -Raw hands back a string
# decorated with PSPath/Provider note properties, and ConvertTo-Json would
# serialize that whole provider graph.
function Read-Head([string]$path, [int]$max) {
    if (-not (Test-Path $path)) { return '' }
    return Cut ([string](Get-Content $path -Raw -Encoding UTF8)) $max
}

# The [string] cast on every line is load-bearing for the same reason as
# above: Get-Content hands back strings DECORATED with PSPath/PSProvider note
# properties, and ConvertTo-Json serializes that entire provider graph instead
# of the line (observed: the digest never finished writing).
function Read-Lines([string]$path, [int]$count) {
    if (-not (Test-Path $path)) { return @() }
    return @(Get-Content $path -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First $count | ForEach-Object { [string]$_ })
}

function Add-IfAny($map, [string]$key, $value) {
    $v = @($value)
    if ($v.Count -gt 0) { $map[$key] = $v }
}

# ---------- board ----------
$kanban = $null
try { $kanban = Get-Content (Join-Path $base 'kanban.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
$allTasks = if ($kanban) { @(AsArr $kanban.tasks) } else { @() }
$archive  = if ($kanban) { @(AsArr $kanban.archive) } else { @() }

$openTasks = @($allTasks | Where-Object { -not $_.done } | ForEach-Object {
    $t = @{
        id = [string]$_.id
        title = [string]$_.title
        status = [string]$_.status
        createdBy = [string]$_.createdBy
        updatedAt = [string]$_.updatedAt
    }
    $d = Cut ([string]$_.desc) 500
    if ($d) { $t.desc = $d }
    Add-IfAny $t 'dirs' (AsArr $_.dirs)
    # Only the open steps matter for planning; a finished checklist item is
    # evidence, so its count travels instead of its text.
    $subs = @(AsArr $_.subtasks)
    if ($subs.Count) {
        $t.subtasksDone = @($subs | Where-Object { $_.done }).Count
        $t.subtasksTotal = $subs.Count
        Add-IfAny $t 'openSubtasks' (@($subs | Where-Object { -not $_.done } | Select-Object -First 8 |
            ForEach-Object { Cut ([string]$_.text) 160 }))
    }
    Add-IfAny $t 'aiNotes' (@(AsArr $_.aiNotes | Select-Object -Last 2 | ForEach-Object { Cut ([string]$_.text) 300 }))
    Add-IfAny $t 'userComments' (@(AsArr $_.comments | Where-Object { [string]$_.by -eq 'user' } |
        Select-Object -Last 3 | ForEach-Object { Cut ([string]$_.text) 300 }))
    $t
})

# Closed work is planning input (what is already covered) but never plan
# content, so titles are enough - and only while they are still recent.
$cutoff = (Get-Date).AddDays(-10)
$doneRecent = @($allTasks | Where-Object {
    if (-not $_.done) { return $false }
    $ts = [datetime]::MinValue
    if ([datetime]::TryParse([string]$_.updatedAt, [ref]$ts)) { return $ts -gt $cutoff }
    return $true
} | Select-Object -Last 25 | ForEach-Object { Cut ([string]$_.title) 120 })

$archiveTitles = @($archive | Select-Object -Last 25 | ForEach-Object { Cut ([string]$_.title) 120 })

# ---------- project registry ----------
$projects = @()
try { $projects = @((Get-Content (Join-Path $base 'projects.json') -Raw -Encoding UTF8 | ConvertFrom-Json).projects) } catch {}

# Every project bound to an open task stays in the digest whatever its
# activity score - the board is asking about it, so the model needs its card.
$boundDirs = @{}
foreach ($t in $openTasks) { foreach ($d in @($t.dirs)) { $boundDirs[([string]$d).ToLowerInvariant()] = $true } }

$ranked = @($projects | Sort-Object { [int]$_.changed14d } -Descending)
$picked = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($p in $ranked) {
    $key = ([string]$p.dir).ToLowerInvariant()
    if ($seen[$key]) { continue }
    if ($picked.Count -lt 18 -or $boundDirs[$key]) { $picked.Add($p); $seen[$key] = $true }
}

$projectCards = @($picked | ForEach-Object {
    $c = @{
        name = [string]$_.name
        dir = [string]$_.dir
        changed14d = [int]$_.changed14d
        lastTouched = [string]$_.lastTouched
    }
    Add-IfAny $c 'stack' (AsArr $_.stack)
    if ($_.isGit) {
        $c.branch = [string]$_.branch
        if ([int]$_.dirtyCount -gt 0) { $c.dirtyCount = [int]$_.dirtyCount }
        Add-IfAny $c 'lastCommits' (@(AsArr $_.lastCommits | Select-Object -First 4 | ForEach-Object { Cut ([string]$_) 140 }))
        Add-IfAny $c 'dirtySample' (@(AsArr $_.dirtySample | Select-Object -First 5 | ForEach-Object { Cut ([string]$_) 120 }))
    }
    Add-IfAny $c 'recentFiles' (@(AsArr $_.recentFiles | Select-Object -First 5 | ForEach-Object { Cut ([string]$_) 140 }))
    Add-IfAny $c 'todoSample' (@(AsArr $_.todoSample | Select-Object -First 3 | ForEach-Object { Cut ([string]$_) 140 }))
    $r = Cut ([string]$_.readme) 320
    if ($r) { $c.readme = $r }
    $pd = Cut ([string]$_.pkgDesc) 160
    if ($pd) { $c.pkgDesc = $pd }
    $c
})

# ---------- yesterday: the last brief, and what was ticked off ----------
$lastBrief = $null
$briefsDir = Join-Path $base 'briefs'
if (Test-Path $briefsDir) {
    $prev = @(Get-ChildItem $briefsDir -Filter '*.json' -File |
        Where-Object { $_.BaseName -lt $Today } | Sort-Object Name -Descending | Select-Object -First 1)
    if ($prev.Count) {
        try {
            $pb = Get-Content $prev[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $lastBrief = @{
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
        $dj = Get-Content $donePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in @($dj.PSObject.Properties)) {
            if ($prop.Value -eq $true) { $doneToday += [string]$prop.Name }
        }
    } catch {}
}
$todayBrief = $null
$todayBriefPath = Join-Path $briefsDir ($Today + '.json')
if ($Replan -and (Test-Path $todayBriefPath)) {
    try {
        $tb = Get-Content $todayBriefPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $todayBrief = @{
            tldr = Cut ([string]$tb.tldr) 400
            tasks = @(AsArr $tb.tasks | ForEach-Object {
                @{ id = [string]$_.id; title = Cut ([string]$_.title) 120; weight = [int]$_.weight }
            })
        }
    } catch {}
}

# ---------- open questions ----------
$questions = @()
try {
    $qj = Get-Content (Join-Path $base 'questions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $questions = @(AsArr $qj.questions | ForEach-Object {
        @{ id = [string]$_.id; text = Cut ([string]$_.text) 300; project = [string]$_.project
           answer = Cut ([string]$_.answer) 500; at = [string]$_.at }
    })
} catch {}

# ---------- activity ----------
$snapDir = Join-Path $base 'snapshots'
$activityHistory = @()
if (Test-Path $snapDir) {
    $files = @(Get-ChildItem $snapDir -Filter 'activity-*.txt' -File | Sort-Object Name -Descending | Select-Object -First 3)
    foreach ($f in $files) {
        $activityHistory += @{
            date = ($f.BaseName -replace '^activity-', '')
            top = @(Read-Lines $f.FullName 6)
        }
    }
}

$digest = @{
    now = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    today = $Today
    mode = if ($Replan) { 'replan' } else { 'full' }
    goals = Read-Head (Join-Path $base 'GOALS.md') 4000
    state = Read-Head (Join-Path $base 'STATE.md') 2500
    progress = Read-Head (Join-Path $base 'PROGRESS.md') 800
}
Add-IfAny $digest 'projects' $projectCards
Add-IfAny $digest 'openTasks' $openTasks
Add-IfAny $digest 'doneRecent' $doneRecent
Add-IfAny $digest 'archiveTitles' $archiveTitles
Add-IfAny $digest 'questions' $questions
Add-IfAny $digest 'topDirs' (Read-Lines (Join-Path $base 'top-dirs.txt') 10)
Add-IfAny $digest 'activityHistory' $activityHistory
Add-IfAny $digest 'doneTodayIds' $doneToday
if ($lastBrief) { $digest.lastBrief = $lastBrief }
if ($todayBrief) { $digest.todayBrief = $todayBrief }

# -Compress on purpose: pretty-printed PS JSON is about twice the bytes, and
# every one of those indent spaces is a token the morning run pays for.
[IO.File]::WriteAllText($Out, ($digest | ConvertTo-Json -Depth 8 -Compress), $utf8NoBom)
'digest: {0:N0} bytes, {1} projects, {2} open tasks' -f (Get-Item $Out).Length, $projectCards.Count, $openTasks.Count

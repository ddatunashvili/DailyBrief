# Applies the morning run's single output file. The model writes ONE json
# (brief text, app data, state, questions, board patch) and this script does
# every write: five Write tool calls used to be five model turns, and a board
# rewritten by the model was a 200 KB file it had to reproduce by hand.
# Only this script ever rewrites kanban.json. ASCII-only on purpose (PS 5.1).
param(
    [Parameter(Mandatory = $true)][string]$In,
    [string]$Today = (Get-Date -Format 'yyyy-MM-dd')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$now = Get-Date -Format 'yyyy-MM-dd HH:mm'

function AsArr($v) {
    if ($null -eq $v) { return @() }
    if ($v -is [array]) { return $v }
    if ($v -is [string]) { return @($v) }
    if ($v -is [PSCustomObject] -and @($v.PSObject.Properties).Count -eq 0) { return @() }
    return @($v)
}
function Has($obj, [string]$name) {
    return ($obj -and $obj.PSObject.Properties[$name] -and $obj.$name)
}
function Norm-Title([string]$s) { return ($s + '').Trim().ToLowerInvariant() }

if (-not (Test-Path $In)) { '[warn] no model output at ' + $In; exit 2 }
$out = Get-Content $In -Raw -Encoding UTF8 | ConvertFrom-Json

# Headings live here, not in the prompt: the markdown briefing is the same
# content as the app's json, so the model writes it once and this renders it.
# The file stays ASCII, so the Georgian headings come from strings.json.
$H = @{
    title = 'Daily brief'; focus = 'Today'; warnings = 'Warnings'
    recap = 'Recap'; assessment = 'Is the path right?'
}
try {
    $sj = Get-Content (Join-Path $app 'strings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in @('briefTitle', 'briefFocus', 'briefWarnings', 'briefRecap', 'briefAssessment')) {
        if ($sj.PSObject.Properties[$k] -and $sj.$k) {
            $H[($k -replace '^brief', '').ToLowerInvariant()] = [string]$sj.$k
        }
    }
} catch {}

function Render-BriefMd($b) {
    $sb = New-Object System.Text.StringBuilder
    $head = [string]$b.dateLabel
    if (-not $head) { $head = [string]$b.date }
    [void]$sb.AppendLine('# ' + $H.title + ' - ' + $head)
    if ($b.tldr) { [void]$sb.AppendLine(''); [void]$sb.AppendLine([string]$b.tldr) }
    $tasks = @(AsArr $b.tasks)
    if ($tasks.Count) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## ' + $H.focus)
        foreach ($t in $tasks) {
            $badge = if ($t.badge) { ' (' + [string]$t.badge + ')' } elseif ($t.weight) { ' (' + [string]$t.weight + '%)' } else { '' }
            [void]$sb.AppendLine('- **' + [string]$t.title + '**' + $badge + ' - ' + [string]$t.desc)
        }
    }
    $warns = @(AsArr $b.warnings)
    if ($warns.Count) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## ' + $H.warnings)
        foreach ($w in $warns) {
            $label = [string]$w.label
            if (-not $label) { $label = [string]$w.sev }
            [void]$sb.AppendLine('- **' + $label + '**: ' + [string]$w.text)
        }
    }
    $recap = @(AsArr $b.recap)
    if ($recap.Count) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## ' + $H.recap)
        foreach ($r in $recap) { [void]$sb.AppendLine('- ' + [string]$r) }
    }
    $ass = @(AsArr $b.assessment)
    if ($ass.Count) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## ' + $H.assessment)
        foreach ($a in $ass) { [void]$sb.AppendLine(''); [void]$sb.AppendLine([string]$a) }
    }
    return $sb.ToString()
}

# ---------- 1. the briefing itself ----------
$md = ''
if (Has $out 'briefMd') { $md = [string]$out.briefMd }
elseif (Has $out 'brief') { $md = Render-BriefMd $out.brief }
if ($md) {
    $dir = Join-Path $base 'briefings'
    New-Item -ItemType Directory -Force $dir | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir ($Today + '.md')), $md, $utf8NoBom)
    'wrote briefings\{0}.md' -f $Today
} else {
    '[warn] model output has neither brief nor briefMd'
}

# ---------- 2. the app's own data ----------
# Re-serialized here rather than pasted through: a brief that does not survive
# a round trip would break the page it is spliced into.
if (Has $out 'brief') {
    $dir = Join-Path $base 'briefs'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $json = $out.brief | ConvertTo-Json -Depth 8
    $null = $json | ConvertFrom-Json
    [IO.File]::WriteAllText((Join-Path $dir ($Today + '.json')), $json, $utf8NoBom)
    'wrote briefs\{0}.json' -f $Today
} else {
    '[warn] model output has no brief object - the app page will not be updated'
}

# ---------- 3. the running assessment ----------
if (Has $out 'state') {
    [IO.File]::WriteAllText((Join-Path $base 'STATE.md'), [string]$out.state, $utf8NoBom)
    'wrote STATE.md'
}
# Goals change rarely; an empty field means "leave them alone".
if (Has $out 'goals') {
    [IO.File]::WriteAllText((Join-Path $base 'GOALS.md'), [string]$out.goals, $utf8NoBom)
    'wrote GOALS.md'
}

# ---------- 4. open questions ----------
# An answered question keeps its answer: the model proposes the list, it does
# not get to erase what the user already replied.
if ($out.PSObject.Properties['questions']) {
    $prev = @{}
    try {
        $qj = Get-Content (Join-Path $base 'questions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($q in @(AsArr $qj.questions)) { $prev[[string]$q.id] = $q }
    } catch {}
    $qs = @(AsArr $out.questions | Select-Object -First 3 | ForEach-Object {
        $id = [string]$_.id
        $old = $prev[$id]
        New-Object PSObject -Property @{
            id = $id
            text = [string]$_.text
            project = [string]$_.project
            at = if ($old) { [string]$old.at } else { $Today }
            answer = if ($old) { [string]$old.answer } else { '' }
            answeredAt = if ($old) { [string]$old.answeredAt } else { '' }
        }
    })
    [IO.File]::WriteAllText((Join-Path $base 'questions.json'),
        (@{ questions = $qs } | ConvertTo-Json -Depth 6), $utf8NoBom)
    'wrote questions.json ({0} open)' -f $qs.Count
}

# ---------- 5. the board ----------
# Same mutex as every other writer: a check run finishing at the same moment
# must not lose its update to this merge, or the other way round.
if ($out.PSObject.Properties['kanban']) {
    $patch = $out.kanban
    $kanbanPath = Join-Path $base 'kanban.json'
    $valid = @('urgent', 'important', 'planning', 'delayed', 'active')
    $mutex = New-Object System.Threading.Mutex($false, 'DailyBriefKanbanWrite')
    $gotLock = $false
    try {
        $gotLock = $mutex.WaitOne(30000)
        if (-not $gotLock) { throw 'kanban.json lock timeout' }
        $fresh = Get-Content $kanbanPath -Raw -Encoding UTF8 | ConvertFrom-Json

        foreach ($u in @(AsArr $patch.updates)) {
            if (-not $u -or -not $u.id) { continue }
            $t = $fresh.tasks | Where-Object { $_.id -eq $u.id } | Select-Object -First 1
            if (-not $t) { continue }
            if (Has $u 'desc') { $t.desc = [string]$u.desc }
            # An urgent task is the user's own escalation; a morning plan may
            # not quietly demote it.
            if ((Has $u 'status') -and $valid -contains [string]$u.status -and $t.status -ne 'urgent') {
                $t.status = [string]$u.status
            }
            if (Has $u 'subtasks') {
                $oldDone = @{}
                foreach ($os in @(AsArr $t.subtasks)) { if ($os.done) { $oldDone[[string]$os.text] = $true } }
                $newSubs = @(AsArr $u.subtasks | Select-Object -First 30 | ForEach-Object {
                    $txt = [string]$_
                    New-Object PSObject -Property @{ text = $txt; done = [bool]$oldDone[$txt] }
                })
                if ($t.PSObject.Properties['subtasks']) { $t.subtasks = $newSubs }
                else { $t | Add-Member -NotePropertyName subtasks -NotePropertyValue $newSubs }
            }
            if (Has $u 'note') {
                $notes = @(AsArr $t.aiNotes)
                $notes += (New-Object PSObject -Property @{ text = [string]$u.note; at = $now })
                if ($notes.Count -gt 10) { $notes = @($notes | Select-Object -Last 10) }
                if ($t.PSObject.Properties['aiNotes']) { $t.aiNotes = $notes }
                else { $t | Add-Member -NotePropertyName aiNotes -NotePropertyValue $notes }
            }
            # done stays the user's call, and comments are a conversation the
            # planner has no business editing.
            $t.updatedAt = $stamp
        }

        # Dedupe on ids AND on normalized titles, across tasks and archive, so
        # a reworded version of finished work cannot come back as new.
        $freshArchive = @(AsArr $fresh.archive)
        $existingIds = @(@($fresh.tasks | ForEach-Object { [string]$_.id }) + @($freshArchive | ForEach-Object { [string]$_.id }))
        $existingTitles = @(@($fresh.tasks | ForEach-Object { Norm-Title $_.title }) + @($freshArchive | ForEach-Object { Norm-Title $_.title }))
        $added = 0
        foreach ($n in @(AsArr $patch.newTasks)) {
            if (-not $n -or -not $n.id -or -not $n.title) { continue }
            $titleNorm = Norm-Title $n.title
            if ($existingIds -contains [string]$n.id -or $existingTitles -contains $titleNorm) { continue }
            $dirs = @()
            if ((Has $n 'dir') -and (Test-Path ([string]$n.dir))) { $dirs = @([string]$n.dir) }
            $subs = @(AsArr $n.subtasks | Select-Object -First 15 |
                ForEach-Object { New-Object PSObject -Property @{ text = [string]$_; done = $false } })
            $nt = New-Object PSObject -Property @{
                id = [string]$n.id; title = [string]$n.title; desc = [string]$n.desc
                status = if ($valid -contains [string]$n.status) { [string]$n.status } else { 'planning' }
                done = $false; createdBy = 'ai'
                createdAt = $stamp; updatedAt = $stamp
                comments = @(); aiNotes = @(); dirs = $dirs; subtasks = $subs
            }
            # A task born without evidence rots: bind the folder immediately.
            if ($dirs.Count -gt 0) {
                $null = & (Join-Path $app 'scan-folder.ps1') -TaskId ([string]$n.id) -Dir ([string]$dirs[0]) 2>$null
            }
            $fresh.tasks = @($fresh.tasks) + $nt
            $existingIds += [string]$n.id
            $existingTitles += $titleNorm
            $added++
        }

        [IO.File]::WriteAllText($kanbanPath, ($fresh | ConvertTo-Json -Depth 10), $utf8NoBom)
        'kanban: {0} updates, {1} new tasks' -f @(AsArr $patch.updates).Count, $added
    } catch {
        '[warn] kanban merge failed: ' + $_.Exception.Message
    } finally {
        if ($gotLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

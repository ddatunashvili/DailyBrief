# Board compactor (no AI). kanban.json only ever grows: every check appends an
# aiNote, and finished work stays on the board forever. Everything that reads
# the board - every digest, every check, the app itself - pays for that on
# every run, so once a day the dead weight moves to kanban-archive.json next
# to it. Nothing is deleted: old notes and old finished tasks are moved, whole,
# with their comments, and ids never change.
#
# Idempotent: a second run right after the first moves nothing.
# Usage: compact-kanban.ps1 [-DryRun] [-KeepNotes 5] [-Days 30]
# ASCII-only on purpose (PS 5.1 encoding).
param(
    # Prints what would move and writes nothing.
    [switch]$DryRun,
    # aiNotes kept on each task; older ones move to the archive file.
    [int]$KeepNotes = 5,
    # Done tasks and archived (deleted) tasks older than this many days move out.
    [int]$Days = 30
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
. (Join-Path $PSScriptRoot 'lock.ps1')    # Invoke-WithBoardLock
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$kanbanPath  = Join-Path $base 'kanban.json'
$archivePath = Join-Path $base 'kanban-archive.json'

# PS 5.1 round-trips an empty array as $null or {}.
function AsArr($v) {
    if ($null -eq $v) { return @() }
    if ($v -is [array]) { return $v }
    if ($v -is [PSCustomObject] -and @($v.PSObject.Properties).Count -eq 0) { return @() }
    return @($v)
}

function Read-JsonFile([string]$path) {
    return ([string](Get-Content $path -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
}

# A task with no readable date is treated as recent: moving something we
# cannot date would be a guess, and keeping it costs only bytes.
function Get-Stamp($obj, [string[]]$fields) {
    foreach ($f in $fields) {
        if ($obj.PSObject.Properties[$f]) {
            $ts = [datetime]::MinValue
            if ([datetime]::TryParse([string]$obj.$f, [ref]$ts)) { return $ts }
        }
    }
    return $null
}

# A comment the AI has not acted on yet is a pending order: the task stays on
# the board until the command run flips it to "applied".
function Has-PendingComment($t) {
    foreach ($c in @(AsArr $t.comments)) { if ([string]$c.state -eq 'new') { return $true } }
    return $false
}

function Set-Prop($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

if (-not (Test-Path $kanbanPath)) { 'compact: no kanban.json - nothing to do'; exit 0 }

$cutoff = (Get-Date).AddDays(-$Days)
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')

try {
    Invoke-WithBoardLock {
        $board = Read-JsonFile $kanbanPath
        $store = $null
        if (Test-Path $archivePath) { $store = Read-JsonFile $archivePath }
        $storeTasks   = New-Object System.Collections.Generic.List[object]
        $storeArchive = New-Object System.Collections.Generic.List[object]
        $storeNotes   = New-Object System.Collections.Generic.List[object]
        if ($store) {
            foreach ($x in @(AsArr $store.tasks))   { $storeTasks.Add($x) }
            foreach ($x in @(AsArr $store.archive)) { $storeArchive.Add($x) }
            foreach ($x in @(AsArr $store.notes))   { $storeNotes.Add($x) }
        }
        $noteKeys = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($n in $storeNotes) { $null = $noteKeys.Add(([string]$n.taskId + '|' + [string]$n.at + '|' + [string]$n.text)) }

        $report = New-Object System.Collections.Generic.List[string]
        $movedTasks = 0; $movedArch = 0; $movedNotes = 0

        # Same id already in the store (a task re-created and finished again):
        # the newer copy replaces it, so the store never holds an id twice.
        $putInto = {
            param($list, $item)
            for ($i = $list.Count - 1; $i -ge 0; $i--) {
                if ([string]$list[$i].id -eq [string]$item.id) { $list.RemoveAt($i) }
            }
            $list.Add($item)
        }

        # ---------- finished tasks ----------
        $keepTasks = New-Object System.Collections.Generic.List[object]
        foreach ($t in @(AsArr $board.tasks)) {
            $when = Get-Stamp $t @('updatedAt', 'createdAt')
            if ($t.done -and $when -and $when -lt $cutoff -and -not (Has-PendingComment $t)) {
                $report.Add(('task    {0}  done {1:yyyy-MM-dd}  "{2}"' -f $t.id, $when, [string]$t.title))
                Set-Prop $t 'compactedAt' $stamp
                & $putInto $storeTasks $t
                $movedTasks++
            } else {
                $keepTasks.Add($t)
            }
        }

        # ---------- archived (deleted) tasks ----------
        $keepArch = New-Object System.Collections.Generic.List[object]
        foreach ($t in @(AsArr $board.archive)) {
            $when = Get-Stamp $t @('archivedAt', 'updatedAt', 'createdAt')
            if ($when -and $when -lt $cutoff) {
                $report.Add(('archive {0}  archived {1:yyyy-MM-dd}  "{2}"' -f $t.id, $when, [string]$t.title))
                Set-Prop $t 'compactedAt' $stamp
                & $putInto $storeArchive $t
                $movedArch++
            } else {
                $keepArch.Add($t)
            }
        }

        # ---------- old aiNotes on what stays ----------
        # Notes are appended in order, so the newest are at the end.
        foreach ($t in @($keepTasks.ToArray()) + @($keepArch.ToArray())) {
            $notes = @(AsArr $t.aiNotes)
            if ($notes.Count -le $KeepNotes) { continue }
            $old = @($notes | Select-Object -First ($notes.Count - $KeepNotes))
            foreach ($n in $old) {
                $key = [string]$t.id + '|' + [string]$n.at + '|' + [string]$n.text
                if ($noteKeys.Add($key)) {
                    $storeNotes.Add((New-Object PSObject -Property ([ordered]@{
                        taskId = [string]$t.id; text = [string]$n.text; at = [string]$n.at; compactedAt = $stamp
                    })))
                }
            }
            $report.Add(('notes   {0}  {1} of {2} older aiNotes' -f $t.id, $old.Count, $notes.Count))
            Set-Prop $t 'aiNotes' @($notes | Select-Object -Last $KeepNotes)
            $movedNotes += $old.Count
        }

        if ($report.Count -eq 0) { 'compact: nothing to move'; return }
        foreach ($l in $report) { $l }
        $summary = 'compact: {0} done task(s), {1} archived task(s), {2} aiNote(s) {3}' -f `
            $movedTasks, $movedArch, $movedNotes, $(if ($DryRun) { 'would move (dry run)' } else { 'moved to kanban-archive.json' })
        if ($DryRun) { $summary; return }

        Set-Prop $board 'tasks' $keepTasks.ToArray()
        Set-Prop $board 'archive' $keepArch.ToArray()
        $out = [ordered]@{
            tasks = $storeTasks.ToArray(); archive = $storeArchive.ToArray(); notes = $storeNotes.ToArray()
        }
        $before = (Get-Item $kanbanPath).Length
        # Archive file first: a crash between the two writes then leaves an
        # item in both files (harmless, the next run dedupes by id), never in
        # neither.
        [IO.File]::WriteAllText($archivePath, ($out | ConvertTo-Json -Depth 10), $utf8NoBom)
        # Same shape every other board writer uses (brief-apply, kanban-check).
        [IO.File]::WriteAllText($kanbanPath, ($board | ConvertTo-Json -Depth 10), $utf8NoBom)
        $summary
        'compact: kanban.json {0:N0} -> {1:N0} bytes' -f $before, (Get-Item $kanbanPath).Length
    }
} catch {
    'compact failed: ' + $_.Exception.Message
    exit 1
}
exit 0

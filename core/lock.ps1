# Cross-process lock around read-modify-write of shared board files
# (kanban.json, questions.json, ideas.json). Several AI runs may now finish
# at the same time (per-project checks run in parallel), and main.js edits the
# same files when the user saves the board; without this the last writer
# silently drops the others' changes.
#
# A lockfile, not a named mutex: main.js must take the same lock and Node has
# no named-mutex API without a native module. Protocol (mirrored in src/boardlock.js):
#   - <data>\board.lock created exclusively (CreateNew / 'wx') = lock held
#   - content "<pid> <iso time>" for diagnostics only
#   - a lock file older than 120s is stale (holder crashed) and may be removed
#   - release = delete the file
#
# Usage:
#   . (Join-Path $PSScriptRoot 'lock.ps1')
#   Invoke-WithBoardLock { ...read kanban.json, apply patch, write it... }

$script:BoardLockStaleSec = 120

function Get-BoardLockPath {
    $dir = if ($env:DAILYBRIEF_DATA) { $env:DAILYBRIEF_DATA } else { $PSScriptRoot }
    return (Join-Path $dir 'board.lock')
}

function Invoke-WithBoardLock {
    param([Parameter(Mandatory)][scriptblock]$Body, [int]$TimeoutSec = 120)
    $path = Get-BoardLockPath
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $held = $false
    while (-not $held) {
        # A static .NET call, not New-Object: New-Object reports a failed
        # constructor as a non-terminating error, so the catch never ran and
        # the body went ahead without the lock.
        $fs = $null
        try {
            $fs = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        } catch { }
        if ($fs) {
            $bytes = [Text.Encoding]::ASCII.GetBytes(('{0} {1}' -f $PID, (Get-Date).ToString('o')))
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Close()
            $held = $true
        } else {
            # Exists: steal it only when the holder is clearly gone.
            try {
                $age = ((Get-Date) - (Get-Item $path -ErrorAction Stop).LastWriteTime).TotalSeconds
                if ($age -gt $script:BoardLockStaleSec) { Remove-Item $path -Force -ErrorAction SilentlyContinue; continue }
            } catch { continue }   # vanished between attempts: retry at once
            if ((Get-Date) -gt $deadline) { throw "board lock not acquired within ${TimeoutSec}s ($path)" }
            Start-Sleep -Milliseconds 100
        }
    }
    try {
        & $Body
    } finally {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

# Tasks compact-kanban.ps1 moved out of kanban.json (done/archived > 30 days).
# Every duplicate check must see them too, or the AI re-creates old work the
# day after compaction. Read-only, so no lock needed.
function Get-ColdArchive {
    $dir = if ($env:DAILYBRIEF_DATA) { $env:DAILYBRIEF_DATA } else { $PSScriptRoot }
    $p = Join-Path $dir 'kanban-archive.json'
    if (-not (Test-Path $p)) { return @() }
    try {
        $ka = ([string](Get-Content $p -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
    } catch { return @() }
    $out = @()
    foreach ($k in @('tasks', 'archive')) {
        if ($ka.PSObject.Properties[$k] -and $ka.$k) { $out += @($ka.$k | Where-Object { $_ }) }
    }
    return $out
}

# Cross-process lock around read-modify-write of shared board files
# (kanban.json, questions.json, ideas.json). Several AI runs may now finish
# at the same time (per-project checks run in parallel); without this the last
# writer silently drops the others' changes.
#
# Usage:
#   . (Join-Path $PSScriptRoot 'lock.ps1')
#   Invoke-WithBoardLock { ...read kanban.json, apply patch, write it... }

function Invoke-WithBoardLock {
    param([Parameter(Mandatory)][scriptblock]$Body, [int]$TimeoutSec = 120)
    # Per-user name: two Windows accounts on one PC have separate data folders.
    $m = New-Object System.Threading.Mutex($false, ('Local\DailyBriefBoard-' + $env:USERNAME))
    $held = $false
    try {
        try { $held = $m.WaitOne([TimeSpan]::FromSeconds($TimeoutSec)) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw "board lock not acquired within ${TimeoutSec}s" }
        & $Body
    } finally {
        if ($held) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

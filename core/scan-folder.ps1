# Captures a baseline snapshot of a task's linked folder so checks can diff
# against it. Git-aware: for git repos the baseline is HEAD + status (cheap,
# precise); for plain folders a capped file inventory. No AI here.
# ASCII-only on purpose (PS 5.1 encoding).
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$Dir
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
$scans = Join-Path $base 'scans'
New-Item -ItemType Directory -Force $scans | Out-Null
if (-not (Test-Path $Dir)) { exit 1 }

$utf8 = New-Object System.Text.UTF8Encoding $false
$now  = Get-Date -Format 'yyyy-MM-dd HH:mm'
$scanPath = Join-Path $scans ($TaskId + '.json')

# Two baselines live in one file. head/scannedAt move on every check that
# touched the task ("what is new since I last looked"); linkedHead/linkedAt are
# set once, when the task first got this folder, and never move, so evidence
# for "is it done" accumulates over days instead of covering only the last
# check window. Files written before linkedHead existed are upgraded by
# treating their current head/scannedAt as the link point - the oldest
# baseline they still remember.
$prev = $null
if (Test-Path $scanPath) {
    try { $prev = ([string](Get-Content $scanPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $prev = $null }
}
# A relinked folder keeps its baselines only when it is the same folder the
# file was written for; a task re-pointed at a different folder starts over.
if ($prev -and ([string]$prev.dir).TrimEnd([char]92) -ne $Dir.TrimEnd([char]92)) { $prev = $null }
$linkedHead = ''
$linkedAt = ''
if ($prev) {
    if ($prev.PSObject.Properties['linkedAt'] -and $prev.linkedAt) {
        $linkedHead = [string]$prev.linkedHead; $linkedAt = [string]$prev.linkedAt
    } else {
        $linkedHead = [string]$prev.head; $linkedAt = [string]$prev.scannedAt
    }
}

$isGit = $false
$gitOut = git -C $Dir rev-parse --is-inside-work-tree 2>$null
if ("$gitOut".Trim() -eq 'true') { $isGit = $true }

if ($isGit) {
    $branch = "$(git -C $Dir rev-parse --abbrev-ref HEAD 2>$null)".Trim()
    $head   = "$(git -C $Dir rev-parse HEAD 2>$null)".Trim()
    $dirty  = @(git -C $Dir status --porcelain 2>$null)
    $last   = "$(git -C $Dir log -1 --format='%h %ad %s' --date=format:'%Y-%m-%d %H:%M' 2>$null)".Trim()
    # Repo identity, so a check can recognise this folder after it is moved
    # or renamed: the root commit survives a move, the path does not.
    $root   = "$(git -C $Dir rev-list --max-parents=0 HEAD 2>$null | Select-Object -First 1)".Trim()
    $top    = "$(git -C $Dir rev-parse --show-toplevel 2>$null)".Trim().Replace('/', [string][char]92)
    if (-not $linkedAt) { $linkedHead = $head; $linkedAt = $now }
    $snap = @{
        taskId = $TaskId; dir = $Dir; isGit = $true
        branch = $branch; head = $head
        dirtyCount = $dirty.Count
        dirty = @($dirty | Select-Object -First 20 | ForEach-Object { [string]$_ })
        lastCommit = $last
        scannedAt = $now
        linkedHead = $linkedHead; linkedAt = $linkedAt
        rootCommit = $root; toplevel = $top
    }
} else {
    $files = @(Get-ChildItem $Dir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'node_modules|\\\.git|__pycache__|\\\.venv|\\dist\\|\\coverage\\|Cache' } |
        Select-Object -First 2000 |
        ForEach-Object {
            $rel = if ($_.FullName.Length -gt $Dir.Length + 1) { $_.FullName.Substring($Dir.Length + 1) } else { $_.Name }
            '{0}|{1}|{2}' -f $rel, $_.LastWriteTime.ToString('yyyy-MM-ddTHH:mm'), $_.Length
        })
    if (-not $linkedAt) { $linkedAt = $now }
    $snap = @{
        taskId = $TaskId; dir = $Dir; isGit = $false
        fileCount = $files.Count; files = $files
        scannedAt = $now; linkedAt = $linkedAt
    }
}

[IO.File]::WriteAllText($scanPath, ($snap | ConvertTo-Json -Depth 4), $utf8)

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

$isGit = $false
$gitOut = git -C $Dir rev-parse --is-inside-work-tree 2>$null
if ("$gitOut".Trim() -eq 'true') { $isGit = $true }

if ($isGit) {
    $branch = "$(git -C $Dir rev-parse --abbrev-ref HEAD 2>$null)".Trim()
    $head   = "$(git -C $Dir rev-parse HEAD 2>$null)".Trim()
    $dirty  = @(git -C $Dir status --porcelain 2>$null)
    $last   = "$(git -C $Dir log -1 --format='%h %ad %s' --date=format:'%Y-%m-%d %H:%M' 2>$null)".Trim()
    $snap = @{
        taskId = $TaskId; dir = $Dir; isGit = $true
        branch = $branch; head = $head
        dirtyCount = $dirty.Count
        dirty = @($dirty | Select-Object -First 20 | ForEach-Object { [string]$_ })
        lastCommit = $last
        scannedAt = $now
    }
} else {
    $files = @(Get-ChildItem $Dir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'node_modules|\\\.git|__pycache__|\\\.venv|\\dist\\|\\coverage\\|Cache' } |
        Select-Object -First 2000 |
        ForEach-Object {
            $rel = if ($_.FullName.Length -gt $Dir.Length + 1) { $_.FullName.Substring($Dir.Length + 1) } else { $_.Name }
            '{0}|{1}|{2}' -f $rel, $_.LastWriteTime.ToString('yyyy-MM-ddTHH:mm'), $_.Length
        })
    $snap = @{
        taskId = $TaskId; dir = $Dir; isGit = $false
        fileCount = $files.Count; files = $files
        scannedAt = $now
    }
}

[IO.File]::WriteAllText((Join-Path $scans ($TaskId + '.json')), ($snap | ConvertTo-Json -Depth 4), $utf8)

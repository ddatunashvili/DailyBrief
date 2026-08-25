# Discovers the user's most actively used directories and writes a scored top-N list.
# Signals: Windows Recent items (files opened) + the project registry's own
# 14-day activity counts. Scores roll up to project level. ASCII-only on purpose (PS 5.1 encoding).
param(
    [Parameter(Mandatory = $true)]
    [string]$OutFile,
    [int]$Top = 20,
    # Quick: Recent-items signal only, skip the registry/scan signal.
    [switch]$Quick,
    # Registry written by discover-projects.ps1 (refreshed every 30 minutes by
    # the app). Holds changed14d per project, which is what signal 2 needs.
    [string]$Projects = '',
    # Last resort only: walk the disk when no usable registry exists.
    [switch]$ForceScan
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
# Default registry path resolves here, not in the param block: the data dir is
# only known after paths.ps1 has read DAILYBRIEF_DATA.
if (-not $Projects) { $Projects = Join-Path $base 'projects.json' }
$exclude = 'AppData|node_modules|\\\.git|\\Temp|C:\\Windows|Program Files|DailyBrief|\\\.vscode|__pycache__|\\\.venv|\\venv\\|\\Recent|\\\$Recycle|\\\.next|\\\.nuxt|\\\.output|\\\.turbo|\\\.cache|\\dist\\|\\coverage\\|Cache'
$roots = @(
    "$env:USERPROFILE\OneDrive\Desktop",
    "$env:USERPROFILE\OneDrive\Documents",
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\Documents",
    "$env:USERPROFILE\Downloads",
    "$env:USERPROFILE\source",
    "$env:USERPROFILE\projects"
) | Where-Object { Test-Path $_ }

$score = @{}
$now = Get-Date

# Roll a deep path up to "project level": root + at most 2 path segments below it.
function Get-ProjectDir([string]$dir) {
    foreach ($root in $roots) {
        if ($dir.Length -gt $root.Length -and $dir.StartsWith($root + '\')) {
            $rest = $dir.Substring($root.Length + 1).Split('\')
            $take = [Math]::Min(2, $rest.Count)
            return $root + '\' + (($rest[0..($take - 1)]) -join '\')
        }
    }
    return $dir
}

function Add-Score([string]$dir, [double]$weight) {
    if ($dir -and $dir -notmatch $exclude) {
        $proj = Get-ProjectDir $dir
        $score[$proj] = [double]$score[$proj] + $weight
    }
}

# Signal 1: Recent shortcuts = files the user actually opened (weight 3x, 30-day window).
$sh = New-Object -ComObject WScript.Shell
Get-ChildItem "$env:APPDATA\Microsoft\Windows\Recent" -Filter *.lnk |
    Where-Object { $_.LastWriteTime -gt $now.AddDays(-30) } |
    ForEach-Object {
        $target = $sh.CreateShortcut($_.FullName).TargetPath
        if (-not $target) { return }
        $dir = if (Test-Path $target -PathType Container) { $target } else { Split-Path $target -Parent }
        if ($dir -and (Test-Path $dir)) {
            $ageDays = ($now - $_.LastWriteTime).TotalDays
            Add-Score $dir (3 * [Math]::Max(0.2, 1 - $ageDays / 30))
        }
    }

# Signal 2: what changed in the last 14 days. The registry already knows this
# per project - it is built from the monitor's event log - so reading it costs
# milliseconds where the equivalent recursive scan of Desktop, Documents and
# Downloads cost about four minutes, most of it inside node_modules.
$usedRegistry = $false
if (-not $Quick -and -not $ForceScan -and (Test-Path $Projects)) {
    try {
        $reg = Get-Content $Projects -Raw -Encoding UTF8 | ConvertFrom-Json
        $genAt = [datetime]::MinValue
        [void][datetime]::TryParse([string]$reg.generatedAt, [ref]$genAt)
        # A registry older than three days no longer describes "the last 14
        # days" well enough to plan a morning on.
        if ($genAt -gt $now.AddDays(-3)) {
            foreach ($p in @($reg.projects)) {
                $dir = [string]$p.dir
                if (-not $dir) { continue }
                $changed = [double]$p.changed14d
                if ($changed -le 0) { continue }
                $touched = [datetime]::MinValue
                $ok = [datetime]::TryParse([string]$p.lastTouched, [ref]$touched)
                if (-not $ok) { $ok = [datetime]::TryParse([string]$p.lastCommitAt, [ref]$touched) }
                $ageDays = if ($ok) { ($now - $touched).TotalDays } else { 14 }
                Add-Score $dir ($changed * [Math]::Max(0.2, 1 - $ageDays / 14))
            }
            $usedRegistry = $true
        }
    } catch { $usedRegistry = $false }
}

# Fallback: no usable registry, so walk the disk after all - but prune the
# excluded folders during the walk instead of enumerating them and throwing
# the results away afterwards.
if (-not $Quick -and -not $usedRegistry) {
    $cutoff = $now.AddDays(-14)
    foreach ($root in $roots) {
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($root)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try {
                foreach ($sub in [IO.Directory]::EnumerateDirectories($dir)) {
                    if ($sub -notmatch $exclude) { $stack.Push($sub) }
                }
                foreach ($file in [IO.Directory]::EnumerateFiles($dir)) {
                    $ts = [IO.File]::GetLastWriteTime($file)
                    if ($ts -gt $cutoff) {
                        Add-Score $dir ([Math]::Max(0.2, 1 - ($now - $ts).TotalDays / 14))
                    }
                }
            } catch { continue }
        }
    }
}

$score.GetEnumerator() |
    Sort-Object Value -Descending |
    Select-Object -First $Top |
    ForEach-Object { '{0,8:N1}  {1}' -f $_.Value, $_.Key } |
    Out-File $OutFile -Encoding utf8

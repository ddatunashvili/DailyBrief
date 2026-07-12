# Discovers the user's most actively used directories and writes a scored top-N list.
# Signals: Windows Recent items (files opened) + recently modified files in common roots.
# Scores roll up to project level (root + 2 path segments). ASCII-only on purpose (PS 5.1 encoding).
param(
    [Parameter(Mandatory = $true)]
    [string]$OutFile,
    [int]$Top = 20,
    # Quick: Recent-items signal only, skip the slow 14-day recursive scan.
    [switch]$Quick
)

$ErrorActionPreference = 'SilentlyContinue'
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

# Signal 2: files modified in the last 14 days under common work roots.
if (-not $Quick) {
    $cutoff = $now.AddDays(-14)
    foreach ($root in $roots) {
        Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $cutoff } |
            ForEach-Object {
                $ageDays = ($now - $_.LastWriteTime).TotalDays
                Add-Score $_.DirectoryName ([Math]::Max(0.2, 1 - $ageDays / 14))
            }
    }
}

$score.GetEnumerator() |
    Sort-Object Value -Descending |
    Select-Object -First $Top |
    ForEach-Object { '{0,8:N1}  {1}' -f $_.Value, $_.Key } |
    Out-File $OutFile -Encoding utf8

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
# Work roots: Settings > Work folders (roots.json) plus the Windows defaults.
# Any drive, not only USERPROFILE - G:\Desktop is as valid as Desktop.
. (Join-Path $PSScriptRoot 'roots.ps1')
. (Join-Path $PSScriptRoot 'walk.ps1')
$roots = @(Get-WorkRoots -WithDownloads)
# A root nested inside another root is already covered by the outer walk;
# walking it again would only count every change twice.
$walkRoots = @($roots | Where-Object {
    $r = $_
    -not @($roots | Where-Object { $_ -ne $r -and $r.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count
})

$score = @{}
$now = Get-Date

# Roll a deep path up to "project level": root + at most 2 path segments below it.
# The most specific (longest) matching root wins, so a nested work folder
# rolls up below itself rather than below its parent root. Case-insensitive:
# roots.json may spell a path differently from what the disk reports.
function Get-ProjectDir([string]$dir) {
    $best = ''
    foreach ($root in $roots) {
        if ($dir.Length -gt $root.Length -and $root.Length -gt $best.Length -and
            $dir.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { $best = $root }
    }
    if ($best) {
        $rest = $dir.Substring($best.Length + 1).Split('\')
        $take = [Math]::Min(2, $rest.Count)
        return $best + '\' + (($rest[0..($take - 1)]) -join '\')
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

# Fallback: no usable registry, so walk the disk after all - with the same
# pruned walk as the monitor (walk.ps1): excluded and dependency/build folders
# are never entered instead of enumerated and thrown away afterwards.
if (-not $Quick -and -not $usedRegistry) {
    $cutoff = $now.AddDays(-14)
    foreach ($root in $walkRoots) {
        foreach ($f in (Get-RecentFiles -Root $root -Since $cutoff -Exclude $exclude)) {
            Add-Score $f.DirectoryName ([Math]::Max(0.2, 1 - ($now - $f.LastWriteTime).TotalDays / 14))
        }
    }
}

$score.GetEnumerator() |
    Sort-Object Value -Descending |
    Select-Object -First $Top |
    ForEach-Object { '{0,8:N1}  {1}' -f $_.Value, $_.Key } |
    Out-File $OutFile -Encoding utf8

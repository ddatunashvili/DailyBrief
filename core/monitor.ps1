# Background activity monitor - collects file-change events for the analytics
# page. Pure data gathering, no AI. Launched by the app on startup and every
# 30 minutes; the 40-minute window overlaps so nothing is missed (duplicates
# are removed on read by file+timestamp). ASCII-only on purpose (PS 5.1).
param([int]$WindowMinutes = 40)

$ErrorActionPreference = 'SilentlyContinue'
$outDir = 'C:\Users\davit\OneDrive\Desktop\DailyBriefApp\core\analytics'
New-Item -ItemType Directory -Force $outDir | Out-Null

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

# Roll a deep path up to project level: root + at most 2 segments below it.
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

$cutoff = (Get-Date).AddMinutes(-$WindowMinutes)
$today  = Get-Date -Format 'yyyy-MM-dd'
$file   = Join-Path $outDir "$today.jsonl"
$lines  = New-Object System.Collections.Generic.List[string]

foreach ($root in $roots) {
    Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $cutoff -and $_.FullName -notmatch $exclude } |
        Select-Object -First 500 |
        ForEach-Object {
            $proj = Get-ProjectDir $_.DirectoryName
            $rel  = if ($_.FullName.Length -gt $proj.Length + 1) { $_.FullName.Substring($proj.Length + 1) } else { $_.Name }
            $obj = [pscustomobject]@{
                ts      = $_.LastWriteTime.ToString('yyyy-MM-ddTHH:mm')
                project = $proj
                file    = $rel
            }
            $lines.Add(($obj | ConvertTo-Json -Compress))
        }
}
if ($lines.Count -gt 0) {
    # AppendAllText with BOM-less UTF-8: Add-Content -Encoding utf8 stamps a BOM
    # on new files, which breaks line-by-line JSON parsing downstream.
    $text = ($lines -join "`r`n") + "`r`n"
    [IO.File]::AppendAllText($file, $text, (New-Object System.Text.UTF8Encoding $false))
}

# Retention: keep 30 daily files.
Get-ChildItem $outDir -Filter '*.jsonl' | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item -Force

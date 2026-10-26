# The folders this user works in. Every script that walks the disk (monitor,
# discover-dirs, discover-projects, the check's folder relink) reads them from
# here, so adding a folder in Settings reaches all of them at once.
#
# Source: <data>\roots.json  { "roots": ["G:\\Desktop", ...] }  written by the
# app's Settings page. The Windows defaults are always added: they cost nothing
# when missing (filtered by Test-Path), and a fresh install must see something.
# Hardcoding only the defaults is what left a G:\Desktop workspace invisible.
#
# Dot-source after paths.ps1 (needs $base).

function Get-WorkRoots {
    param([switch]$WithDownloads)
    $list = New-Object System.Collections.Generic.List[string]
    $cfg = Join-Path $base 'roots.json'
    if (Test-Path $cfg) {
        try {
            $j = ([string](Get-Content $cfg -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
            foreach ($r in @($j.roots)) { if ($r) { $list.Add(([string]$r).TrimEnd('\')) } }
        } catch { }
    }
    $defaults = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        "$env:USERPROFILE\OneDrive\Desktop",
        "$env:USERPROFILE\OneDrive\Documents",
        "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Documents",
        "$env:USERPROFILE\source",
        "$env:USERPROFILE\projects"
    )
    if ($WithDownloads) { $defaults += "$env:USERPROFILE\Downloads" }
    foreach ($d in $defaults) { if ($d) { $list.Add(([string]$d).TrimEnd('\')) } }

    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in $list) {
        $k = $r.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        if (Test-Path -LiteralPath $r -PathType Container) { $out.Add($r) }
    }
    return @($out)
}

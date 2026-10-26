# Pruned directory walk for the scripts that look for recently changed files
# (monitor, discover-dirs fallback). Get-ChildItem -Recurse enumerates every
# node_modules / .git / build folder and only then filters the results away;
# on a G:\Desktop work root that cost three minutes per monitor run. This walk
# never descends into those folders at all, and reads each file's timestamp
# from the directory listing itself (no extra stat per file).
# ASCII-only on purpose (PS 5.1 encoding).

# Folder NAMES that are never descended into: dependency, VCS, build output and
# cache folders. Matched against the leaf name only.
$script:PruneNameRe = '^(node_modules|\.git|\.svn|\.hg|vendor|dist|build|bin|obj|\.next|\.nuxt|\.output|\.turbo|\.cache|\.parcel-cache|\.gradle|\.idea|\.vs|\.vscode|\.venv|venv|__pycache__|\.pytest_cache|\.mypy_cache|coverage|\$Recycle\.Bin|System Volume Information)$'

# Files under $Root written after $Since, as FileInfo objects.
#   $Exclude    - the caller's path regex; tested on each folder path (with a
#                 trailing backslash, so patterns like '\\dist\\' still match)
#                 and on each file's full path, exactly as before.
#   $IgnoreDirs - lower-cased muted folders: pruned with everything below them.
#   $Max        - stop after this many hits (0 = no limit).
# Access-denied, too-long and vanished folders are skipped, never fatal.
# Reparse points (junctions, symlinks) are not followed: they loop or leave the root.
function Get-RecentFiles {
    param(
        [string]$Root,
        [datetime]$Since,
        [string]$Exclude = '',
        [string[]]$IgnoreDirs = @(),
        [int]$Max = 0
    )
    $out = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $ign = @{}
    foreach ($d in $IgnoreDirs) { if ($d) { $ign[([string]$d).TrimEnd('\').ToLowerInvariant()] = $true } }
    if ($ign.ContainsKey($Root.TrimEnd('\').ToLowerInvariant())) { return $out }
    $reparse = [IO.FileAttributes]::ReparsePoint
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    try { $stack.Push((New-Object System.IO.DirectoryInfo $Root)) } catch { return $out }
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($e in $dir.EnumerateFileSystemInfos()) {
                if ($e -is [System.IO.DirectoryInfo]) {
                    if (($e.Attributes -band $reparse) -ne 0) { continue }
                    if ($e.Name -match $script:PruneNameRe) { continue }
                    $full = $e.FullName
                    if ($Exclude -and (($full + '\') -match $Exclude)) { continue }
                    if ($ign.Count -and $ign.ContainsKey($full.ToLowerInvariant())) { continue }
                    $stack.Push($e)
                } elseif ($e.LastWriteTime -gt $Since) {
                    if ($Exclude -and ($e.FullName -match $Exclude)) { continue }
                    $out.Add($e)
                    if ($Max -gt 0 -and $out.Count -ge $Max) { return $out }
                }
            }
        } catch { continue }
    }
    return $out
}

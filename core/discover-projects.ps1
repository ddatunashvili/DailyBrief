# Project registry builder. Turns the raw folder activity into first-class
# "projects" the AI can reason about: what the thing IS (stack, readme intent),
# what happened in it lately (commits, dirty files, changed files) and what is
# still open in it (TODO/FIXME count). No AI here - pure data gathering, so
# every AI run can read a small projects.json instead of guessing from
# directory byte-scores.
# ASCII-only on purpose (PS 5.1 encoding).
param(
    # Cap on activity-ranked projects. Projects linked to an open task are
    # always kept on top of it (see 'pinned by open tasks' below).
    [int]$MaxProjects = 60,
    [int]$ActiveDays  = 14
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
$outFile = Join-Path $base 'projects.json'
$utf8    = New-Object System.Text.UTF8Encoding $false
$now     = Get-Date

# Work roots: Settings > Work folders (roots.json) plus the Windows defaults
# (no Downloads here, as before). Any drive, not only USERPROFILE.
. (Join-Path $PSScriptRoot 'roots.ps1')
$roots = @(Get-WorkRoots)
# The monitor also watches Downloads, and a folder touched there has always
# been allowed to become a project through its events - keep that.
$eventRoots = @(Get-WorkRoots -WithDownloads)

# True when $path sits strictly below one of the monitor's current roots.
function Under-Root([string]$path) {
    foreach ($r in $eventRoots) {
        if ($path.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

$skipRe = 'node_modules|\\\.git$|\\\.git\\|AppData|\\Temp|\\\.vscode|__pycache__|\\\.venv|\\venv|\\Recent|\$Recycle|\\\.next|\\\.nuxt|\\\.output|\\\.turbo|\\\.cache|\\dist|\\coverage|DailyBriefApp'

# ---------- user-muted folders (the "ignored" page) ----------
# A muted folder must not become a project and its file changes must not be
# counted anywhere: old events for it are already on disk, so filtering has to
# happen on read too, not only in the monitor that writes them.
$ignoreDirs = @()
$ignorePath = Join-Path $base 'ignore.json'
if (Test-Path $ignorePath) {
    try {
        $ij = ([string](Get-Content $ignorePath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $ignoreDirs = @($ij.dirs | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    } catch {}
}

function Is-Ignored([string]$path) {
    $p = ([string]$path).Trim().ToLowerInvariant()
    if (-not $p) { return $false }
    $sep = [char]92
    foreach ($d in $ignoreDirs) {
        if ($p -eq $d -or $p.StartsWith($d + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ---------- activity from the monitor's event log ----------
# A List, not `$events += $e`: array += copies the whole array per event, and
# two weeks of monitor log is tens of thousands of lines.
$events = New-Object System.Collections.Generic.List[object]
# The monitor's windows overlap by design, so the same change is logged many
# times - dedupe or every count is inflated several-fold.
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
for ($i = 0; $i -lt $ActiveDays; $i++) {
    $f = Join-Path $base ('analytics\' + $now.AddDays(-$i).ToString('yyyy-MM-dd') + '.jsonl')
    if (Test-Path $f) {
        Get-Content $f -Encoding UTF8 | ForEach-Object {
            if ($_.Trim()) {
                try {
                    $e = $_ | ConvertFrom-Json
                    if (Is-Ignored ([string]$e.project)) { return }
                    $key = [string]$e.project + '|' + [string]$e.file + '|' + [string]$e.ts
                    if ($seen.Add($key)) { $events.Add($e) }
                } catch {}
            }
        }
    }
}
$events = $events.ToArray()
$eventDirs = @($events | Group-Object project | Sort-Object Count -Descending)

# ---------- candidate roots: marker folders (depth 1-2) + observed activity ----------
$markers = @('.git', 'package.json', 'requirements.txt', 'pom.xml', 'go.mod', 'Cargo.toml', 'composer.json', 'pubspec.yaml', 'index.html')

function Has-Marker([string]$dir) {
    foreach ($m in $markers) { if (Test-Path (Join-Path $dir $m)) { return $true } }
    if (@(Get-ChildItem $dir -Filter '*.csproj' -File -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    if (@(Get-ChildItem $dir -Filter '*.sln'    -File -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    return $false
}

$candidates = New-Object System.Collections.Generic.List[string]
foreach ($root in $roots) {
    foreach ($d1 in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        if ($d1.FullName -match $skipRe) { continue }
        if (Has-Marker $d1.FullName) { $candidates.Add($d1.FullName); continue }
        foreach ($d2 in @(Get-ChildItem $d1.FullName -Directory -ErrorAction SilentlyContinue)) {
            if ($d2.FullName -match $skipRe) { continue }
            if (Has-Marker $d2.FullName) { $candidates.Add($d2.FullName) }
        }
    }
}
# Folders the user actually touched count as projects even without a marker
# (docs, media, thesis folders) - they are real work, just not code repos.
foreach ($g in $eventDirs) {
    $p = [string]$g.Name
    # Only while it is still under a work root: a folder removed in Settings
    # must not linger for two weeks on the strength of its old events.
    if ($p -and (Under-Root $p) -and (Test-Path $p) -and ($p -notmatch $skipRe)) { $candidates.Add($p) }
}
# Collapse to the repository root. The monitor rolls activity up to "root + 2
# segments", which for a big repo yields RENODE PANEL\app, \storage, \public...
# as if they were separate projects. One repo = one project.
$normalized = New-Object System.Collections.Generic.List[string]
foreach ($c in @($candidates | Select-Object -Unique)) {
    if ($roots -contains $c) { continue }          # a work root is not a project
    $top = "$(git -C $c rev-parse --show-toplevel 2>$null)".Trim()
    if ($top) {
        $top = $top.Replace('/', '\')
        if (Test-Path $top) { $normalized.Add($top); continue }
    }
    $normalized.Add($c)
}
$candidates = @($normalized | Select-Object -Unique | Where-Object { $roots -notcontains $_ -and -not (Is-Ignored $_) })
# A plain folder that merely CONTAINS a project is not itself a project
# (DB_BACKUPS-master wrapping renode-panel-backups). Git roots survive: a
# nested repo is genuinely its own project.
$candidates = @($candidates | Where-Object {
    $outer = $_
    $isGitDir = Test-Path (Join-Path $outer '.git')
    if ($isGitDir) { return $true }
    $wraps = @($candidates | Where-Object { $_ -ne $outer -and $_.StartsWith($outer + '\', [StringComparison]::OrdinalIgnoreCase) })
    return ($wraps.Count -eq 0)
})

# ---------- projects pinned by open tasks ----------
# A project with an open task on the board must stay in the registry however
# quiet it has been: every check and plan for that task reads its card. A task
# folder counts for the deepest project that is it or contains it; one no
# project covers becomes a project itself (its git root when it has one).
$pinned = @{}
$taskDirs = @()
$kanbanPath = Join-Path $base 'kanban.json'
if (Test-Path $kanbanPath) {
    try {
        $kj = ([string](Get-Content $kanbanPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $taskDirs = @(foreach ($t in @($kj.tasks)) {
            if (-not $t -or $t.done -eq $true) { continue }
            foreach ($d in @($t.dirs)) { $s = ([string]$d).Trim().TrimEnd('\'); if ($s) { $s } }
        })
    } catch { $taskDirs = @() }
}
$extra = New-Object System.Collections.Generic.List[string]
foreach ($td in @($taskDirs | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $td -PathType Container)) { continue }
    if (Is-Ignored $td) { continue }
    $owner = ''
    foreach ($c in @($candidates) + @($extra)) {
        if ($c.Length -gt $owner.Length -and
            ($td -eq $c -or $td.StartsWith($c + '\', [StringComparison]::OrdinalIgnoreCase))) { $owner = $c }
    }
    if (-not $owner) {
        $owner = $td
        $top = "$(git -C $td rev-parse --show-toplevel 2>$null)".Trim()
        if ($top) {
            $top = $top.Replace('/', '\')
            if (Test-Path -LiteralPath $top) { $owner = $top }
        }
        if (($roots -contains $owner) -or (Is-Ignored $owner)) { continue }   # a work root is not a project
        $extra.Add($owner)
    }
    $pinned[$owner.ToLowerInvariant()] = $true
}
$candidates = @(@($candidates) + @($extra))

# ---------- score, then keep only the most relevant ones ----------
function Event-Count([string]$dir) {
    $c = 0
    foreach ($g in $eventDirs) {
        $p = [string]$g.Name
        if ($p -eq $dir -or $p.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $dir.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { $c += $g.Count }
    }
    return $c
}

$scored = @(foreach ($c in $candidates) {
    $li = (Get-Item $c -ErrorAction SilentlyContinue)
    if (-not $li) { continue }
    [pscustomobject]@{ dir = $c; ev = (Event-Count $c); last = $li.LastWriteTime }
})
$rank = 0
$picked = @($scored | Sort-Object @{e = 'ev'; Descending = $true}, @{e = 'last'; Descending = $true} |
    ForEach-Object {
        $rank++
        if ($rank -le $MaxProjects -or $pinned.ContainsKey(([string]$_.dir).ToLowerInvariant())) { $_ }
    })

# ---------- build one card per project ----------
function Detect-Stack([string]$dir) {
    # Plain array, not List[string]: PS 5.1 serializes an empty List as {} and
    # every consumer then reads an object where an array was promised.
    $stack = @()
    $pkgPath = Join-Path $dir 'package.json'
    if (Test-Path $pkgPath) {
        try {
            $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $deps = @()
            if ($pkg.dependencies)    { $deps += @($pkg.dependencies.PSObject.Properties.Name) }
            if ($pkg.devDependencies) { $deps += @($pkg.devDependencies.PSObject.Properties.Name) }
            foreach ($known in @('next', 'react', 'vue', 'nuxt', 'svelte', 'electron', 'express', 'fastify', 'nest', 'tailwindcss', 'typescript', 'prisma', 'mongoose', 'discord.js', 'vite')) {
                if ($deps -contains $known) { $stack += $known }
            }
            if ($stack.Count -eq 0) { $stack += 'node' }
        } catch { $stack += 'node' }
    }
    if (Test-Path (Join-Path $dir 'requirements.txt')) { $stack += 'python' }
    if (Test-Path (Join-Path $dir 'composer.json'))    { $stack += 'php' }
    if (Test-Path (Join-Path $dir 'artisan'))          { $stack += 'laravel' }
    if (Test-Path (Join-Path $dir 'go.mod'))           { $stack += 'go' }
    if (Test-Path (Join-Path $dir 'Cargo.toml'))       { $stack += 'rust' }
    if (Test-Path (Join-Path $dir 'pubspec.yaml'))     { $stack += 'flutter' }
    if (@(Get-ChildItem $dir -Filter '*.csproj' -File -ErrorAction SilentlyContinue).Count -gt 0) { $stack += 'dotnet' }
    if (Test-Path (Join-Path $dir 'build.gradle'))     { $stack += 'android' }
    return @($stack | Select-Object -Unique | Select-Object -First 6)
}

function Read-Head([string]$path, [int]$len) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $t = Get-Content $path -Raw -Encoding UTF8
        $t = ($t -replace '\s+', ' ').Trim()
        if ($t.Length -gt $len) { $t = $t.Substring(0, $len) }
        return $t
    } catch { return '' }
}

# ---------- incremental rebuild ----------
# This runs every 30 minutes, and most projects did not move in between. The
# git log, the TODO scan over `git ls-files` and the readme/package reads are
# the expensive part, so they are reused from the previous projects.json card
# whenever the project's fingerprint is unchanged. Activity fields (changed14d,
# recentFiles, lastTouched) and git status come from data already in hand and
# are always fresh, so a reused card is never stale on what moved.
$cachePath = Join-Path $base 'projects-cache.json'
$prevCards = @{}
$prevFp = @{}
if (Test-Path $outFile) {
    try {
        $pj = ([string](Get-Content $outFile -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        foreach ($c in @($pj.projects)) { if ($c.dir) { $prevCards[([string]$c.dir).ToLowerInvariant()] = $c } }
    } catch {}
}
if (Test-Path $cachePath) {
    try {
        $cj = ([string](Get-Content $cachePath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json
        foreach ($prop in @($cj.fp.PSObject.Properties)) { $prevFp[$prop.Name] = [string]$prop.Value }
    } catch {}
}
$newFp = @{}
$md5 = [System.Security.Cryptography.MD5]::Create()
function Hash-Text([string]$s) {
    return [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-', '')
}

# PS 5.1 round-trips an empty array as $null or {}, and a reused card has to
# serialize exactly like a freshly built one. The leading comma stops the
# pipeline from unrolling the array on return: 0 or 1 items would not stay [].
function AsStrArr($v) {
    if ($null -eq $v) { return ,@() }
    if ($v -is [PSCustomObject] -and @($v.PSObject.Properties).Count -eq 0) { return ,@() }
    return ,@(@($v) | ForEach-Object { [string]$_ })
}

# Detect-Stack's plain `return @(...)` unrolls, so a fresh card carries a
# one-item stack as a bare string and an empty one as {}. Every reader runs
# stack through AsArr/arr(), but a reused card must still serialize exactly
# like a fresh one, so it goes through the same kind of return.
function Same-AsDetectStack($a) { return @($a) }

$projects = @(foreach ($p in $picked) {
    $dir  = [string]$p.dir
    $name = Split-Path $dir -Leaf
    $parent = Split-Path $dir -Parent
    $label = if ($parent) { (Split-Path $parent -Leaf) + '\' + $name } else { $name }

    # One rev-parse answers three questions: is it a repo, its HEAD sha, its
    # branch. A repo with no commits yet fails on HEAD; it still counts as git.
    $isGit = $false; $headSha = ''; $branch = ''
    $rp = @(git -C $dir rev-parse --is-inside-work-tree HEAD --abbrev-ref HEAD 2>$null | ForEach-Object { ([string]$_).Trim() })
    if ($rp.Count -ge 1 -and $rp[0] -eq 'true') {
        $isGit = $true
        if ($rp.Count -ge 3) { $headSha = $rp[1]; $branch = $rp[2] }
        else { $branch = "$(git -C $dir rev-parse --abbrev-ref HEAD 2>$null)".Trim() }
    }

    $lastCommits = @(); $dirtyCount = 0; $dirtySample = @(); $lastCommitAt = ''; $dirty = @()
    if ($isGit) {
        $dirty = @(git -C $dir status --porcelain 2>$null | ForEach-Object { [string]$_ })
        $dirtyCount = $dirty.Count
        $dirtySample = @($dirty | Select-Object -First 8)
    }

    # Recently changed files inside this project, straight from the monitor log.
    $recent = @($events | Where-Object {
        $pp = [string]$_.project
        $pp -eq $dir -or $pp.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $dir.StartsWith($pp + '\', [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object ts -Descending)
    $recentFiles = @($recent | Select-Object -First 8 | ForEach-Object { [string]$_.file })
    $lastTouched = if ($recent.Count -gt 0) { [string]$recent[0].ts } else { '' }

    # Open work already written down in the code itself. Only git repos are
    # scanned, and the file list comes from `git ls-files`: a plain -Recurse
    # walks node_modules/.next and takes minutes per project.
    $todoEligible = ($isGit -and ($recent.Count -gt 0 -or $dirtyCount -gt 0))

    # Fingerprint. git: HEAD + status + the mtimes of the dirty files (status
    # alone says " M x" whether x was edited once or ten times). Plain folder:
    # the newest top-level mtime - its card only reads top-level files.
    $key = $dir.ToLowerInvariant()
    if ($isGit) {
        $mt = @($dirty | Select-Object -First 50 | ForEach-Object {
            $rel = ([string]$_)
            if ($rel.Length -gt 3) { $rel = $rel.Substring(3) }
            if ($rel -match ' -> ') { $rel = ($rel -split ' -> ')[-1] }
            $rel = $rel.Trim('"')
            $fi = Get-Item -LiteralPath (Join-Path $dir $rel) -ErrorAction SilentlyContinue
            if ($fi) { [string]$fi.LastWriteTimeUtc.Ticks } else { '0' }
        })
        $fp = 'g|' + $headSha + '|' + $branch + '|' + (Hash-Text ((@($dirty) + @($mt)) -join "`n")) + '|' + $todoEligible
    } else {
        $newest = (Get-Item -LiteralPath $dir).LastWriteTimeUtc.Ticks
        foreach ($ch in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($ch.LastWriteTimeUtc.Ticks -gt $newest) { $newest = $ch.LastWriteTimeUtc.Ticks }
        }
        $fp = 'd|' + $newest
    }
    $newFp[$key] = $fp
    $prev = $prevCards[$key]
    if ($prev -and $prevFp[$key] -eq $fp -and [bool]$prev.isGit -eq $isGit) {
        @{
            id           = $key.GetHashCode().ToString('x')
            name         = $label
            dir          = $dir
            isGit        = $isGit
            branch       = $branch
            lastCommits  = (AsStrArr $prev.lastCommits)
            lastCommitAt = [string]$prev.lastCommitAt
            dirtyCount   = $dirtyCount
            dirtySample  = $dirtySample
            changed14d   = $recent.Count
            recentFiles  = $recentFiles
            lastTouched  = $lastTouched
            stack        = Same-AsDetectStack (AsStrArr $prev.stack)
            readme       = [string]$prev.readme
            pkgDesc      = [string]$prev.pkgDesc
            todoCount    = [int]$prev.todoCount
            todoSample   = (AsStrArr $prev.todoSample)
        }
        continue
    }

    if ($isGit) {
        $lastCommits = @(git -C $dir log -5 --format='%ad %s' --date=format:'%Y-%m-%d' 2>$null |
            ForEach-Object { [string]$_ })
        $lastCommitAt = "$(git -C $dir log -1 --format='%ad' --date=format:'%Y-%m-%d %H:%M' 2>$null)".Trim()
    }

    $todoCount = 0; $todoSample = @()
    if ($todoEligible) {
        $codeExt = @('.js', '.ts', '.tsx', '.jsx', '.py', '.php', '.cs', '.go', '.rs', '.java', '.kt', '.vue', '.svelte')
        $codeFiles = @(git -C $dir ls-files 2>$null |
            Where-Object { $codeExt -contains [IO.Path]::GetExtension($_) } |
            Select-Object -First 300 |
            ForEach-Object { Join-Path $dir $_ } |
            Where-Object { Test-Path $_ })
        if ($codeFiles.Count -gt 0) {
            $hits = @(Select-String -Path $codeFiles -Pattern 'TODO|FIXME|HACK:' -ErrorAction SilentlyContinue)
            $todoCount = $hits.Count
            $todoSample = @($hits | Select-Object -First 5 | ForEach-Object {
                $line = ([string]$_.Line).Trim()
                if ($line.Length -gt 120) { $line = $line.Substring(0, 120) }
                '{0}:{1} {2}' -f $_.Filename, $_.LineNumber, $line
            })
        }
    }

    $readme = Read-Head (Join-Path $dir 'README.md') 400
    if (-not $readme) { $readme = Read-Head (Join-Path $dir 'readme.md') 400 }
    $pkgDesc = ''
    $pkgPath = Join-Path $dir 'package.json'
    if (Test-Path $pkgPath) {
        try {
            $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $pkgDesc = [string]$pkg.description
        } catch {}
    }

    @{
        id           = ([string]$dir).ToLowerInvariant().GetHashCode().ToString('x')
        name         = $label
        dir          = $dir
        isGit        = $isGit
        branch       = $branch
        lastCommits  = $lastCommits
        lastCommitAt = $lastCommitAt
        dirtyCount   = $dirtyCount
        dirtySample  = $dirtySample
        changed14d   = $recent.Count
        recentFiles  = $recentFiles
        lastTouched  = $lastTouched
        stack        = Detect-Stack $dir
        readme       = $readme
        pkgDesc      = $pkgDesc
        todoCount    = $todoCount
        todoSample   = $todoSample
    }
})

$out = @{ generatedAt = $now.ToString('yyyy-MM-dd HH:mm'); projects = $projects }
[IO.File]::WriteAllText($outFile, ($out | ConvertTo-Json -Depth 6), $utf8)
# Written after projects.json on purpose: a crash in between leaves an old
# cache, which only costs one full rebuild, never a reused card that is wrong.
[IO.File]::WriteAllText($cachePath, (@{ version = 1; fp = $newFp } | ConvertTo-Json -Depth 3 -Compress), $utf8)

# Project registry builder. Turns the raw folder activity into first-class
# "projects" the AI can reason about: what the thing IS (stack, readme intent),
# what happened in it lately (commits, dirty files, changed files) and what is
# still open in it (TODO/FIXME count). No AI here - pure data gathering, so
# every AI run can read a small projects.json instead of guessing from
# directory byte-scores.
# ASCII-only on purpose (PS 5.1 encoding).
param(
    [int]$MaxProjects = 40,
    [int]$ActiveDays  = 14
)

$ErrorActionPreference = 'SilentlyContinue'
$base    = 'C:\Users\davit\OneDrive\Desktop\DailyBriefApp\core'
$outFile = Join-Path $base 'projects.json'
$utf8    = New-Object System.Text.UTF8Encoding $false
$now     = Get-Date

$roots = @(
    "$env:USERPROFILE\OneDrive\Desktop",
    "$env:USERPROFILE\OneDrive\Documents",
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\Documents",
    "$env:USERPROFILE\source",
    "$env:USERPROFILE\projects"
) | Where-Object { Test-Path $_ }

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
$events = @()
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
                    if ($seen.Add($key)) { $events += $e }
                } catch {}
            }
        }
    }
}
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
    foreach ($d1 in @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
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
    if ($p -and (Test-Path $p) -and ($p -notmatch $skipRe)) { $candidates.Add($p) }
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
$picked = @($scored | Sort-Object @{e = 'ev'; Descending = $true}, @{e = 'last'; Descending = $true} |
    Select-Object -First $MaxProjects)

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

$projects = @(foreach ($p in $picked) {
    $dir  = [string]$p.dir
    $name = Split-Path $dir -Leaf
    $parent = Split-Path $dir -Parent
    $label = if ($parent) { (Split-Path $parent -Leaf) + '\' + $name } else { $name }

    $isGit = $false
    $gitOut = git -C $dir rev-parse --is-inside-work-tree 2>$null
    if ("$gitOut".Trim() -eq 'true') { $isGit = $true }

    $branch = ''; $lastCommits = @(); $dirtyCount = 0; $dirtySample = @(); $lastCommitAt = ''
    if ($isGit) {
        $branch = "$(git -C $dir rev-parse --abbrev-ref HEAD 2>$null)".Trim()
        $lastCommits = @(git -C $dir log -5 --format='%ad %s' --date=format:'%Y-%m-%d' 2>$null |
            ForEach-Object { [string]$_ })
        $lastCommitAt = "$(git -C $dir log -1 --format='%ad' --date=format:'%Y-%m-%d %H:%M' 2>$null)".Trim()
        $dirty = @(git -C $dir status --porcelain 2>$null)
        $dirtyCount = $dirty.Count
        $dirtySample = @($dirty | Select-Object -First 8 | ForEach-Object { [string]$_ })
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
    $todoCount = 0; $todoSample = @()
    if ($isGit -and ($recent.Count -gt 0 -or $dirtyCount -gt 0)) {
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

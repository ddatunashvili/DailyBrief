# Two AI modes that never rewrite kanban.json:
#   -Mode ask    answers a free-text question about the project registry
#   -Mode ideas  proposes 3 new features for ONE project (accept/decline in UI)
# Same token diet as kanban-check.ps1: the script compresses everything into
# ask-digest-<runid>.json, the model reads only that file and writes a small
# ask-out-<runid>.json, and the script merges the result into ask-log.json /
# ideas.json. The model never opens a project file itself.
# ASCII-only on purpose (PS 5.1 encoding).
param(
    [ValidateSet('ask', 'ideas')][string]$Mode = 'ask',
    [string]$RunId = '',
    [string]$Dir = ''
)

# Force real UTF-8 before anything else runs, so no child process in the
# claude.cmd -> node chain inherits a stale codepage (Georgian question in,
# Georgian answer out).
& chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$base   = 'C:\Users\davit\OneDrive\Desktop\DailyBriefApp\core'
$now = Get-Date -Format 'yyyy-MM-dd HH:mm'
$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

$runToken   = if ($RunId) { $RunId } else { [guid]::NewGuid().ToString('N').Substring(0, 8) }
$log        = Join-Path $base ("ask-run-$runToken.log")
$digestPath = Join-Path $base ("ask-digest-$runToken.json")
$outPath    = Join-Path $base ("ask-out-$runToken.json")
if (Test-Path $outPath) { Remove-Item $outPath -Force }

# Resolved only AFTER the log path exists: when no working claude CLI is
# installed this throws, and without the catch the script died leaving no log
# at all - which the app used to journal as a successful run.
try {
    . (Join-Path $PSScriptRoot 'claude-path.ps1')   # sets $claude
} catch {
    [IO.File]::WriteAllText($log, ('[fatal] ' + $_.Exception.Message), $utf8NoBom)
    exit 3
}

$askLogPath = Join-Path $base 'ask-log.json'
$ideasPath  = Join-Path $base 'ideas.json'

# PS 5.1 serializes an EMPTY array inside an object as {}, so a round-tripped
# "no items" list comes back as an empty PSCustomObject.
function AsArr($v) {
    if ($null -eq $v) { return @() }
    if ($v -is [array]) { return $v }
    if ($v -is [string]) { return @($v) }
    if ($v -is [PSCustomObject] -and @($v.PSObject.Properties).Count -eq 0) { return @() }
    return @($v)
}

function Norm([string]$s) { return ($s + '').Trim().ToLowerInvariant() }

function Read-Json([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return ([string](Get-Content $path -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json }
    catch { return $null }
}

function Read-Head([string]$path, [int]$len) {
    if (-not (Test-Path $path)) { return '' }
    # The [string] cast is load-bearing: Get-Content -Raw returns a string
    # decorated with PSPath/Provider note properties, and ConvertTo-Json
    # serializes that whole provider graph (observed once: a 292 MB digest).
    $t = [string](Get-Content $path -Raw -Encoding UTF8)
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt $len) { $t = $t.Substring(0, $len) }
    return $t
}

# PS 5.1 renders an empty array inside an object as {}, which reads to the
# model as "an object with unknown contents" instead of "nothing here". Empty
# lists are simply left out of the digest, and the prompts say so.
function Add-IfAny($ht, [string]$key, $value) {
    $v = @($value)
    if ($v.Count -gt 0) { $ht[$key] = $v }
}

function Cut([string]$s, [int]$len) {
    $s = ($s + '')
    if ($s.Length -gt $len) { return $s.Substring(0, $len) }
    return $s
}

# ---------- ignore list (folders the user excluded from every scan) ----------
$ignoreDirs = @()
$ig = Read-Json (Join-Path $base 'ignore.json')
if ($ig) { $ignoreDirs = @(AsArr $ig.dirs | ForEach-Object { (Norm ([string]$_)) } | Where-Object { $_ }) }

function Is-Ignored([string]$path) {
    $p = Norm $path
    if (-not $p) { return $false }
    $sep = [char]92
    foreach ($d in $ignoreDirs) {
        if ($p -eq $d -or $p.StartsWith($d + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ---------- project registry (built by discover-projects.ps1, no AI) ----------
$projects = @()
$reg = Read-Json (Join-Path $base 'projects.json')
if ($reg) { $projects = @(AsArr $reg.projects | Where-Object { -not (Is-Ignored ([string]$_.dir)) }) }

# A one-line fingerprint of "where this project stands". Ideas are regenerated
# only when it changes - no commits, no dirty churn, no new suggestions.
function Project-Signature($p) {
    return ('{0}|{1}|{2}' -f [string]$p.lastCommitAt, [int]$p.dirtyCount, [int]$p.changed14d)
}

# Slim card: 40 of these are still only a couple of thousand tokens.
function Slim-Card($p) {
    $card = @{
        name = [string]$p.name; dir = [string]$p.dir
        changed14d = [int]$p.changed14d
    }
    Add-IfAny $card 'stack' (AsArr $p.stack | Select-Object -First 3)
    if ($p.isGit) {
        $card.branch = [string]$p.branch
        $card.dirtyCount = [int]$p.dirtyCount
        $card.lastCommitAt = [string]$p.lastCommitAt
        $c = @(AsArr $p.lastCommits)
        if ($c.Count -gt 0) { $card.lastCommit = Cut ([string]$c[0]) 90 }
    }
    if ([int]$p.todoCount -gt 0) { $card.todoCount = [int]$p.todoCount }
    $desc = [string]$p.pkgDesc
    if (-not $desc) { $desc = [string]$p.readme }
    if ($desc) { $card.what = Cut $desc 110 }
    return $card
}

# Full card: only for the projects the question is actually about.
function Full-Card($p) {
    $card = Slim-Card $p
    $card.what = Cut ([string]$p.pkgDesc) 200
    $card.readme = Cut ([string]$p.readme) 400
    Add-IfAny $card 'lastCommits' (AsArr $p.lastCommits | Select-Object -First 5 | ForEach-Object { [string]$_ })
    Add-IfAny $card 'dirtySample' (AsArr $p.dirtySample | Select-Object -First 8 | ForEach-Object { [string]$_ })
    Add-IfAny $card 'todoSample'  (AsArr $p.todoSample  | Select-Object -First 5 | ForEach-Object { [string]$_ })
    Add-IfAny $card 'recentFiles' (AsArr $p.recentFiles | Select-Object -First 8 | ForEach-Object { [string]$_ })
    return $card
}

function Find-Project([string]$dir) {
    if (-not $dir) { return $null }
    $d = Norm $dir
    foreach ($p in $projects) { if ((Norm ([string]$p.dir)) -eq $d) { return $p } }
    return $null
}

# ---------- open tasks, so nothing is proposed twice ----------
$kanban = Read-Json (Join-Path $base 'kanban.json')
$openTasks = @()
$doneTitles = @()
if ($kanban) {
    $openTasks = @(AsArr $kanban.tasks | Where-Object { -not $_.done } | ForEach-Object {
        @{ title = [string]$_.title; status = [string]$_.status; dir = [string](@(AsArr $_.dirs)[0]) }
    } | Select-Object -First 40)
    $doneTitles = @(AsArr $kanban.tasks | Where-Object { $_.done } |
        Select-Object -Last 10 | ForEach-Object { [string]$_.title })
}

function Tasks-For([string]$dir) {
    $d = Norm $dir
    return @($openTasks | Where-Object { (Norm ([string]$_.dir)) -eq $d } | ForEach-Object { [string]$_.title })
}

# ============================ digest ============================
if ($Mode -eq 'ask') {
    $thread = @()
    $al = Read-Json $askLogPath
    if ($al) { $thread = @(AsArr $al.messages) }
    $lastUser = @($thread | Where-Object { [string]$_.by -eq 'user' } | Select-Object -Last 1)
    if ($lastUser.Count -eq 0) {
        [IO.File]::WriteAllText($log, 'skipped: no question in ask-log.json - zero AI tokens spent', $utf8NoBom)
        exit 0
    }
    $question = [string]$lastUser[0].text
    $focusDir = [string]$lastUser[0].dir
    if (-not $focusDir) { $focusDir = $Dir }

    # Which projects deserve the full card: the one the question was asked
    # from, plus any whose name/dir/stack the question mentions. Everything
    # else stays a slim line.
    $fullDirs = New-Object System.Collections.Generic.List[string]
    if ($focusDir) { $fullDirs.Add((Norm $focusDir)) }
    # Words too generic to identify a project: without this "which PROJECT is
    # closest to done" pulls a full card for every folder named "projects".
    $stop = @('project', 'projects', 'folder', 'folders', 'code', 'app', 'apps', 'repo', 'this',
              'that', 'what', 'which', 'where', 'when', 'work', 'done', 'next', 'best', 'file', 'files')
    $words = @(($question.ToLowerInvariant() -split '[^a-z0-9_.\-]+') |
        Where-Object { $_.Length -ge 4 -and $stop -notcontains $_ })
    foreach ($p in $projects) {
        if ($fullDirs.Count -ge 3) { break }
        $hay = (Norm ([string]$p.name)) + ' ' + (Norm ([string]$p.dir)) + ' ' + (Norm ((AsArr $p.stack) -join ' '))
        foreach ($w in $words) {
            if ($hay.Contains($w)) {
                $nd = Norm ([string]$p.dir)
                if (-not $fullDirs.Contains($nd)) { $fullDirs.Add($nd) }
                break
            }
        }
    }

    $slim = @()
    $full = @()
    foreach ($p in $projects) {
        if ($fullDirs.Contains((Norm ([string]$p.dir)))) { $full += (Full-Card $p) }
        else { $slim += (Slim-Card $p) }
    }

    # Last few turns so a follow-up question ("and the second one?") lands.
    $history = @($thread | Select-Object -Last 7 | ForEach-Object {
        @{ by = [string]$_.by; text = Cut ([string]$_.text) 400 }
    })

    $digest = @{
        now = $now
        question = $question
        focusDir = $focusDir
        goals = Read-Head (Join-Path $base 'GOALS.md') 1200
    }
    Add-IfAny $digest 'projects' $slim
    Add-IfAny $digest 'focus' $full
    Add-IfAny $digest 'tasks' $openTasks
    Add-IfAny $digest 'recentDone' $doneTitles
    Add-IfAny $digest 'history' $history
    # -Compress on purpose: pretty-printed PS JSON is ~2x the bytes, and every
    # one of those indent spaces is a token the question pays for.
    [IO.File]::WriteAllText($digestPath, ($digest | ConvertTo-Json -Depth 6 -Compress), $utf8NoBom)
    $promptFile = 'prompt-ask.md'
}
else {
    if (-not $Dir) {
        [IO.File]::WriteAllText($log, 'skipped: ideas run without -Dir', $utf8NoBom)
        exit 0
    }
    $proj = Find-Project $Dir
    if (-not $proj) {
        [IO.File]::WriteAllText($log, 'skipped: project not in registry (or ignored)', $utf8NoBom)
        exit 0
    }

    # Everything already suggested for this folder, so the model cannot serve
    # the same idea twice - declined ones are the important half.
    $declined = @(); $accepted = @(); $pending = @()
    $store = Read-Json $ideasPath
    if ($store) {
        $declined = @(AsArr $store.declined | Where-Object { (Norm ([string]$_.dir)) -eq (Norm $Dir) } |
            ForEach-Object { [string]$_.title } | Select-Object -Last 25)
        $accepted = @(AsArr $store.accepted | Where-Object { (Norm ([string]$_.dir)) -eq (Norm $Dir) } |
            ForEach-Object { [string]$_.title } | Select-Object -Last 25)
        foreach ($e in @(AsArr $store.entries)) {
            if ((Norm ([string]$e.dir)) -ne (Norm $Dir)) { continue }
            # Older files kept accepted ideas on the card itself.
            $accepted += @(AsArr $e.ideas | Where-Object { [string]$_.state -eq 'accepted' } |
                ForEach-Object { [string]$_.title })
            # Still on the card and undecided: these stay, so they must not be
            # proposed a second time by this run.
            $pending = @(AsArr $e.ideas | Where-Object { [string]$_.state -eq 'new' } |
                ForEach-Object { [string]$_.title })
        }
        $accepted = @($accepted | Select-Object -Unique)
    }

    $digest = @{
        now = $now
        project = Full-Card $proj
        goals = Read-Head (Join-Path $base 'GOALS.md') 800
    }
    Add-IfAny $digest 'openTasks' (Tasks-For $Dir)
    Add-IfAny $digest 'declined' $declined
    Add-IfAny $digest 'accepted' $accepted
    Add-IfAny $digest 'pending' $pending
    # -Compress on purpose: pretty-printed PS JSON is ~2x the bytes, and every
    # one of those indent spaces is a token the question pays for.
    [IO.File]::WriteAllText($digestPath, ($digest | ConvertTo-Json -Depth 6 -Compress), $utf8NoBom)
    $promptFile = 'prompt-ideas.md'
}

# ---------- Claude: digest in, small JSON out ----------
$digestSize = (Get-Item $digestPath -ErrorAction SilentlyContinue).Length
if ($digestSize -gt 1MB) {
    [IO.File]::WriteAllText($log, ('skipped: digest too large ({0:N0} bytes) - not sent to the model' -f $digestSize), $utf8NoBom)
    exit 0
}

# The exact per-run file names go INTO the prompt: left to guess a suffixed
# name the model spends turns listing the folder and can write its answer
# where the script never looks for it.
$prompt = (Get-Content (Join-Path $base $promptFile) -Raw -Encoding UTF8).
    Replace('{{NOW}}', $now).
    Replace('{{DIGEST}}', ("ask-digest-$runToken.json")).
    Replace('{{OUT}}', ("ask-out-$runToken.json"))

Set-Location $base
$ErrorActionPreference = 'Continue'
# Judgment work, both modes: this is the one place where a cheaper model
# shows immediately (generic advice, repeated ideas).
$claudeArgs = @(
    '-p',
    '--model', 'sonnet',
    '--allowedTools', 'Read,Write',
    '--allow-dangerously-skip-permissions',
    '--dangerously-skip-permissions',
    '--max-turns', '6',
    '--output-format', 'json'
)
$prompt | & $claude @claudeArgs 2>&1 | Out-File $log -Encoding utf8
$ErrorActionPreference = 'Stop'

# ---------- merge the answer (only the script writes the stores) ----------
if (-not (Test-Path $outPath)) {
    Add-Content $log '[warn] model wrote no output file'
    Add-Content $log ('[timing] ask total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)
    exit 0
}

$out = Read-Json $outPath
if (-not $out) {
    Add-Content $log '[warn] output file is not valid JSON'
    exit 0
}

if ($Mode -eq 'ask') {
    $mutex = New-Object System.Threading.Mutex($false, 'DailyBriefAskWrite')
    $got = $false
    try {
        $got = $mutex.WaitOne(30000)
        $fresh = Read-Json $askLogPath
        $msgs = @()
        if ($fresh) { $msgs = @(AsArr $fresh.messages) }
        $suggested = @(AsArr $out.suggestedTasks | Select-Object -First 3 | ForEach-Object {
            New-Object PSObject -Property @{
                title = Cut ([string]$_.title) 120
                desc  = Cut ([string]$_.desc) 600
                dir   = [string]$_.dir
            }
        })
        $msgs += (New-Object PSObject -Property @{
            id = ('a' + $runToken)
            by = 'ai'
            at = $stamp
            text = [string]$out.answer
            projects = @(AsArr $out.projects | Select-Object -First 6 | ForEach-Object { [string]$_ })
            suggestedTasks = $suggested
        })
        if ($msgs.Count -gt 60) { $msgs = @($msgs | Select-Object -Last 60) }
        [IO.File]::WriteAllText($askLogPath, (@{ messages = $msgs } | ConvertTo-Json -Depth 8), $utf8NoBom)
    } catch {
        Add-Content $log ('[warn] ask-log merge failed: ' + $_.Exception.Message)
    } finally {
        if ($got) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
else {
    $mutex = New-Object System.Threading.Mutex($false, 'DailyBriefIdeasWrite')
    $got = $false
    try {
        $got = $mutex.WaitOne(30000)
        $fresh = Read-Json $ideasPath
        $entries = @(); $declinedAll = @(); $acceptedAll = @()
        if ($fresh) {
            $entries = @(AsArr $fresh.entries | Where-Object { (Norm ([string]$_.dir)) -ne (Norm $Dir) })
            $declinedAll = @(AsArr $fresh.declined)
            $acceptedAll = @(AsArr $fresh.accepted)
        }
        # Undecided ideas survive a regeneration - the user has not seen an
        # answer to them yet. Only the empty slots are refilled, so the card
        # always holds exactly three open suggestions. Decided ones are gone
        # from the card; their titles live in accepted/declined.
        $keep = @()
        if ($fresh) {
            foreach ($e in @(AsArr $fresh.entries)) {
                if ((Norm ([string]$e.dir)) -ne (Norm $Dir)) { continue }
                $keep = @(AsArr $e.ideas | Where-Object { [string]$_.state -eq 'new' } | Select-Object -First 3)
            }
        }
        $need = 3 - @($keep).Count
        if ($need -lt 0) { $need = 0 }
        $i = 0
        $newIdeas = @()
        if ($need -gt 0) { $newIdeas = @(AsArr $out.ideas | Select-Object -First $need | ForEach-Object {
            $i++
            New-Object PSObject -Property @{
                id = ('{0}-{1}' -f $runToken, $i)
                title = Cut ([string]$_.title) 120
                desc  = Cut ([string]$_.desc) 700
                why   = Cut ([string]$_.why) 300
                effort = [string]$_.effort
                subtasks = @(AsArr $_.subtasks | Select-Object -First 8 | ForEach-Object { Cut ([string]$_) 160 })
                state = 'new'
                at = $stamp
                taskId = ''
            }
        }) }
        $entries += (New-Object PSObject -Property @{
            dir = [string]$Dir
            name = [string]$proj.name
            generatedAt = $now
            signature = Project-Signature $proj
            ideas = @($keep + $newIdeas)
        })
        if ($entries.Count -gt 60) { $entries = @($entries | Select-Object -Last 60) }
        [IO.File]::WriteAllText($ideasPath,
            (@{ entries = $entries; declined = $declinedAll; accepted = $acceptedAll } | ConvertTo-Json -Depth 8), $utf8NoBom)
    } catch {
        Add-Content $log ('[warn] ideas merge failed: ' + $_.Exception.Message)
    } finally {
        if ($got) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

Remove-Item $outPath -Force -ErrorAction SilentlyContinue
Add-Content $log ('[timing] ask total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)

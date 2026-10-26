# Two AI modes that never rewrite kanban.json:
#   -Mode ask    answers a free-text question about the project registry
#   -Mode ideas  proposes 3 new features for ONE project (accept/decline in UI)
# Same token diet as kanban-check.ps1: the script compresses everything into
# ask-digest-<runid>.json, hands it to the model inline, gets a small
# schema-checked JSON back (kept as ask-out-<runid>.json until merged), and
# merges it into ask-log.json / ideas.json. The model has no tools at all.
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
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
. (Join-Path $PSScriptRoot 'lock.ps1')    # Invoke-WithBoardLock (ideas.json)
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
    . (Join-Path $PSScriptRoot 'claude-run.ps1')    # Invoke-ClaudeLean
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

# The digest rides in the prompt and the answer comes back as structured
# output: the model used to Read the digest and Write ask-out with tools,
# three turns of a full CLI session for a one-shot answer, and a reply that
# skipped the Write was a run with nothing saved. The digest file stays on
# disk because the AI usage page shows it as "exactly what the AI was given".
$digestJson = ([string](Get-Content $digestPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF)
$prompt = "<digest>`n" + $digestJson + "`n</digest>`n`n" +
    (Get-Content (Join-Path $app $promptFile) -Raw -Encoding UTF8).Replace('{{NOW}}', $now)

function Str { return @{ type = 'string' } }
function Arr($items) { return @{ type = 'array'; items = $items } }
function Obj([hashtable]$props, [string[]]$req) {
    return @{ type = 'object'; additionalProperties = $false; properties = $props; required = $req }
}
if ($Mode -eq 'ask') {
    $schemaObj = Obj @{
        answer = (Str)
        projects = Arr (Str)
        suggestedTasks = Arr (Obj @{ title = (Str); desc = (Str); dir = (Str) } @('title', 'desc', 'dir'))
    } @('answer', 'projects', 'suggestedTasks')
} else {
    $schemaObj = Obj @{
        ideas = Arr (Obj @{
            title = (Str); desc = (Str); why = (Str)
            effort = @{ type = 'string'; enum = @('S', 'M', 'L') }
            subtasks = Arr (Str)
        } @('title', 'desc', 'why', 'effort', 'subtasks'))
    } @('ideas')
}
$schema = $schemaObj | ConvertTo-Json -Depth 20 -Compress

# Same deterministic similarity as brief-apply.ps1: a reworded declined idea
# is still a declined idea.
$titleStop = @('a', 'an', 'the', 'and', 'or', 'to', 'for', 'of', 'in', 'on', 'with', 'from', 'into', 'by', 'at', 'is')
function Title-Tokens([string]$s) {
    $set = @{}
    foreach ($w in ((Norm $s) -split '[^\p{L}\p{N}]+')) {
        if ($w.Length -ge 2 -and $titleStop -notcontains $w) { $set[$w] = $true }
    }
    return $set
}
function Test-SimilarTitle([string]$a, [string]$b) {
    $na = ((Norm $a) -replace '[^\p{L}\p{N}]+', ' ').Trim()
    $nb = ((Norm $b) -replace '[^\p{L}\p{N}]+', ' ').Trim()
    if (-not $na -or -not $nb) { return $false }
    if ($na -eq $nb) { return $true }
    $short = $na; $long = $nb
    if ($na.Length -gt $nb.Length) { $short = $nb; $long = $na }
    if ($short.Length -ge 8 -and $long.Contains($short)) { return $true }
    $ta = Title-Tokens $a
    $tb = Title-Tokens $b
    if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return $false }
    $inter = 0
    foreach ($k in $ta.Keys) { if ($tb.ContainsKey($k)) { $inter++ } }
    return (($inter / [double]($ta.Count + $tb.Count - $inter)) -ge 0.6)
}

$knownDirs = @{}
foreach ($p in $projects) { if ($p.dir) { $knownDirs[(Norm ([string]$p.dir))] = [string]$p.dir } }

# Returns @{ clean; hard; soft }: hard = nothing usable, soft = single bad
# items (left out of `clean`), worth one retry but not worth losing the run.
function Test-AskOut($d) {
    $hard = New-Object System.Collections.Generic.List[string]
    $soft = New-Object System.Collections.Generic.List[string]
    if ($Mode -eq 'ask') {
        $answer = ([string]$d.answer).Trim()
        if (-not $answer) { $hard.Add('answer is empty') }
        # A dir the registry does not hold would render as a dead chip.
        $projs = @(AsArr $d.projects | ForEach-Object { $knownDirs[(Norm ([string]$_))] } | Where-Object { $_ } |
            Select-Object -Unique -First 6)
        $sug = @()
        foreach ($s in @(AsArr $d.suggestedTasks)) {
            if (-not $s -or -not $s.title) { continue }
            $sd = $knownDirs[(Norm ([string]$s.dir))]
            if (-not $sd) { $soft.Add(('suggestedTasks "{0}": dir "{1}" is not a project dir from the digest' -f [string]$s.title, [string]$s.dir)); continue }
            $dup = $null
            foreach ($ot in $openTasks) { if (Test-SimilarTitle ([string]$s.title) ([string]$ot.title)) { $dup = [string]$ot.title; break } }
            if ($dup) { $soft.Add(('suggestedTasks "{0}" repeats the open task "{1}"' -f [string]$s.title, $dup)); continue }
            $sug += [ordered]@{ title = Cut ([string]$s.title) 120; desc = Cut ([string]$s.desc) 600; dir = $sd }
        }
        $clean = [ordered]@{ answer = $answer; projects = $projs; suggestedTasks = @($sug | Select-Object -First 3) }
    } else {
        $taken = @($declined) + @($accepted) + @($pending) + @(Tasks-For $Dir)
        $ideas = @()
        foreach ($it in @(AsArr $d.ideas)) {
            if (-not $it -or -not $it.title -or -not $it.desc) { continue }
            $dup = $null
            foreach ($tt in $taken) { if (Test-SimilarTitle ([string]$it.title) ([string]$tt)) { $dup = [string]$tt; break } }
            if ($dup) { $soft.Add(('idea "{0}" repeats "{1}", which is declined, accepted, pending or already a task' -f [string]$it.title, $dup)); continue }
            $subs = @(AsArr $it.subtasks | Where-Object { $_ } | ForEach-Object { [string]$_ })
            if ($subs.Count -lt 3) { $soft.Add(('idea "{0}" has {1} subtasks; it needs 3-6' -f [string]$it.title, $subs.Count)); continue }
            $eff = [string]$it.effort
            if (@('S', 'M', 'L') -notcontains $eff) { $eff = 'M' }
            $ideas += [ordered]@{
                title = Cut ([string]$it.title) 120; desc = Cut ([string]$it.desc) 700; why = Cut ([string]$it.why) 300
                effort = $eff; subtasks = @($subs | Select-Object -First 6)
            }
            $taken += [string]$it.title
        }
        if ($ideas.Count -gt 3) { $ideas = @($ideas | Select-Object -First 3) }
        if ($ideas.Count -eq 0) { $hard.Add('no usable idea: each needs a title, a desc and 3-6 subtasks, and must not repeat a listed one') }
        elseif ($ideas.Count -lt 3) { $soft.Add(('only {0} usable ideas; exactly 3 are needed' -f $ideas.Count)) }
        $sizes = @($ideas | ForEach-Object { $_.effort } | Sort-Object -Unique)
        if ($ideas.Count -eq 3 -and $sizes.Count -ne 3) { $soft.Add('the three ideas must be one S, one M and one L') }
        $clean = [ordered]@{ ideas = $ideas }
    }
    return @{ clean = $clean; hard = $hard; soft = $soft }
}

# Every attempt leaves its own CLI envelope in the log, but main.js reads
# only the last one. After a retry, a combined line keeps the journal honest.
function Add-CombinedUsage([string]$Log, $envs) {
    $e = @($envs | Where-Object { $_ })
    if ($e.Count -lt 2) { return }
    $in = 0; $cr = 0; $cc = 0; $out = 0; $cost = 0.0; $turns = 0; $ms = 0
    foreach ($x in $e) {
        if ($x.usage) {
            $in += [int]$x.usage.input_tokens; $out += [int]$x.usage.output_tokens
            $cr += [int]$x.usage.cache_read_input_tokens; $cc += [int]$x.usage.cache_creation_input_tokens
        }
        $cost += [double]$x.total_cost_usd; $turns += [int]$x.num_turns; $ms += [int]$x.duration_ms
    }
    $last = $e[$e.Count - 1]
    $line = [ordered]@{
        type = 'result'; subtype = [string]$last.subtype; is_error = [bool]$last.is_error
        num_turns = $turns; duration_ms = $ms; total_cost_usd = $cost
        usage = [ordered]@{ input_tokens = $in; cache_creation_input_tokens = $cc; cache_read_input_tokens = $cr; output_tokens = $out }
        result = ('combined usage of {0} attempts' -f $e.Count)
    }
    Add-Content -Path $Log -Value ($line | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8
}

Set-Location $base
# Judgment work, both modes: this is the one place where a cheaper model
# shows immediately (generic advice, repeated ideas). The system prompt is
# ours: the user's own style hooks no longer reach the answer.
$system = 'You are the project adviser inside DailyBrief, a personal desktop app. Write in plain, complete English sentences: no shorthand, no dropped articles, no telegraphic notes. Return only the structured output.'
$envelopes = @()
$best = $null
$errs = @()
for ($attempt = 1; $attempt -le 2; $attempt++) {
    $p = $prompt
    if ($errs.Count -gt 0) {
        $p += "`n`n## Your previous answer was rejected`nFix every problem below and return the complete corrected answer:`n- " + ($errs -join "`n- ")
    }
    $r = Invoke-ClaudeLean -Prompt $p -Log $log -System $system -Model 'sonnet' -Schema $schema
    $envelopes += $r.envelope
    if (-not $r.ok) {
        Add-Content $log ('[info] attempt {0}: {1}' -f $attempt, $r.error)
        $errs = @()
        continue
    }
    try { $v = Test-AskOut $r.data }
    catch { $v = @{ clean = $null; hard = @('answer could not be read: ' + $_.Exception.Message); soft = @() } }
    if ($v.hard.Count -eq 0) {
        $best = $v
        if ($v.soft.Count -eq 0) { break }
    }
    $errs = @($v.hard) + @($v.soft)
    Add-Content $log ('[info] attempt {0} failed validation: {1}' -f $attempt, ($errs -join '; '))
}
Add-CombinedUsage $log $envelopes

# ---------- merge the answer (only the script writes the stores) ----------
# Same failure line as before (main.js translates it for the user): nothing
# usable came back, nothing is saved.
if (-not $best) {
    Add-Content $log '[warn] model wrote no output file'
    Add-Content $log ('[timing] ask total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)
    exit 0
}
foreach ($s in @($best.soft)) { Add-Content $log ('[warn] dropped from model output: ' + $s) }
[IO.File]::WriteAllText($outPath, ($best.clean | ConvertTo-Json -Depth 8), $utf8NoBom)

$out = Read-Json $outPath
if (-not $out) {
    Add-Content $log '[warn] output file is not valid JSON'
    exit 0
}

if ($Mode -eq 'ask') {
    # board.lock, not a private mutex: main.js writes ask-log.json too (the
    # user's question in ask:send) and can only take the shared lockfile.
    try {
        Invoke-WithBoardLock {
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
        }
    } catch {
        Add-Content $log ('[warn] ask-log merge failed: ' + $_.Exception.Message)
    }
}
else {
    # The shared board lock, not a private mutex: main.js runs ideas for
    # several projects in parallel, and every one of them rewrites the whole
    # ideas.json - without the lock the last writer drops the others' cards.
    try {
        Invoke-WithBoardLock {
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
        }
    } catch {
        Add-Content $log ('[warn] ideas merge failed: ' + $_.Exception.Message)
    }
}

Remove-Item $outPath -Force -ErrorAction SilentlyContinue
Add-Content $log ('[timing] ask total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)

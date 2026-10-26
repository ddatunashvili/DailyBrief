# Daily briefing generator: runs Claude Code headless, writes today's briefing, opens it.
# Launched by the Electron shell (with -NoShow) or standalone. ASCII-only on purpose (PS 5.1 encoding).
param(
    [switch]$NoShow,
    # Replan: throw away today's briefing and regenerate it. Claude sees
    # done\<today>.json (checked-off tasks) and plans the remaining day.
    [switch]$Force
)

# Force real UTF-8 as early as possible, before anything else runs, so no
# child process in the claude.cmd -> node chain can inherit a stale codepage.
& chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'paths.ps1')   # sets $app (install) and $base (this user's data)
$today  = Get-Date -Format 'yyyy-MM-dd'
$brief  = Join-Path $base "briefings\$today.md"
$log    = Join-Path $base 'last-run.log'
try {
    . (Join-Path $PSScriptRoot 'claude-path.ps1')   # sets $claude
    . (Join-Path $PSScriptRoot 'claude-run.ps1')    # Invoke-ClaudeLean
} catch {
    # No working claude CLI: leave a log, or the app journals a run that never
    # happened as a success.
    [IO.File]::WriteAllText($log, ('[fatal] ' + $_.Exception.Message), (New-Object Text.UTF8Encoding $false))
    exit 3
}

function Show-Brief([string]$Path) {
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA',
        '-File', (Join-Path $app 'show-brief.ps1'), '-Path', "`"$Path`""
    )
}

# Already generated today (e.g. second logon): nothing to do unless replanning.
if (Test-Path $brief) {
    if ($Force) {
        Remove-Item $brief -Force
    } else {
        # Nothing to do today. Written down on purpose: an early exit that
        # left last-run.log untouched made the app re-journal the PREVIOUS
        # run's tokens and cost as a brand new successful run.
        [IO.File]::WriteAllText($log, 'skipped: brief for today already exists - zero AI tokens spent', (New-Object Text.UTF8Encoding $false))
        if (-not $NoShow) { Show-Brief $brief }
        exit 0
    }
}

# One digest in, one json out. The model used to open the registry, the board,
# the snapshots and yesterday's brief one Read at a time and then write five
# files - eleven round trips for work the scripts can do in half a second.
# Now it reads nothing and writes nothing: the digest rides in the prompt and
# this script writes brief-out from the structured answer.
$digestPath = Join-Path $base ("brief-digest-$today.json")
$outPath    = Join-Path $base ("brief-out-$today.json")
if (Test-Path $outPath) { Remove-Item $outPath -Force }

# A replan doesn't need fresh activity data - the snapshots are a morning job.
if (-not $Force) {
    # Snapshot watched folders (dirs.txt) so Claude can diff against previous days
    # and measure real progress without any manual logging.
    $snapDir = Join-Path $base 'snapshots'
    New-Item -ItemType Directory -Force $snapDir | Out-Null
    $snap = Join-Path $snapDir "$today.txt"
    # Directory-level stats only - no file names, no file contents (privacy by design).
    # No dirs.txt yet (fresh account) means no watched folders, not a failed
    # run: the snapshot is simply empty and the day is planned without it.
    $dirsFile = Join-Path $base 'dirs.txt'
    if (-not (Test-Path $dirsFile)) { [IO.File]::WriteAllText($dirsFile, '', (New-Object Text.UTF8Encoding $false)) }
    Get-Content $dirsFile -Encoding UTF8 |
        Where-Object { $_.Trim() -and (Test-Path $_.Trim()) } |
        ForEach-Object { Get-ChildItem $_.Trim() -Recurse -File -ErrorAction SilentlyContinue } |
        Group-Object DirectoryName |
        ForEach-Object {
            $latest = ($_.Group | Measure-Object LastWriteTime -Maximum).Maximum
            $bytes  = ($_.Group | Measure-Object Length -Sum).Sum
            '{0:yyyy-MM-dd HH:mm}  {1,5} files  {2,14:N0} B  {3}' -f $latest, $_.Count, $bytes, $_.Name
        } |
        Sort-Object -Descending |
        Out-File $snap -Encoding utf8
    # Top active directories. Scored from the project registry (which the app
    # refreshes every 30 minutes), not from a fresh recursive scan of every
    # work root - that scan alone took four minutes of the morning run.
    $topFile = Join-Path $base 'top-dirs.txt'
    & (Join-Path $app 'discover-dirs.ps1') -OutFile $topFile -Top 10
    if (Test-Path $topFile) {
        Copy-Item $topFile (Join-Path $snapDir "activity-$today.txt") -Force
    }

    # Keep two weeks of each snapshot series (file snapshots and activity lists).
    Get-ChildItem $snapDir -File |
        Group-Object { $_.Name -replace '\d{4}-\d{2}-\d{2}', '' } |
        ForEach-Object { $_.Group | Sort-Object Name -Descending | Select-Object -Skip 14 | Remove-Item -Force }
}

$digestArgs = @{ Out = $digestPath; Today = $today }
if ($Force) { $digestArgs['Replan'] = $true }
& (Join-Path $app 'brief-digest.ps1') @digestArgs | Out-File $log -Encoding utf8

$promptFile = if ($Force) { 'prompt-replan.md' } else { 'prompt.md' }
$isReplan = [bool]$Force

# The digest goes INTO the prompt. The model used to Read it and Write its
# answer with tools: three turns of a full CLI session (~135k input tokens)
# for one ~12k-token digest, and a run that answered in prose instead of
# writing the file was a whole morning run wasted.
$digestJson = ([string](Get-Content $digestPath -Raw -Encoding UTF8)).TrimStart([char]0xFEFF)
$digest = $digestJson | ConvertFrom-Json
$promptBody = (Get-Content (Join-Path $app $promptFile) -Raw -Encoding UTF8).
    Replace('{{TODAY}}', $today)
$prompt = "<digest>`n" + $digestJson + "`n</digest>`n`n" + $promptBody

# ---------- output contract ----------
# The CLI validates the answer against this schema, so the shape is enforced
# before a single line of PowerShell looks at it. What a schema cannot say
# (ids that must exist, weights that must add up, length caps) is checked
# below in Test-BriefOut.
function Str { return @{ type = 'string' } }
function Arr($items) { return @{ type = 'array'; items = $items } }
function Obj([hashtable]$props, [string[]]$req) {
    return @{ type = 'object'; additionalProperties = $false; properties = $props; required = $req }
}
$statusEnum = @{ type = 'string'; enum = @('urgent', 'important', 'planning', 'delayed', 'active') }
$briefSchema = Obj @{
    date = (Str); dateLabel = (Str); tldr = (Str)
    tasks = Arr (Obj @{ id = (Str); title = (Str); desc = (Str); weight = @{ type = 'integer' }; badge = (Str) } @('id', 'title', 'desc', 'weight', 'badge'))
    warnings = Arr (Obj @{ sev = @{ type = 'string'; enum = @('crit', 'warn', 'note') }; label = (Str); text = (Str) } @('sev', 'label', 'text'))
    recap = Arr (Str)
    assessment = Arr (Str)
} @('date', 'dateLabel', 'tldr', 'tasks', 'warnings', 'recap', 'assessment')
$newTaskSchema = Obj @{ id = (Str); title = (Str); desc = (Str); status = $statusEnum; dir = (Str); subtasks = Arr (Str) } @('id', 'title', 'desc', 'status', 'dir', 'subtasks')
if ($isReplan) {
    $updateSchema = Obj @{ id = (Str); status = $statusEnum; note = (Str) } @('id', 'note')
    $schemaObj = Obj @{
        brief = $briefSchema
        kanban = Obj @{ updates = Arr $updateSchema; newTasks = Arr $newTaskSchema } @('updates', 'newTasks')
    } @('brief', 'kanban')
} else {
    $updateSchema = Obj @{ id = (Str); desc = (Str); status = $statusEnum; subtasks = Arr (Str); note = (Str) } @('id', 'note')
    $schemaObj = Obj @{
        brief = $briefSchema
        state = (Str); goals = (Str)
        questions = Arr (Obj @{ id = (Str); text = (Str); project = (Str) } @('id', 'text', 'project'))
        kanban = Obj @{ updates = Arr $updateSchema; newTasks = Arr $newTaskSchema } @('updates', 'newTasks')
    } @('brief', 'state', 'goals', 'questions', 'kanban')
}
$schema = $schemaObj | ConvertTo-Json -Depth 20 -Compress

# ---------- validation ----------
function AsArr($v) {
    if ($null -eq $v) { return @() }
    if ($v -is [array]) { return $v }
    if ($v -is [string]) { return @($v) }
    if ($v -is [PSCustomObject] -and @($v.PSObject.Properties).Count -eq 0) { return @() }
    return @($v)
}
# Over-long text is cut, not sent back: a retry costs a whole run, a trimmed
# sentence costs nothing. Cut at a sentence end when one is close, else at a word.
function Cut([string]$s, [int]$n) {
    $t = ($s + '').Trim()
    if ($t.Length -le $n) { return $t }
    $c = $t.Substring(0, $n)
    $dot = $c.LastIndexOf('. ')
    if ($dot -gt ($n * 0.5)) { return $c.Substring(0, $dot + 1) }
    $sp = $c.LastIndexOf(' ')
    if ($sp -gt ($n * 0.6)) { $c = $c.Substring(0, $sp) }
    return $c.TrimEnd(' ', ',', ';', ':', '-')
}
function Slug([string]$s) {
    $t = (($s + '').ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($t.Length -gt 40) { $t = $t.Substring(0, 40).Trim('-') }
    return $t
}

$openIds = @{}
foreach ($t in @(AsArr $digest.openTasks)) { $openIds[[string]$t.id] = $true }
$projDirs = @{}
foreach ($p in @(AsArr $digest.projects)) { if ($p.dir) { $projDirs[([string]$p.dir).ToLowerInvariant()] = [string]$p.dir } }
$validStatus = @('urgent', 'important', 'planning', 'delayed', 'active')

# Returns @{ clean; hard; soft }. `clean` is what brief-apply gets, already
# capped and normalized, with every item that failed a soft check left out.
# Hard errors mean there is no usable brief at all; soft errors are single
# bad items, worth one retry but not worth losing the morning over.
function Test-BriefOut($d) {
    $hard = New-Object System.Collections.Generic.List[string]
    $soft = New-Object System.Collections.Generic.List[string]
    $b = $d.brief
    if (-not $b) { $hard.Add('brief is missing'); return @{ clean = $null; hard = $hard; soft = $soft } }

    $tldr = Cut ([string]$b.tldr) 400
    if (-not $tldr) { $hard.Add('brief.tldr is empty') }
    $label = [string]$b.dateLabel
    if (-not $label) { $label = (Get-Date $today).ToString('dddd, d MMMM', [Globalization.CultureInfo]::GetCultureInfo('en-US')) }

    $tasks = @(AsArr $b.tasks | Where-Object { $_ -and $_.title })
    if ($tasks.Count -gt 5) { $tasks = @($tasks | Select-Object -First 5) }
    if ($tasks.Count -lt 3) { $hard.Add(('brief.tasks has {0} usable items; it needs 3-5, each with a title' -f $tasks.Count)) }
    $seenIds = @{}
    $outTasks = @()
    $i = 0
    foreach ($t in $tasks) {
        $i++
        $id = Slug ([string]$t.id)
        if (-not $id) { $id = Slug ([string]$t.title) }
        if (-not $id -or $seenIds[$id]) { $id = ('task-{0}' -f $i) }
        $seenIds[$id] = $true
        $w = [int]$t.weight
        if ($w -lt 0) { $w = 0 }
        $outTasks += [ordered]@{ id = $id; title = Cut ([string]$t.title) 140; desc = Cut ([string]$t.desc) 250; weight = $w; badge = [string]$t.badge }
    }
    $sum = 0
    foreach ($t in $outTasks) { $sum += $t.weight }
    if ($outTasks.Count -gt 0 -and $sum -ne 100) {
        # Off by rounding (or by a trimmed sixth task): rescale. Off by more
        # than that is a plan that does not add up, and that goes back.
        if ($sum -ge 90 -and $sum -le 110) {
            $acc = 0; $top = $outTasks[0]
            foreach ($t in $outTasks) {
                $t.weight = [int][Math]::Round($t.weight * 100.0 / $sum)
                $acc += $t.weight
                if ($t.weight -gt $top.weight) { $top = $t }
            }
            $top.weight += (100 - $acc)
        } else {
            $hard.Add(('brief.tasks weights sum to {0}; they must sum to 100' -f $sum))
        }
    }
    foreach ($t in $outTasks) {
        if (-not $t.badge -or $t.badge -match '^\s*\d+\s*%') { $t.badge = ('{0}% of the day' -f $t.weight) }
    }

    $warnings = @(AsArr $b.warnings | Where-Object { $_ -and $_.text } | ForEach-Object {
        $sev = [string]$_.sev
        if (@('crit', 'warn', 'note') -notcontains $sev) { $sev = 'note' }
        [ordered]@{ sev = $sev; label = Cut ([string]$_.label) 80; text = Cut ([string]$_.text) 400 }
    })
    $recap = @(AsArr $b.recap | Where-Object { $_ } | Select-Object -First 3 | ForEach-Object { Cut ([string]$_) 250 })
    $maxAss = if ($isReplan) { 1 } else { 2 }
    $assessment = @(AsArr $b.assessment | Where-Object { $_ } | Select-Object -First $maxAss | ForEach-Object { Cut ([string]$_) 500 })

    $clean = [ordered]@{
        brief = [ordered]@{
            date = $today; dateLabel = $label; tldr = $tldr
            tasks = $outTasks; warnings = $warnings; recap = $recap; assessment = $assessment
        }
    }

    if (-not $isReplan) {
        $state = Cut ([string]$d.state) 1200
        if (-not $state) { $soft.Add('state is empty; it must hold the full new STATE.md text') }
        else { $clean.state = $state }
        $clean.goals = [string]$d.goals
        $clean.questions = @(AsArr $d.questions | Where-Object { $_ -and $_.text } | Select-Object -First 3 | ForEach-Object {
            $qid = Slug ([string]$_.id)
            if (-not $qid) { $qid = Slug ([string]$_.text) }
            [ordered]@{ id = $qid; text = Cut ([string]$_.text) 300; project = [string]$_.project }
        })
    }

    $k = $d.kanban
    $updates = @()
    foreach ($u in @(AsArr $k.updates)) {
        if (-not $u) { continue }
        $uid = [string]$u.id
        if (-not $openIds[$uid]) { $soft.Add(('kanban.updates id "{0}" is not an id from openTasks' -f $uid)); continue }
        $o = [ordered]@{ id = $uid }
        if ($u.status -and $validStatus -contains [string]$u.status) { $o.status = [string]$u.status }
        if (-not $isReplan) {
            if ($u.desc) { $o.desc = Cut ([string]$u.desc) 250 }
            $subs = @(AsArr $u.subtasks | Where-Object { $_ } | ForEach-Object { Cut ([string]$_) 200 })
            if ($subs.Count -gt 0) { $o.subtasks = @($subs | Select-Object -First 30) }
        }
        if ($u.note) { $o.note = Cut ([string]$u.note) 300 }
        $updates += $o
    }
    $newTasks = @()
    foreach ($n in @(AsArr $k.newTasks)) {
        if (-not $n -or -not $n.title) { continue }
        $title = [string]$n.title
        $dir = $projDirs[([string]$n.dir).ToLowerInvariant()]
        if (-not $dir) { $soft.Add(('kanban.newTasks "{0}": dir "{1}" is not a project dir from the digest' -f $title, [string]$n.dir)); continue }
        $subs = @(AsArr $n.subtasks | Where-Object { $_ } | ForEach-Object { Cut ([string]$_) 200 })
        if ($subs.Count -lt 3) { $soft.Add(('kanban.newTasks "{0}" has {1} subtasks; it needs 3-7' -f $title, $subs.Count)); continue }
        $nid = Slug ([string]$n.id)
        if (-not $nid) { $nid = Slug $title }
        $st = [string]$n.status
        if ($validStatus -notcontains $st) { $st = 'planning' }
        $newTasks += [ordered]@{
            id = $nid; title = Cut $title 140; desc = Cut ([string]$n.desc) 250
            status = $st; dir = $dir; subtasks = @($subs | Select-Object -First 7)
        }
    }
    $clean.kanban = [ordered]@{ updates = $updates; newTasks = $newTasks }
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

# ---------- the call: one try, one retry with the reasons ----------
Set-Location $base
# sonnet for the daily brief and replans: language quality matters here.
# --effort low: the judgment is in the digest and the rules, not in the
# deliberation. At the default effort the run spent six thousand tokens
# thinking - most of the morning's wall clock - to reach the same plan.
# The system prompt is ours, not the CLI's and not the user's own hooks: a
# personal "write tersely" style once leaked into the briefing prose.
$system = 'You are the planning engine of DailyBrief, a personal desktop app. Write in plain, complete English sentences: no shorthand, no dropped articles, no telegraphic notes. Return only the structured output.'
$envelopes = @()
$best = $null
$errs = @()
for ($attempt = 1; $attempt -le 2; $attempt++) {
    $p = $prompt
    if ($errs.Count -gt 0) {
        $p += "`n`n## Your previous answer was rejected`nFix every problem below and return the complete corrected answer:`n- " + ($errs -join "`n- ")
    }
    $r = Invoke-ClaudeLean -Prompt $p -Log $log -System $system -Model 'sonnet' -Effort 'low' -Schema $schema
    $envelopes += $r.envelope
    if (-not $r.ok) {
        Add-Content $log ('[info] attempt {0}: {1}' -f $attempt, $r.error)
        $errs = @()
        continue
    }
    try { $v = Test-BriefOut $r.data }
    catch { $v = @{ clean = $null; hard = @('answer could not be read: ' + $_.Exception.Message); soft = @() } }
    if ($v.hard.Count -eq 0) {
        $best = $v
        if ($v.soft.Count -eq 0) { break }
    }
    $errs = @($v.hard) + @($v.soft)
    Add-Content $log ('[info] attempt {0} failed validation: {1}' -f $attempt, ($errs -join '; '))
}
Add-CombinedUsage $log $envelopes
$ErrorActionPreference = 'Stop'

if ($best) {
    # Single bad items that survived the retry are dropped, not fatal.
    foreach ($s in @($best.soft)) { Add-Content $log ('[warn] dropped from model output: ' + $s) }
    [IO.File]::WriteAllText($outPath, ($best.clean | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
} else {
    # Same failure path as before: no out file, brief-apply reports it.
    Add-Content $log '[warn] model output failed validation twice - nothing applied'
}

# Every file the run produces is written here, from that one json.
& (Join-Path $app 'brief-apply.ps1') -In $outPath -Today $today 2>&1 |
    ForEach-Object { Add-Content $log ([string]$_) }

Add-Content $log ('[timing] total {0:N0}s' -f $stopwatch.Elapsed.TotalSeconds)

# Today's brief lives in briefs\<date>.json and the app reads it from there
# over IPC. The page itself is installed program content - shared by every
# user on the machine, read-only inside the packaged asar - so the run must
# never write into it. Validate the JSON here instead: a broken file is worth
# a log line now rather than an empty page at 8am.
$briefReady = $false
$briefJsonPath = Join-Path $base ('briefs\' + $today + '.json')
try {
    if (Test-Path $briefJsonPath) {
        $null = (Get-Content $briefJsonPath -Raw -Encoding UTF8).Trim() | ConvertFrom-Json
        $briefReady = $true
    } else {
        Add-Content $log '[warn] briefs json for today not found; app has nothing new to show'
    }
} catch {
    Add-Content $log ('[warn] briefs json for today is not valid JSON: ' + $_.Exception.Message)
}

# Optional follow-up run: publish a web copy of today's brief. Off unless this
# user dropped a publish.json in their data folder (it holds their own artifact
# URL), because publishing is personal - one account, one link.
if ($briefReady -and (Test-Path (Join-Path $base 'publish.json'))) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (Join-Path $app 'publish-page.ps1'), '-Today', $today
    )
}

if (Test-Path $brief) {
    if (-not $NoShow) { Show-Brief $brief }
} else {
    # Claude failed to produce the briefing. Surface the log only when running
    # standalone - in app mode (-NoShow) the app is the only UI, no popups.
    if (-not $NoShow) { Show-Brief $log }
}

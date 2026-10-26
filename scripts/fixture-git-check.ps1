# Builds a throwaway data folder + git repos under %TEMP% and runs
# core\kanban-check.ps1 against it, asserting what the check digest says about
# the cases that used to go wrong: feature-branch commits, a baseline sha that
# no longer exists (amend + gc), a task linked to a subfolder of a bigger repo,
# a build commit drowning the real file in dist\ noise, cumulative evidence
# since the task was linked, and a linked folder that moved.
#
#   powershell -NoProfile -File scripts\fixture-git-check.ps1            # digest only, zero tokens
#   powershell -NoProfile -File scripts\fixture-git-check.ps1 -RunModel  # + one real haiku check
#
# Never touches the real data folder: DAILYBRIEF_DATA points at the fixture.
# ASCII-only on purpose (PS 5.1 encoding).
param(
    [string]$Root = (Join-Path $env:TEMP 'dailybrief-fixture'),
    [switch]$RunModel
)

$ErrorActionPreference = 'Continue'
$core = Join-Path (Split-Path $PSScriptRoot) 'core'
$u8 = New-Object System.Text.UTF8Encoding $false

if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
$data = Join-Path $Root 'data'
$work = Join-Path $Root 'work'           # the work root the relink searches
$gone = Join-Path $Root 'gone'           # where moved folders used to be (does not exist)
New-Item -ItemType Directory -Force $data, $work, (Join-Path $data 'scans') | Out-Null

function FxGit([string]$dir) {
    # Commit dates are set per call through the environment: everything here
    # happens within one minute, and the --since fallback needs real gaps.
    & git -C $dir -c user.name=fixture -c user.email=fixture@example.invalid -c core.autocrlf=false @args 2>$null
}
function Put([string]$dir, [string]$rel, [string]$text) {
    $p = Join-Path $dir $rel
    New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
    [IO.File]::WriteAllText($p, $text, $u8)
}
function At([datetime]$t) {
    $s = $t.ToString('yyyy-MM-ddTHH:mm:ss')
    $env:GIT_AUTHOR_DATE = $s; $env:GIT_COMMITTER_DATE = $s
}
function Commit([string]$dir, [string]$msg, [datetime]$t) {
    At $t
    FxGit $dir add -A | Out-Null
    FxGit $dir commit -q -m $msg | Out-Null
    return [string](FxGit $dir rev-parse HEAD)
}
function Fmt([datetime]$t) { return $t.ToString('yyyy-MM-dd HH:mm') }
function Write-Json([string]$path, $obj) { [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 8), $u8) }
function Read-Json([string]$path) { return (([string](Get-Content $path -Raw -Encoding UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json) }

$now = Get-Date
$env:DAILYBRIEF_DATA = $data

# ---------- repo A: subfolder task, branches, orphaned baseline, noise ----------
$repoA = Join-Path $work 'repoA'
$appA = Join-Path $repoA 'app'
New-Item -ItemType Directory -Force $repoA | Out-Null
FxGit $repoA init -q -b main | Out-Null
Put $repoA 'README.md' 'repo A'
Put $repoA 'server.js' 'root'
Put $repoA 'app\src\main.js' 'main'
$rootA = Commit $repoA 'init' $now.AddDays(-3)

# Baseline as the scanner writes it, then moved back in time: the linked
# point three days ago at the root commit.
& (Join-Path $core 'scan-folder.ps1') -TaskId 'fx-sub' -Dir $appA
$scanSubPath = Join-Path $data 'scans\fx-sub.json'
$s = Read-Json $scanSubPath
$s.linkedAt = Fmt $now.AddDays(-3).AddMinutes(1); $s.scannedAt = $s.linkedAt
Write-Json $scanSubPath $s

Put $repoA 'app\src\Billing.js' 'billing'
$null = Commit $repoA 'feat: add Billing.js' $now.AddDays(-2)
Put $repoA 'server.js' 'root tweak'
$null = Commit $repoA 'feat: root server tweak' $now.AddDays(-2).AddHours(1)

# "Check 1" baselined at commit X, which is then amended away and collected:
# the stored sha no longer exists anywhere.
Put $repoA 'app\src\pre.js' 'pre'
$x = Commit $repoA 'wip: pre' $now.AddDays(-1)
$s = Read-Json $scanSubPath
$s.head = $x; $s.scannedAt = Fmt $now.AddDays(-1).AddMinutes(1)
Write-Json $scanSubPath $s
At $now.AddDays(-1).AddSeconds(20)
FxGit $repoA commit -q --amend -m 'wip: pre (amended)' | Out-Null
FxGit $repoA reflog expire --expire=now --all | Out-Null
FxGit $repoA gc -q --prune=now | Out-Null

# A build: 50 generated files plus the one source file that matters.
for ($i = 0; $i -lt 50; $i++) { Put $repoA ("app\dist\chunk-$i.js") ("x$i") }
Put $repoA 'app\src\Invoice.js' 'invoice'
$null = Commit $repoA 'build: bundle' $now.AddHours(-12)

# Work on a feature branch, never checked out at check time.
FxGit $repoA checkout -q -b feature/x | Out-Null
Put $repoA 'app\src\Feature.js' 'feature'
$null = Commit $repoA 'feat: feature work' $now.AddHours(-11)
FxGit $repoA checkout -q main | Out-Null

# execute.ps1's own branch: belongs to the task whatever the message says.
FxGit $repoA checkout -q -b dailybrief/fx-sub | Out-Null
Put $repoA 'app\src\Other.js' 'other'
$null = Commit $repoA 'chore: misc' $now.AddHours(-10)
FxGit $repoA checkout -q main | Out-Null

# A commit that names the task id in its message.
Put $repoA 'app\src\Thing.js' 'thing'
$null = Commit $repoA 'refactor: cleanup for fx-sub' $now.AddHours(-9)

# ---------- repo B: moved folder (and a look-alike decoy) ----------
$repoB = Join-Path $work 'projB\movedrepo'
New-Item -ItemType Directory -Force $repoB | Out-Null
FxGit $repoB init -q -b main | Out-Null
Put $repoB 'README.md' 'repo B'
$rootB = Commit $repoB 'init B' $now.AddDays(-5)
Put $repoB 'src\Widget.js' 'widget'
$null = Commit $repoB 'feat: implement Widget.js' $now.AddHours(-5)

$decoy = Join-Path $work 'decoy\movedrepo'
New-Item -ItemType Directory -Force $decoy | Out-Null
FxGit $decoy init -q -b main | Out-Null
Put $decoy 'README.md' 'decoy'
$null = Commit $decoy 'init decoy' $now.AddDays(-5)

$oldB = Join-Path $gone 'movedrepo'
Write-Json (Join-Path $data 'scans\fx-moved.json') ([ordered]@{
    taskId = 'fx-moved'; dir = $oldB; isGit = $true; branch = 'main'; head = $rootB
    dirtyCount = 0; dirty = @(); lastCommit = ''; scannedAt = (Fmt $now.AddDays(-5).AddMinutes(1))
    linkedHead = $rootB; linkedAt = (Fmt $now.AddDays(-5).AddMinutes(1))
    rootCommit = $rootB; toplevel = $oldB
})
$oldGone = Join-Path $gone 'nowhere-to-be-found'

# ---------- plain folder (no git): noise filtered before the cap ----------
$plain = Join-Path $work 'plainproj'
Put $plain 'notes\old.md' 'old'
& (Join-Path $core 'scan-folder.ps1') -TaskId 'fx-plain' -Dir $plain
for ($i = 0; $i -lt 40; $i++) { Put $plain ("build\out-$i.js") ("b$i") }
Put $plain 'notes\Plan.md' 'plan'
Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue

# ---------- data folder shaped like the real one ----------
Write-Json (Join-Path $data 'roots.json') @{ roots = @($work) }
Write-Json (Join-Path $data 'projects.json') @{ projects = @(
    [ordered]@{ name = 'work\repoA'; dir = $repoA; isGit = $true; branch = 'main'; stack = @('node'); changed14d = 60
                lastTouched = (Fmt $now); dirtyCount = 0; lastCommits = @('refactor: cleanup for fx-sub'); todoCount = 0; readme = 'repo A' }
) }
function New-Task([string]$id, [string]$title, [string]$dir, [string[]]$subs) {
    return [ordered]@{
        id = $id; title = $title; desc = $title; status = 'important'; done = $false; createdBy = 'user'
        createdAt = '2026-10-20T10:00:00'; updatedAt = '2026-10-20T10:00:00'
        comments = @(); aiNotes = @(); dirs = @($dir)
        subtasks = @($subs | ForEach-Object { [ordered]@{ text = $_; done = $false } })
    }
}
Write-Json (Join-Path $data 'kanban.json') ([ordered]@{
    tasks = @(
        (New-Task 'fx-sub' 'Billing module in app' $appA @('Create app/src/Billing.js module', 'Write the Exporter.md docs')),
        (New-Task 'fx-moved' 'Widget for project B' $oldB @('Implement src/Widget.js', 'Release v2')),
        (New-Task 'fx-gone' 'Task whose folder vanished' $oldGone @('Do the thing')),
        (New-Task 'fx-plain' 'Plain folder plan' $plain @('Write notes/Plan.md'))
    )
    archive = @()
})

# ---------- assertions ----------
$script:fails = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host ('PASS  ' + $name) } else { Write-Host ('FAIL  ' + $name); $script:fails++ }
}
function Run-Check([string]$runId, [switch]$Digest) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $core 'kanban-check.ps1'), '-RunId', $runId)
    if ($Digest) { $a += '-DigestOnly' }
    & powershell.exe @a | Out-Null
    return [string](Get-Content (Join-Path $data "check-run-$runId.log") -Raw -Encoding UTF8)
}
function Task-Of($dg, [string]$id) { return @($dg.tasks | Where-Object { $_.id -eq $id })[0] }
function Has($arr, [string]$needle) { return [bool](@($arr | Where-Object { ([string]$_).Contains($needle) }).Count -gt 0) }

$kHash = (Get-FileHash (Join-Path $data 'kanban.json')).Hash
$log1 = Run-Check 't1' -Digest
$dg = Read-Json (Join-Path $data 'check-digest-t1.json')
$sub = Task-Of $dg 'fx-sub'
Write-Host '--- t1 (digest only)'
Check 'digest-only left kanban.json untouched' ((Get-FileHash (Join-Path $data 'kanban.json')).Hash -eq $kHash)
Check 'orphaned check baseline fell back to --since' ($sub.scanDiff.baseline -eq 'since')
Check 'linked baseline still resolves by sha' ($sub.sinceLinked.baseline -eq 'sha')
Check 'feature-branch commit seen, labelled' (Has $sub.scanDiff.newCommits 'feat: feature work [feature/x]')
Check 'subfolder task does not see root-level commit' (-not ((Read-Json (Join-Path $data 'check-digest-t1.json') | ConvertTo-Json -Depth 10).Contains('root server tweak')))
Check 'real file kept despite 50 dist files' (Has $sub.scanDiff.changedFiles 'src/Invoice.js')
Check 'no dist noise in changedFiles' (-not (Has $sub.scanDiff.changedFiles 'dist/'))
Check 'pre-check-baseline commit not in sinceCheck' (-not (Has $sub.scanDiff.newCommits 'add Billing.js'))
Check 'cumulative mine.commits has Billing.js (before last check)' (Has $sub.mine.commits 'feat: add Billing.js')
Check 'execute branch commit is mine' (Has $sub.mine.commits 'chore: misc')
Check 'commit naming the task id is mine' (Has $sub.mine.commits 'cleanup for fx-sub')
$st1 = @($sub.subtasks | Where-Object { $_.text -like 'Create app/src/Billing.js*' })[0]
$st2 = @($sub.subtasks | Where-Object { $_.text -like 'Write the Exporter*' })[0]
Check 'subtask with matching commit has evidence' (@($st1.evidence).Count -gt 0)
Check 'subtask without matching work has no evidence' (-not $st2.PSObject.Properties['evidence'])
$mv = Task-Of $dg 'fx-moved'
Check 'moved folder would be relinked (log)' ($log1.Contains('would relink fx-moved: ' + $oldB + ' -> ' + $repoB))
Check 'decoy with same name but other root ignored' (-not $log1.Contains($decoy))
Check 'moved task digest uses the new folder' ((@($mv.dirs)[0] -eq $repoB) -and (Has $mv.mine.commits 'implement Widget.js'))
Check 'missing folder flagged' ((Task-Of $dg 'fx-gone').folderMissing -eq $true)
$pl = Task-Of $dg 'fx-plain'
Check 'plain folder: real new file kept, build noise dropped' ((Has $pl.scanDiff.newFiles 'Plan.md') -and -not (Has $pl.scanDiff.newFiles 'build'))
Check 'plain folder: cumulative window counted' ([int]$pl.sinceLinked.fileCount -ge 1)
Check 'missing folder warn line' ($log1.Contains('[warn] linked folder missing for 1 task(s): Task whose folder vanished'))

# ---------- check 2: baseline advances, linked baseline must not ----------
& (Join-Path $core 'scan-folder.ps1') -TaskId 'fx-sub' -Dir $appA
$s2 = Read-Json $scanSubPath
Write-Host '--- rescan'
Check 'rescan keeps linkedHead' ($s2.linkedHead -eq $rootA)
Check 'rescan records rootCommit' ($s2.rootCommit -eq $rootA)
Check 'rescan records toplevel' ($s2.toplevel -ieq $repoA)
Put $repoA 'app\docs\Exporter.md' 'docs'
FxGit $repoA add -A | Out-Null
FxGit $repoA commit -q -m 'docs: Exporter.md' | Out-Null
$null = Run-Check 't2' -Digest
$dg2 = Read-Json (Join-Path $data 'check-digest-t2.json')
$sub2 = Task-Of $dg2 'fx-sub'
Write-Host '--- t2 (digest only, after baseline advance)'
Check 'sha baseline used again' ($sub2.scanDiff.baseline -eq 'sha')
Check 'only the new commit is in sinceCheck' ((@($sub2.scanDiff.newCommits).Count -eq 1) -and (Has $sub2.scanDiff.newCommits 'docs: Exporter.md'))
Check 'old unmerged branch is not "new" again' (-not (Has $sub2.scanDiff.newCommits 'feature work'))
Check 'cumulative evidence survived the advance' (Has $sub2.mine.commits 'feat: add Billing.js')
$st2b = @($sub2.subtasks | Where-Object { $_.text -like 'Write the Exporter*' })[0]
Check 'second subtask now has evidence' (@($st2b.evidence).Count -gt 0)

if ($RunModel) {
    Write-Host '--- t3 (real check: relink + model + apply)'
    $log3 = Run-Check 't3'
    $kb = Read-Json (Join-Path $data 'kanban.json')
    $tm = @($kb.tasks | Where-Object { $_.id -eq 'fx-moved' })[0]
    Check 'relink written to kanban.json' (@($tm.dirs)[0] -eq $repoB)
    Check 'relink aiNote added' (Has @($tm.aiNotes | ForEach-Object { $_.text }) ($oldB + ' -> ' + $repoB))
    Check 'scan file follows the relink, baselines kept' (((Read-Json (Join-Path $data 'scans\fx-moved.json')).dir -eq $repoB) -and ((Read-Json (Join-Path $data 'scans\fx-moved.json')).linkedHead -eq $rootB))
    Check 'warn line for the missing folder' ($log3.Contains('[warn] linked folder missing for 1 task(s)'))
    Check 'no model answer rejected' (-not $log3.Contains('rejected after retry'))
    $ticks = @(($log3 -split "`n") | Where-Object { $_ -match 'subtask ticked|refused subtask tick' })
    Write-Host ('      subtask log: ' + ($(if ($ticks.Count) { ($ticks | ForEach-Object { $_.Trim() }) -join ' | ' } else { '(model ticked nothing)' })))
    $allSubs = @($kb.tasks | ForEach-Object { $tk = $_; @($tk.subtasks) | Where-Object { $_.done } | ForEach-Object { $tk.id + ': ' + $_.text } })
    Write-Host ('      ticked on board: ' + ($(if ($allSubs.Count) { $allSubs -join ' | ' } else { '(none)' })))
    Check 'nothing without evidence was ticked' (-not (Has $allSubs 'Release v2') -and -not (Has $allSubs 'Do the thing'))
    $tg = @($kb.tasks | Where-Object { $_.id -eq 'fx-gone' })[0]
    Write-Host ('      fx-gone notes: ' + (@($tg.aiNotes | ForEach-Object { $_.text }) -join ' | '))
    $sg = Join-Path $data 'scans\fx-gone.json'
    if (@($tg.aiNotes).Count -gt 0) { Check 'missing folder marked as told' ((Test-Path $sg) -and ((Read-Json $sg).missingNoted -eq $oldGone)) }
}

Write-Host ''
Write-Host ('fixture: ' + $Root)
if ($script:fails -gt 0) { Write-Host ("$script:fails assertion(s) FAILED"); exit 1 }
Write-Host 'all assertions passed'

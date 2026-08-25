# Where the app's own files live, and where THIS user's data lives.
#
#   $app  - scripts, prompts, strings. Ships with the install, read-only,
#           shared by every user on the machine.
#   $base - db, kanban, briefs, digests, logs. One folder per user, never
#           shared between installs.
#
# The Electron shell sets DAILYBRIEF_DATA before spawning any of these
# scripts. Running a script by hand without it keeps the old behaviour:
# data sits next to the scripts, which is what a checked-out repo wants.
# ASCII-only on purpose (PS 5.1 encoding).

$app = $PSScriptRoot
$base = if ($env:DAILYBRIEF_DATA) { $env:DAILYBRIEF_DATA } else { $PSScriptRoot }
if (-not (Test-Path $base)) { New-Item -ItemType Directory -Force $base | Out-Null }

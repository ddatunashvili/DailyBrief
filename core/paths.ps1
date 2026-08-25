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


# A model that answers with its JSON in a fenced block instead of writing the
# file it was told to write costs a whole run for nothing: the tokens are spent
# and the script applies nothing. The answer is right there in the run's own
# log, so take it from there. Returns $true when a usable file was written.
function Recover-JsonFromLog([string]$LogPath, [string]$OutPath, [string[]]$RequireProps) {
    if (-not (Test-Path $LogPath)) { return $false }
    try {
        # The log holds the CLI's own JSON line, and callers append plain text
        # to it, so parse line by line rather than the whole file.
        $res = ''
        foreach ($line in @(Get-Content $LogPath -Encoding UTF8)) {
            $l = ([string]$line).TrimStart([char]0xFEFF).Trim()
            if (-not $l.StartsWith('{')) { continue }
            try { $o = $l | ConvertFrom-Json } catch { continue }
            if ($o.PSObject.Properties['result']) { $res = [string]$o.result; break }
        }
        if (-not $res) { return $false }
        $cand = ''
        if ($res -match '(?s)```(?:json)?\s*(\{.*?\})\s*```') { $cand = $Matches[1] }
        elseif ($res -match '(?s)(\{.*\})') { $cand = $Matches[1] }
        if (-not $cand) { return $false }
        $parsed = $cand | ConvertFrom-Json          # only a parsable answer counts
        if ($RequireProps -and $RequireProps.Count -gt 0) {
            $ok = $false
            foreach ($rp in $RequireProps) { if ($parsed.PSObject.Properties[$rp]) { $ok = $true } }
            if (-not $ok) { return $false }
        }
        $u8 = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText($OutPath, $cand, $u8)
        return $true
    } catch {
        return $false
    }
}

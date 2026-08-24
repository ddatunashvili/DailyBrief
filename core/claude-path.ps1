# Resolves $claude to a claude launcher whose native binary is actually there.
#
# Two shapes exist on this machine over time:
#   - npm global install: claude.cmd + node_modules\@anthropic-ai\claude-code\bin\claude.exe
#   - native install:     %USERPROFILE%\.local\bin\claude.exe (a few hundred MB, no .cmd)
# A global npm install can leave claude.cmd in place while the platform-native
# optional dependency is missing; bin\claude.exe is then a tiny text stub and
# Windows rejects it with "This version of ... is not compatible with the
# version of Windows you're running" - every AI run dies in ~2s with no output.
# So a candidate is accepted only when the binary it launches is real (>1 MB),
# and the native install is checked too: only looking for claude.cmd is what
# made every run fail after the CLI was reinstalled natively.

function Test-RealBinary([string]$exe) {
    if (-not $exe) { return $false }
    if (-not (Test-Path $exe)) { return $false }
    # Real binary is hundreds of MB; the "not installed" stub is under 1 KB.
    return ((Get-Item $exe).Length -gt 1MB)
}

function Resolve-ClaudeCmd {
    $candidates = New-Object System.Collections.Generic.List[string]

    # Whatever is on PATH first (either shape), then the known install roots.
    foreach ($name in @('claude.cmd', 'claude.exe', 'claude')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $candidates.Add([string]$cmd.Source) }
    }
    $candidates.Add((Join-Path $env:USERPROFILE '.local\bin\claude.exe'))
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe'))
    $candidates.Add('C:\Users\davit\.nvm\versions\node\v22.22.2\bin\claude.cmd')
    $candidates.Add('C:\Users\davit\AppData\Roaming\nvm\v22.22.3\claude.cmd')
    $candidates.Add((Join-Path $env:APPDATA 'npm\claude.cmd'))

    # Any nvm/npm root that happens to hold an install, so a node version bump
    # does not silently take the whole app's AI down again.
    foreach ($root in @((Join-Path $env:USERPROFILE '.nvm\versions\node'), (Join-Path $env:APPDATA 'nvm'))) {
        if (-not (Test-Path $root)) { continue }
        foreach ($d in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
            $candidates.Add((Join-Path $d.FullName 'bin\claude.cmd'))
            $candidates.Add((Join-Path $d.FullName 'claude.cmd'))
        }
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (-not (Test-Path $c)) { continue }
        if ($c -like '*.exe') {
            if (Test-RealBinary $c) { return $c }
            continue
        }
        # A .cmd is only a launcher: check the binary it actually starts.
        $exe = Join-Path (Split-Path $c) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
        if (Test-RealBinary $exe) { return $c }
    }
    throw "No working claude CLI found (checked PATH, ~\.local\bin and every nvm/npm root). Reinstall it: npm install -g @anthropic-ai/claude-code"
}

$claude = Resolve-ClaudeCmd

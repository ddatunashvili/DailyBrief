# Resolves $claude to a claude.cmd whose native binary is actually installed.
#
# A global npm install can leave claude.cmd in place while the platform-native
# optional dependency is missing; bin\claude.exe is then a tiny text stub and
# Windows rejects it with "This version of ... is not compatible with the
# version of Windows you're running" - every AI run dies in ~2s with no output.
# So each candidate is checked by the size of the exe it launches, not by
# Test-Path on the .cmd.

function Resolve-ClaudeCmd {
    $candidates = @(
        'C:\Users\davit\.nvm\versions\node\v22.22.2\bin\claude.cmd',
        'C:\Users\davit\AppData\Roaming\nvm\v22.22.3\claude.cmd'
    )
    $cmd = Get-Command claude.cmd -ErrorAction SilentlyContinue
    if ($cmd) { $candidates = @($cmd.Source) + $candidates }

    foreach ($c in $candidates) {
        if (-not (Test-Path $c)) { continue }
        $exe = Join-Path (Split-Path $c) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
        if (-not (Test-Path $exe)) { continue }
        # Real binary is hundreds of MB; the "not installed" stub is under 1 KB.
        if ((Get-Item $exe).Length -gt 1MB) { return $c }
    }
    throw "No working claude CLI found. The native binary is missing - reinstall with: npm install -g @anthropic-ai/claude-code"
}

$claude = Resolve-ClaudeCmd

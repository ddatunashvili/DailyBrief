# Lean headless claude call shared by every pipeline script.
#
# A plain `claude -p` is a full Claude Code session: the CLI system prompt,
# every tool schema, every MCP server and skill from the user's own
# ~/.claude config, their CLAUDE.md and their SessionStart hooks. That was
# ~30k tokens per turn before the digest, and a user's personal hooks (e.g. a
# "talk tersely" style hook) leaked into the briefing's prose. Here:
#   --setting-sources ""            no user/project settings -> no hooks, no plugins
#   --strict-mcp-config + empty cfg no MCP servers
#   --system-prompt                 replaces the CLI system prompt
#   --tools ""                      no tools unless the caller needs them
#   --json-schema                   structured output, validated by the CLI
# Measured: ~1.2k baseline tokens instead of ~30k, one model turn.
# Not --bare: it only accepts ANTHROPIC_API_KEY and would break subscription auth.
#
# Dot-source after claude-path.ps1 (needs $claude).

function Get-ClaudeExe {
    # PS 5.1 hands native args to a .cmd through cmd.exe, which re-parses the
    # escaped quotes inside --json-schema. The real exe behind it does not.
    if ($claude -like '*.cmd') {
        $exe = Join-Path (Split-Path $claude) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $claude
}

function Get-EmptyMcpConfig {
    $p = Join-Path $env:TEMP 'dailybrief-empty-mcp.json'
    if (-not (Test-Path $p)) {
        [IO.File]::WriteAllText($p, '{"mcpServers":{}}', (New-Object Text.UTF8Encoding($false)))
    }
    return $p
}

# PS 5.1 passes native args without escaping embedded double quotes.
function ConvertTo-NativeArg([string]$s) { return ($s -replace '"', '\"') }

# Pulls the first JSON object/array out of free text (```json fences, prose around it).
function ConvertFrom-ModelJson([string]$text) {
    if (-not $text) { return $null }
    $t = $text.Trim()
    $t = $t -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
    try { return ($t | ConvertFrom-Json) } catch { }
    $start = $t.IndexOfAny([char[]]'{[')
    $end = [Math]::Max($t.LastIndexOf('}'), $t.LastIndexOf(']'))
    if ($start -ge 0 -and $end -gt $start) {
        try { return ($t.Substring($start, $end - $start + 1) | ConvertFrom-Json) } catch { }
    }
    return $null
}

# Returns @{ ok; data; error; envelope }. `data` is the structured output
# (or the JSON parsed out of the result text when no schema was given).
# The raw CLI envelope is appended to $Log: main.js reads usage/cost from it.
function Invoke-ClaudeLean {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Log,
        [string]$System = 'You are a precise assistant inside a desktop app pipeline. Answer only with the requested JSON.',
        [string]$Model = 'haiku',
        [string]$Effort = '',
        [string]$Schema = '',
        [string]$Tools = '',
        [string[]]$AddDir = @(),
        [int]$MaxTurns = 3,
        # Keeps the account's claude.ai connectors (e.g. Claude Docs): they
        # arrive through default MCP loading, which --strict-mcp-config with
        # an empty config switches off. Hooks/plugins stay off either way
        # (connectors still load with --setting-sources ""). With it, -Tools
        # names the connector tools to allow; the only built-in is ToolSearch.
        # Measured: ~7.8k baseline tokens with this account's connectors.
        [switch]$ClaudeAiConnectors
    )
    $exe = Get-ClaudeExe
    $a = @(
        '-p',
        '--model', $Model,
        '--setting-sources', '""'
    )
    if (-not $ClaudeAiConnectors) {
        $a += @('--strict-mcp-config', '--mcp-config', (Get-EmptyMcpConfig))
    }
    $a += @(
        '--disable-slash-commands',
        '--no-session-persistence',
        '--system-prompt', (ConvertTo-NativeArg $System),
        '--max-turns', [string]$MaxTurns,
        '--output-format', 'json'
    )
    if ($ClaudeAiConnectors) {
        # --tools "" would hide the connector tools too, and the CLI defers
        # most connector tools behind ToolSearch, so that one built-in stays.
        # Connector tools are pre-approved by name through --allowedTools;
        # nothing else gets permission, and there is no permission bypass.
        $a += @('--tools', 'ToolSearch')
        if ($Tools) { $a += @('--allowedTools', ('ToolSearch,' + $Tools)) }
    } elseif ($Tools) {
        $a += @('--tools', $Tools, '--allowedTools', $Tools,
                '--allow-dangerously-skip-permissions', '--dangerously-skip-permissions')
    } else {
        $a += @('--tools', '""')
    }
    if ($Effort) { $a += @('--effort', $Effort) }
    if ($Schema) { $a += @('--json-schema', (ConvertTo-NativeArg $Schema)) }
    foreach ($d in $AddDir) { $a += @('--add-dir', $d) }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = $Prompt | & $exe @a 2>&1 | ForEach-Object { [string]$_ }
    $ErrorActionPreference = $prev
    $rawText = ($raw -join "`n")
    Add-Content -Path $Log -Value $rawText -Encoding UTF8

    $resp = ConvertFrom-ModelJson $rawText
    if (-not $resp) { return @{ ok = $false; data = $null; error = 'claude CLI returned no JSON envelope'; envelope = $null } }
    if ($resp.is_error) { return @{ ok = $false; data = $null; error = ('claude CLI error: ' + $resp.subtype + " " + $resp.result); envelope = $resp } }
    $data = $resp.structured_output
    if (-not $data) { $data = ConvertFrom-ModelJson ([string]$resp.result) }
    if (-not $data) { return @{ ok = $false; data = $null; error = 'model answer was not JSON'; envelope = $resp } }
    return @{ ok = $true; data = $data; error = $null; envelope = $resp }
}

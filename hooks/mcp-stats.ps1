# MCP Usage Stats Hook — PostToolUse
# Logs every tool call to orch-mcp-stats.jsonl for analysis
# Input: JSON via stdin { tool_name, tool_input, tool_response, session_id }

param()

$ErrorActionPreference = 'SilentlyContinue'

$statsFile = "$env:USERPROFILE\.claude\orch-mcp-stats.jsonl"

# Rotate if > 10MB
if (Test-Path $statsFile) {
    $size = (Get-Item $statsFile).Length
    if ($size -gt 10MB) {
        Move-Item $statsFile "$statsFile.old" -Force
    }
}

try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $input_data = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($input_data)) { exit 0 }

    $event = $input_data | ConvertFrom-Json -ErrorAction Stop

    $toolName = $event.tool_name
    if ([string]::IsNullOrWhiteSpace($toolName)) { exit 0 }

    $isMcp = $toolName -like "mcp__*"
    $isNative = $toolName -in @("Bash","Grep","Glob","Read","Write","Edit","WebFetch","WebSearch","Task")

    # Categorize native tools that might replace MCP
    $category = if ($isMcp) {
        "mcp"
    } elseif ($toolName -eq "Bash") {
        "bash"
    } elseif ($toolName -in @("Grep","Glob")) {
        "search"
    } else {
        "other"
    }

    $entry = [ordered]@{
        ts         = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        tool       = $toolName
        category   = $category
        session    = $event.session_id
    }

    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $statsFile -Encoding UTF8

    # Write verified MCP servers file for statusline
    if ($isMcp) {
        $serverName = ($toolName -split '__')[1]
        if ($serverName) {
            $verifiedFile = "$env:TEMP\orch-mcp-verified.json"
            $verified = @{}
            if (Test-Path $verifiedFile) {
                try {
                        $obj = Get-Content $verifiedFile -Raw | ConvertFrom-Json
                        $verified = @{}
                        $obj.PSObject.Properties | ForEach-Object { $verified[$_.Name] = $_.Value }
                    } catch { $verified = @{} }
            }
            $verified[$serverName] = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            ($verified | ConvertTo-Json -Compress) | Set-Content $verifiedFile -Force
        }
    }

} catch {
    # Never fail — hook must not block AI
    exit 0
}

exit 0

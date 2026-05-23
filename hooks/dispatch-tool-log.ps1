# Dispatch Tool Log Hook — PostToolUse + PostToolUseFailure (async)
# Appends JSONL entry to $env:ORCH_DISPATCH_LOG if set.
# Zero cost for non-dispatch sessions (env var not set → exit 0 immediately).

param()

$ErrorActionPreference = 'SilentlyContinue'

if (-not $env:ORCH_DISPATCH_LOG) { exit 0 }

try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop

    $toolName = $event.tool_name
    if ([string]::IsNullOrWhiteSpace($toolName)) { exit 0 }

    # Determine status
    $status = "ok"
    $errorMsg = $null
    if ($event.error -or ($event.tool_response -and $event.tool_response.is_error)) {
        $status = "error"
        $errorMsg = if ($event.error) { "$($event.error)" } else { "tool error" }
    }

    # Extract meaningful detail based on tool type
    $detail = $toolName
    switch -Regex ($toolName) {
        "^Bash$" {
            $cmd = $event.tool_input.command
            if ($cmd) {
                $cmd = ($cmd -replace '\s+', ' ').Trim()
                $detail = if ($cmd.Length -gt 150) { $cmd.Substring(0, 150) + "..." } else { $cmd }
            }
        }
        "^(Edit|Write|Read)$" {
            $fp = $event.tool_input.file_path
            if ($fp) { $detail = $fp }
        }
        "^mcp__" {
            # Extract server name from tool_name (mcp__<server>__<method>)
            $parts = $toolName -split "__"
            $server = if ($parts.Count -ge 2) { $parts[1] } else { $toolName }
            # Find first meaningful arg value
            $firstArg = $null
            if ($event.tool_input) {
                $props = $event.tool_input.PSObject.Properties
                foreach ($p in $props) {
                    if ($p.Value -and "$($p.Value)".Length -gt 0) {
                        $firstArg = "$($p.Name)=$($p.Value)"
                        if ("$($p.Value)".Length -gt 80) { $firstArg = "$($p.Name)=" + "$($p.Value)".Substring(0, 80) + "..." }
                        break
                    }
                }
            }
            $detail = if ($firstArg) { "$server | $firstArg" } else { $server }
        }
        "^(Grep|Glob)$" {
            $pat = $event.tool_input.pattern
            if ($pat) { $detail = $pat }
        }
        "^Agent$" {
            $desc = $event.tool_input.description
            if ($desc) {
                $detail = if ($desc.Length -gt 150) { $desc.Substring(0, 150) + "..." } else { $desc }
            }
        }
    }

    $entry = [ordered]@{
        ts      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        tool    = $toolName
        status  = $status
        detail  = $detail
        session = $event.session_id
    }
    if ($errorMsg) { $entry["error"] = $errorMsg }

    # Ensure log directory exists
    $logDir = Split-Path $env:ORCH_DISPATCH_LOG -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $env:ORCH_DISPATCH_LOG -Encoding UTF8

} catch {
    exit 0
}

exit 0

# Subagent Stop Verify Hook — SubagentStop
# Records agent result summary to RLM for cross-session visibility.

param()

$ErrorActionPreference = 'SilentlyContinue'

. "$PSScriptRoot\lib\rlm-client.ps1"

try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop

    $agentType  = $event.agent_type
    $agentId    = $event.agent_id
    $cwd        = $event.cwd
    $lastMsg    = $event.last_assistant_message

    $projectName = "unknown"
    if ($cwd) { $projectName = Split-Path $cwd -Leaf }

    $truncated = if ($lastMsg -and $lastMsg.Length -gt 500) {
        $lastMsg.Substring(0, 500) + "..."
    } elseif ($lastMsg) {
        $lastMsg
    } else {
        "(no message)"
    }

    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $factContent = "SUBAGENT-RESULT [project: $projectName] $ts agent_type=$agentType agent_id=$agentId. Summary: $truncated"

    Invoke-RLM "rlm_start_session" @{ restore = $true } | Out-Null
    Start-Sleep -Milliseconds 300
    Invoke-RLM "rlm_add_hierarchical_fact" @{
        content  = $factContent
        domain   = "workflow"
        level    = 1
        ttl_days = 14
    } | Out-Null

    "$ts | $projectName | $agentType | $agentId | msglen:$($lastMsg.Length)" |
        Add-Content "$env:TEMP\orch-subagent-stop.log" -Encoding UTF8

} catch {
    "$((Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')) | ERROR: $_" |
        Add-Content "$env:TEMP\orch-subagent-stop.log" -Encoding UTF8
}

exit 0

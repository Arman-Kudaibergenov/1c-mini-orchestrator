# Post-Compact Restore Hook — SessionStart (matcher: compact)
# Fires AFTER auto-compact or manual /compact. stdout is injected into Claude's context.
# Reads latest PENDING tasks and pre-compact facts from RLM -> outputs restoration context.

param()

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. "$PSScriptRoot/lib/rlm-client.ps1"

function Test-OtherProject {
    param([string]$Content, [string]$CurrentProject)
    if ($Content -match '\[project:\s*([\w][\w-]*)\]') {
        return $Matches[1] -ne $CurrentProject
    }
    return $false
}

try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop

    $projectName = "unknown"
    if ($event.cwd) { $projectName = Split-Path $event.cwd -Leaf }

    # 1. Start RLM session
    Invoke-RLM -ToolName "rlm_start_session" -Arguments @{ restore = $true } | Out-Null
    Start-Sleep -Milliseconds 300

    # 2. Search PENDING tasks
    $pendingRaw = Invoke-RLM-Read -ToolName "rlm_search_facts" -Arguments @{
        query            = "PENDING tasks next session"
        keyword_weight   = 0.8
        semantic_weight  = 0.1
        recency_weight   = 0.1
        top_k            = 5
    }

    $pendingTasks = @()
    if ($pendingRaw) {
        try {
            $pendingJson = $pendingRaw | ConvertFrom-Json
            foreach ($fact in $pendingJson.results) {
                $c = $fact.content
                # Skip other projects and empty "none" facts
                if (Test-OtherProject $c $projectName) { continue }
                if ($c -match '^\s*PENDING tasks next session:\s*none\.?\s*$') { continue }
                if ($c -match 'PENDING tasks next session: none\.') { continue }
                $pendingTasks += $c
            }
        } catch {}
    }

    # 3. Search pre-compact auto-save for THIS project
    $preCompactRaw = Invoke-RLM-Read -ToolName "rlm_search_facts" -Arguments @{
        query            = "PRE-COMPACT auto-save project $projectName"
        keyword_weight   = 0.6
        semantic_weight  = 0.1
        recency_weight   = 0.3
        top_k            = 3
    }

    $preCompactInfo = ""
    if ($preCompactRaw) {
        try {
            $pcJson = $preCompactRaw | ConvertFrom-Json
            foreach ($fact in $pcJson.results) {
                $c = $fact.content
                # Only show facts for current project
                if ($c -match "PRE-COMPACT" -and $c -match $projectName) {
                    $preCompactInfo = $c
                    break
                }
            }
        } catch {}
    }

    # 4. Build restoration context
    $output = @()
    $output += "CONTEXT RESTORED after compaction (project: $projectName)."

    if ($preCompactInfo) {
        $output += ""
        $output += "Session state saved before compact:"
        $output += $preCompactInfo
    }

    if ($pendingTasks.Count -gt 0) {
        $output += ""
        $output += "PENDING tasks for this project:"
        foreach ($t in $pendingTasks) {
            $output += "- $t"
        }
    }

    $output += ""
    $output += "To restore full context, ask user to say 'kontekst' or call rlm_route_context."

    Write-Output ($output -join "`n")

} catch {
    Write-Output "Context was compacted. Ask user to say kontekst to restore session state from RLM."
}

exit 0

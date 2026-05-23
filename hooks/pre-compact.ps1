# Pre-Compact Hook
# Fires BEFORE Claude Code auto-compacts. PreCompact stdout is NOT injected
# into Claude's context — so this hook saves state directly to RLM via HTTP.
# Also reads autocapture buffer for file/command history.

param()

$ErrorActionPreference = 'SilentlyContinue'

. "$PSScriptRoot/lib/rlm-client.ps1"

try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop

    $trigger   = $event.trigger          # "auto" or "manual"
    $sessionId = $event.session_id
    $ts        = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

    # Project name from cwd
    $projectName = "unknown"
    if ($event.cwd) { $projectName = Split-Path $event.cwd -Leaf }

    # ── 1. Read autocapture buffer (reliable source) ──
    $filesEdited = [System.Collections.Generic.HashSet[string]]::new()
    $commandsRun = @()

    $bufferFile = "$env:USERPROFILE\.claude\orch-autocapture-buffer.jsonl"
    if (Test-Path $bufferFile) {
        foreach ($line in (Get-Content $bufferFile -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.file)               { $null = $filesEdited.Add($entry.file) }
                if ($entry.cmd)                { $commandsRun += $entry.cmd }
            } catch { continue }
        }
    }

    # ── 2. Best-effort: extract last user messages from transcript ──
    $userMessages = @()
    $transcriptPath = $event.transcript_path
    if ($transcriptPath -and (Test-Path $transcriptPath)) {
        # Read last 200 lines (enough for recent context, avoids OOM on huge transcripts)
        $tailLines = Get-Content $transcriptPath -Tail 200 -Encoding UTF8 -ErrorAction Stop
        foreach ($line in $tailLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json -ErrorAction Stop

                # Extract user messages (format varies: type=human or role=user)
                $isUser = ($entry.type -eq "human") -or ($entry.role -eq "user")
                if ($isUser) {
                    $text = ""
                    if ($entry.content -is [string]) {
                        $text = $entry.content
                    }
                    elseif ($entry.message.content -is [array]) {
                        foreach ($block in $entry.message.content) {
                            if ($block.type -eq "text" -and $block.text) {
                                $text = $block.text; break
                            }
                        }
                    }
                    elseif ($entry.content -is [array]) {
                        foreach ($block in $entry.content) {
                            if ($block.type -eq "text" -and $block.text) {
                                $text = $block.text; break
                            }
                        }
                    }
                    if ($text.Length -gt 150) { $text = $text.Substring(0, 150) + "..." }
                    if ($text) { $userMessages += $text }
                }

                # Also extract edited files from tool calls in transcript
                if ($entry.type -eq "tool_use" -or $entry.name) {
                    $tn = if ($entry.name) { $entry.name } elseif ($entry.tool_name) { $entry.tool_name } else { "" }
                    if ($tn -in @("Edit","Write") -and $entry.input.file_path) {
                        $null = $filesEdited.Add($entry.input.file_path)
                    }
                }
            } catch { continue }
        }
    }

    # ── 3. Build RLM fact ──
    $lastMsgs = if ($userMessages.Count -gt 0) {
        ($userMessages | Select-Object -Last 3) -join " | "
    } else { "(no user messages captured)" }

    $filesList = if ($filesEdited.Count -gt 0) {
        ($filesEdited | Select-Object -First 20) -join ", "
    } else { "none" }

    $cmdsList = if ($commandsRun.Count -gt 0) {
        $commandsRun | Select-Object -Last 5 | ForEach-Object {
            if ($_.Length -gt 80) { $_.Substring(0, 80) + "..." } else { $_ }
        }
        ($commandsRun | Select-Object -Last 5) -join "; "
    } else { "none" }

    $factContent = "PRE-COMPACT auto-save [project: $projectName] $ts (trigger: $trigger). " +
        "Recent user context: $lastMsgs. " +
        "Files modified ($($filesEdited.Count)): $filesList. " +
        "Notable commands: $cmdsList."

    # ── 4. Save to RLM ──
    Invoke-RLM -ToolName "rlm_start_session" -Arguments @{ restore = $true } | Out-Null
    Start-Sleep -Milliseconds 500

    $saved = Invoke-RLM -ToolName "rlm_add_hierarchical_fact" -Arguments @{
        content = $factContent
        domain  = "workflow"
        level   = 1
    }

    # ── 4b. Query RLM for latest PENDING tasks (fallback preservation) ──
    try {
        $latestPending = Invoke-RLM-Read -ToolName "rlm_search_facts" -Arguments @{
            query = "PENDING tasks next session [project: $projectName]"
            keyword_weight = 0.8
            semantic_weight = 0.1
            recency_weight = 0.1
            top_k = 3
        }
        if ($latestPending) {
            $pendingSnippet = if ($latestPending.Length -gt 500) { $latestPending.Substring(0, 500) + "..." } else { $latestPending }
            # Save as separate fact to preserve PENDING through compact
            Invoke-RLM -ToolName "rlm_add_hierarchical_fact" -Arguments @{
                content  = "PRE-COMPACT PENDING preservation [project: $projectName] $ts. Last known: $pendingSnippet"
                domain   = "workflow"
                level    = 1
                ttl_days = 7
            } | Out-Null
        }
    } catch {
        # Silent - don't break pre-compact for PENDING query failure
    }

    # ── 5. Log locally ──
    $logFile = "$env:TEMP\orch-precompact.log"
    "$ts | $trigger | $projectName | files:$($filesEdited.Count) | cmds:$($commandsRun.Count) | rlm:$saved" |
        Add-Content $logFile -Encoding UTF8

} catch {
    "$((Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')) | ERROR: $_" |
        Add-Content "$env:TEMP\orch-precompact-error.log" -Encoding UTF8
}

exit 0

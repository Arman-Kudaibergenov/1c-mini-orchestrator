# Session Start Restore Hook -- SessionStart (matchers: startup, resume, clear)
# Fires on new session start. stdout is injected into Claude context.
# Three paths:
#   1. RELAY: relay-pending.json exists → restore dispatched session context
#   2. CLEAR/RESUME: no relay, trigger=clear|resume → query RLM for last session
#   3. STARTUP: fresh session → exit silently

param()

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$logPath   = Join-Path $env:TEMP 'orch-relay.log'
$relayPath = Join-Path $env:TEMP 'orch-dispatch/relay-pending.json'

function Write-RelayLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts $Message" | Out-File -FilePath $logPath -Append -Encoding UTF8 -ErrorAction SilentlyContinue
}

try {
    # RLM tunnel is now ensured by ~/.bashrc (runs before claude starts)
    # No need to check here — it would be too late anyway (MCP connects before hooks)

    # Load rlm-client from lib
    $libPath = Join-Path $PSScriptRoot 'lib/rlm-client.ps1'
    if (Test-Path $libPath) { . $libPath }

    # Load session status journal
    $statusLib = Join-Path $PSScriptRoot 'lib/session-status.ps1'
    if (Test-Path $statusLib) { . $statusLib }

    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()

    # DEBUG: log raw stdin
    $rawSnippet = if ($inputData.Length -gt 500) { $inputData.Substring(0,500) + '...' } else { $inputData }
    Write-RelayLog "RAW STDIN ($($inputData.Length) bytes): $rawSnippet"

    $event = $null
    if (-not [string]::IsNullOrWhiteSpace($inputData)) {
        try { $event = ConvertFrom-Json -InputObject $inputData -ErrorAction Stop } catch {
            Write-RelayLog "JSON PARSE ERROR: $_"
        }
    }

    # compact trigger -- handled by post-compact-restore.ps1
    # NOTE: Claude Code CLI sends "source" field, not "trigger" (confirmed 2026-04-01)
    if ($event -and ($event.trigger -eq 'compact' -or $event.source -eq 'compact')) { exit 0 }

    # Determine trigger type -- check both "source" (actual CLI field) and "trigger" (legacy)
    $trigger = ''
    if ($event -and $event.source) { $trigger = $event.source }
    elseif ($event -and $event.trigger) { $trigger = $event.trigger }

    Write-RelayLog "Hook fired: trigger=$trigger cwd=$(if($event -and $event.cwd){$event.cwd}else{'(none)'})"

    # ── Session status journal — initial entry for THIS session ──
    # Goal/parent will be filled in below if this is a relay restore.
    $sid = if ($event -and $event.session_id) { $event.session_id } else { '' }
    $proj = 'unknown'
    $projPath = ''
    if ($event -and $event.cwd) {
        $proj = Split-Path $event.cwd -Leaf
        $projPath = $event.cwd
    }
    if ($sid -and (Get-Command New-SessionStatus -ErrorAction SilentlyContinue)) {
        New-SessionStatus -SessionId $sid -Project $proj -ProjectPath $projPath -Trigger $(if($trigger){$trigger}else{'startup'})
    }

    # -- PATH 1: RELAY - automated session rotation --
    if (Test-Path $relayPath) {
        # Parse JSON
        $relay = $null
        try {
            $rawJson = [System.IO.File]::ReadAllText($relayPath, [System.Text.Encoding]::UTF8)
            $relay = $rawJson | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-RelayLog "CORRUPT relay-pending.json: $_"
            Remove-Item $relayPath -Force -ErrorAction SilentlyContinue
            exit 0
        }

        # Required fields. Accept either new (parent_session_id) or legacy (task_id)
        # naming for backwards compatibility with old relay files.
        $parentSid = if ($relay.parent_session_id) { $relay.parent_session_id } else { $relay.task_id }
        if ([string]::IsNullOrWhiteSpace($parentSid) -or
            [string]::IsNullOrWhiteSpace($relay.project) -or
            [string]::IsNullOrWhiteSpace($relay.project_path) -or
            [string]::IsNullOrWhiteSpace($relay.created_at)) {
            Write-RelayLog 'MISSING required fields in relay-pending.json'
            Remove-Item $relayPath -Force -ErrorAction SilentlyContinue
            exit 0
        }

        # TTL (1 hour)
        try {
            $createdAt = [datetime]::Parse($relay.created_at)
            $age = (Get-Date) - $createdAt
            if ($age.TotalHours -gt 1) {
                Write-RelayLog "STALE relay-pending.json (age: $([int]$age.TotalMinutes) min) -- deleted"
                Remove-Item $relayPath -Force -ErrorAction SilentlyContinue
                exit 0
            }
        } catch {
            Write-RelayLog "INVALID created_at in relay-pending.json: $_"
            Remove-Item $relayPath -Force -ErrorAction SilentlyContinue
            exit 0
        }

        # Project path match — normalize slashes (Windows cwd uses `\`, relay
        # files written by bash/git tooling may use `/`). Without this, a relay
        # written as `C:/Users/...` against an event cwd of `C:\Users\...`
        # silently fails the equality check and the hook exits without injecting.
        $eventCwd = ''
        if ($event -and $event.cwd) {
            $eventCwd = $event.cwd.TrimEnd('\').TrimEnd('/').Replace('/', '\')
        }
        $relayProjPath = $relay.project_path.TrimEnd('\').TrimEnd('/').Replace('/', '\')

        if ($eventCwd -and ($eventCwd.ToLower() -ne $relayProjPath.ToLower())) {
            Write-RelayLog "PATH MISMATCH: event.cwd='$eventCwd' relay.project_path='$relayProjPath' -- exiting without consuming relay"
            exit 0
        }

        # Read relay data
        $taskId   = $parentSid
        $project  = $relay.project
        $reason   = if ($relay.reason)       { $relay.reason }       else { 'unknown' }
        $hint     = if ($relay.hint)         { $relay.hint }         else { '' }
        $handoffFile = if ($relay.handoff_file) { $relay.handoff_file } else { '' }

        # ── Update this session's status with parent linkage + goal ──
        # relay.task_id is the parent session_id (see context-monitor.ps1).
        if ($sid -and (Get-Command New-SessionStatus -ErrorAction SilentlyContinue)) {
            $goalText = if ($hint) { $hint } else { "relay restore (reason: $reason)" }
            New-SessionStatus -SessionId $sid -Project $project -ProjectPath $relay.project_path `
                -ParentSessionId $taskId -Goal $goalText -InboundReason $reason -Trigger 'rotate'
            if ($taskId -and (Get-Command Add-SessionChild -ErrorAction SilentlyContinue)) {
                Add-SessionChild -ParentSessionId $taskId -ChildSessionId $sid
            }
        }

        # ── NEW PATH: handoff_file is the authoritative source ──
        # If the relay points to a structured handoff file (state-machine
        # flow from context-monitor.ps1), read it directly. RLM is best-effort
        # archival, not the source of truth — this dodges RLM unavailability
        # entirely.
        $handoffContent = ''
        if ($handoffFile -and (Test-Path $handoffFile)) {
            try {
                $handoffContent = [System.IO.File]::ReadAllText($handoffFile, [System.Text.Encoding]::UTF8)
            } catch {
                Write-RelayLog "FAILED to read handoff_file '$handoffFile': $_"
            }
        }

        # Legacy PENDING fallback (only when handoff_file absent or unreadable)
        $pendingContent = ''
        $rlmWorked = $false
        $rlmAvailable = $null -ne (Get-Command Invoke-RLM-Read -ErrorAction SilentlyContinue)

        if (-not $handoffContent -and $rlmAvailable) {
            try {
                Invoke-RLM -ToolName 'rlm_start_session' -Arguments @{ restore = $true } | Out-Null
                Start-Sleep -Milliseconds 300

                $pendingRaw = Invoke-RLM-Read -ToolName 'rlm_search_facts' -Arguments @{
                    query           = "PENDING tasks next session [project: $project]"
                    keyword_weight  = 0.2
                    semantic_weight = 0.3
                    recency_weight  = 0.5
                    top_k           = 3
                }

                if ($pendingRaw) {
                    $pendingJson = $pendingRaw | ConvertFrom-Json
                    foreach ($fact in $pendingJson.results) {
                        $c = $fact.content
                        if ($c -match '\[project:\s*([\w][\w-]*)\]' -and $Matches[1] -ne $project) { continue }
                        if ($c -match 'SESSION-END') { continue }
                        if ($c -match '^\s*PENDING tasks next session:\s*none\.?\s*$') { continue }
                        $pendingContent = $c
                        $rlmWorked = $true
                        break
                    }
                }
            } catch {
                Write-RelayLog "RLM error: $_"
            }
        }

        # Build output
        $lines = @()
        $lines += "RELAY RESTORE [project: $project] [task_id: $taskId]"
        $lines += ''
        $lines += "Предыдущая сессия передала управление автоматически (reason: $reason)."
        $lines += ''

        if ($handoffContent) {
            # Extract the primary "read this first" pointer (resume_prompt > spec)
            $primaryRead = $null
            if ($handoffContent -match '(?im)^\s*resume_prompt:\s*(\S.+?)\s*$') { $primaryRead = $matches[1].Trim() }
            elseif ($handoffContent -match '(?im)^\s*spec:\s*(\S.+?)\s*$')      { $primaryRead = $matches[1].Trim() }

            $lines += 'HANDOFF from previous session:'
            $lines += $handoffContent.TrimEnd()
            if ($primaryRead -and $primaryRead.ToLower() -ne 'none') {
                $lines += ''
                $lines += "AUTHORITATIVE READ: $primaryRead -- contains the full continuation plan. Read this first."
            }
        } elseif ($rlmWorked -and $pendingContent) {
            $lines += 'PENDING from previous session:'
            $lines += $pendingContent
        } elseif ($hint) {
            $lines += 'PENDING from previous session (RLM unavailable -- fallback from relay file):'
            $lines += $hint
        } else {
            $lines += 'No PENDING context available. Run rlm_route_context to restore full context.'
        }

        $lines += ''
        $lines += 'INSTRUCTION: Continue from the NEXT section above. Do not ask the user what to do.'
        $lines += "Do not run the 'kontekst' ritual -- context is already restored."
        $lines += 'If NEXT is clear -- execute immediately. If unclear -- report status and ask.'

        Write-Output ($lines -join "`n")

        # ONE-SHOT CONSUMPTION
        Remove-Item $relayPath -Force -ErrorAction SilentlyContinue
        Write-RelayLog "Relay consumed: task_id=$taskId project=$project reason=$reason"

        # ORS relay ACK
        $ackScript = $env:ORCH_RELAY_ACK_SCRIPT
        if (Test-Path $ackScript) {
            $sessionId = if ($event -and $event.session_id) { $event.session_id } else { '' }
            bash $ackScript $sessionId 'true' 2>$null
        }
    }
    # ── PATH 2: CLEAR/RESUME - manual /clear or resume, restore from RLM ──
    elseif ($trigger -eq 'clear' -or $trigger -eq 'resume') {
        Write-RelayLog "Trigger=$trigger, no relay file - querying RLM for session context"

        $projectName = 'unknown'
        if ($event -and $event.cwd) { $projectName = Split-Path $event.cwd -Leaf }

        $rlmAvailable = $null -ne (Get-Command Invoke-RLM-Read -ErrorAction SilentlyContinue)
        if (-not $rlmAvailable) {
            Write-RelayLog "RLM client not available - no restore"
            exit 0
        }

        try {
            Invoke-RLM -ToolName 'rlm_start_session' -Arguments @{ restore = $true } | Out-Null
            Start-Sleep -Milliseconds 300

            # Get last SESSION-END for this project
            $sessionEndRaw = Invoke-RLM-Read -ToolName 'rlm_search_facts' -Arguments @{
                query           = "SESSION-END [project: $projectName]"
                keyword_weight  = 0.5
                semantic_weight = 0.1
                recency_weight  = 0.4
                top_k           = 1
            }

            $sessionContent = ''
            if ($sessionEndRaw) {
                $parsed = $sessionEndRaw | ConvertFrom-Json
                foreach ($fact in $parsed.results) {
                    $c = $fact.content
                    # Match real SESSION-END facts, skip PENDING preservation wrappers
                    if ($c -match 'SESSION-END \[project:' -and $c -notmatch 'PENDING preservation') {
                        $sessionContent = $c
                        break
                    }
                }
            }

            # Get PENDING tasks
            $pendingContent = ''
            $pendingRaw = Invoke-RLM-Read -ToolName 'rlm_search_facts' -Arguments @{
                query           = "PENDING tasks next session [project: $projectName]"
                keyword_weight  = 0.2
                semantic_weight = 0.3
                recency_weight  = 0.5
                top_k           = 3
            }

            if ($pendingRaw) {
                $pendingJson = $pendingRaw | ConvertFrom-Json
                foreach ($fact in $pendingJson.results) {
                    $c = $fact.content
                    if ($c -match '\[project:\s*([\w][\w-]*)\]' -and $Matches[1] -ne $projectName) { continue }
                    if ($c -match '^\s*PENDING tasks next session:\s*none\.?\s*$') { continue }
                    # Skip preservation wrappers with empty results
                    if ($c -match 'PENDING preservation' -and $c -match '"results"\s*:\s*\[\s*\]') { continue }
                    # Skip raw JSON that isn't real content
                    if ($c -match '^\s*\{' -or $c -match '"status"\s*:\s*"success"') { continue }
                    $pendingContent = $c
                    break
                }
            }

            # Build output
            if ($sessionContent -or $pendingContent) {
                $lines = @()
                $lines += "SESSION RESTORE [project: $projectName] (trigger: $trigger)"
                $lines += ''
                if ($sessionContent) {
                    $lines += 'Last session summary:'
                    $lines += $sessionContent
                    $lines += ''
                }
                if ($pendingContent) {
                    $lines += 'PENDING from previous session:'
                    $lines += $pendingContent
                    $lines += ''
                }
                $lines += 'INSTRUCTION: Review the context above. If there are PENDING tasks - continue. If not - ask the user what to do.'
                Write-Output ($lines -join "`n")
                Write-RelayLog "RLM restore OK: project=$projectName trigger=$trigger"
            } else {
                Write-RelayLog "RLM returned no relevant facts for project=$projectName"
            }
        } catch {
            Write-RelayLog "RLM restore error: $_"
        }
    }
    # ── PATH 3: STARTUP - fresh session, no restore needed ──
    else {
        Write-RelayLog "Fresh startup - no restore needed"
    }

} catch {
    Write-RelayLog "EXCEPTION in session-start-restore.ps1: $_"
}

exit 0

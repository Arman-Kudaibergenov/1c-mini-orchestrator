# Context Guard Hook — PreToolUse
#
# Two-mode operation:
#
# 1) State-machine mode (primary): reads handoff state from
#    $TEMP/orch-handoff/<sid>.json. When state = COMPLIANCE, narrow whitelist
#    to handoff-only tools (RLM, Bash, Read). This is the hard-stop that
#    forces the agent to produce a handoff and nothing else.
#
# 2) Legacy threshold mode (fallback): if state file is missing (state
#    machine never armed, e.g. session-status lib not loaded), fall back to
#    the old PID-scoped ctx-state read + percentage thresholds. WARN at
#    40% remaining, CRIT at 23% remaining with the legacy (wider) whitelist.
#
# Session-id resolution for state lookup: PreToolUse event provides session_id
# in the JSON payload. Fall back to current PID-based ctx-state if needed.

param()

$ErrorActionPreference = 'SilentlyContinue'

. "$PSScriptRoot/lib/handoff-state.ps1"

$WARN_PCT   = 40
$CRIT_PCT   = 23
$WARN_FLOOR = 50000
$CRIT_FLOOR = 30000

# Compliance mode whitelist — always-allowed tools (Bash for git/ssh/heredoc,
# Read for inspecting own work, mcp__rlm-toolkit__* for state archival).
$COMPLIANCE_WHITELIST = @('Bash', 'Read')
# mcp__rlm prefix is also allowed (checked separately via -like 'mcp__rlm*')

# Write-class tools (Write, Edit, MultiEdit, NotebookEdit) get conditional allow
# in COMPLIANCE: ONLY when tool_input.file_path is a result-recording path.
# This lets the agent write handoff content / resume prompts properly (without
# fighting Bash heredoc quoting hell) while blocking new feature work.
$WRITE_TOOLS = @('Write', 'Edit', 'MultiEdit', 'NotebookEdit')

function Test-IsResultRecordingPath {
    # Accept paths that look like session-handoff / resume-prompt artifacts.
    # Convention-based — agent can dodge by naming files cleverly, but that's
    # a deliberate act, not accident.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $patterns = @(
        '*/orch-handoff/*', '*\orch-handoff\*',
        '*/next-session-prompts/*', '*\next-session-prompts\*',
        '*-ready.flag',
        '*-handoff.md', '*-handoff.txt',
        '*-resume-*.md', '*-resume.md',
        '*-pending-*.md', '*-pending.md'
    )
    foreach ($p in $patterns) {
        if ($Path -like $p) { return $true }
    }
    return $false
}

# Legacy CRIT whitelist (wider — used only when state machine isn't tracking)
$LEGACY_WHITELIST = @(
    'Read', 'Glob', 'Grep',
    'WebFetch', 'WebSearch',
    'AskUserQuestion',
    'ExitPlanMode',
    'TaskList', 'TaskGet'
)

try {
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop
    $toolName = $event.tool_name
    $sessionId = $event.session_id

    # ── State-machine mode: if handoff state exists, it's authoritative ──
    if ($sessionId) {
        $handoff = Read-HandoffState -SessionId $sessionId
        if ($handoff -and $handoff.state -in @('COMPLIANCE','HANDOFF_VALIDATED','ROTATED')) {
            $readyFlagPath = Get-HandoffReadyFlagPath -SessionId $sessionId

            $isAllowed = $false
            $pathAllowed = $false
            $writePath = $null

            if ($COMPLIANCE_WHITELIST -contains $toolName) { $isAllowed = $true }
            if ($toolName -like 'mcp__rlm*')               { $isAllowed = $true }

            # Write-class tools: allow ONLY if target path is a result-recording artifact.
            if (-not $isAllowed -and ($WRITE_TOOLS -contains $toolName)) {
                $writePath = $event.tool_input.file_path
                if (Test-IsResultRecordingPath -Path $writePath) {
                    $isAllowed = $true
                    $pathAllowed = $true
                }
            }

            # NORMAL mode: marker file present + state is COMPLIANCE → no hard-block.
            # Rotation is OFF, so forcing the agent into a handoff lane is wrong:
            # operator is at keyboard and just needs to /clear when ready. Stay
            # advisory. HANDOFF_VALIDATED / ROTATED are not relaxed here — those
            # mean rotation IS in flight (e.g. the operator armed it and the
            # state transitioned before they flipped the marker back), and we
            # must not interfere with an in-flight handoff.
            if ($handoff.state -eq 'COMPLIANCE' -and (Test-Path "$env:USERPROFILE\.claude\.orch-autonomous-off")) {
                $output = @{
                    hookSpecificOutput = @{
                        hookEventName      = "PreToolUse"
                        permissionDecision = "allow"
                        additionalContext  = "NORMAL mode: COMPLIANCE state advisory only — autonomous rotation is OFF (~/.claude/.orch-autonomous-off present). Wrap up or run /clear when ready."
                    }
                }
                Write-Output ($output | ConvertTo-Json -Compress -Depth 5)
                exit 0
            }

            if ($isAllowed) {
                $allowMsg = switch ($handoff.state) {
                    'COMPLIANCE' {
                        if ($pathAllowed) {
                            "COMPLIANCE: write allowed for result-recording path ($writePath). Use this for handoff content / resume prompts / WIP drafts only."
                        } else {
                            "COMPLIANCE: Bash/Read/mcp__rlm-toolkit__* + Write/Edit to result-recording paths are allowed. Finish current op, then write HANDOFF to $readyFlagPath."
                        }
                    }
                    'HANDOFF_VALIDATED' { "Handoff validated. Spawn pending — wait for the new terminal. Do not start new work." }
                    'ROTATED'           { "Session already rotated to a new terminal. This window is finished — close it." }
                }
                $output = @{
                    hookSpecificOutput = @{
                        hookEventName      = "PreToolUse"
                        permissionDecision = "allow"
                        additionalContext  = $allowMsg
                    }
                }
                Write-Output ($output | ConvertTo-Json -Compress -Depth 5)
                exit 0
            }

            $denyReason = switch ($handoff.state) {
                'COMPLIANCE' {
                    "Context COMPLIANCE blocked $toolName. Allowed: Bash (git/ssh/heredoc) + Read + mcp__rlm-toolkit__* + Write/Edit when target path looks like result-recording (orch-handoff/, next-session-prompts/, *-ready.flag, *-handoff.md, *-resume-*.md). " +
                    "A template ready.flag with the correct header is pre-seeded at $readyFlagPath — use the Edit tool to fill task/spec/resume_prompt/next_step. " +
                    "After your file validates, end your turn — the Stop hook (stop-rotate.ps1) spawns the new terminal once your assistant message finishes."
                }
                'HANDOFF_VALIDATED' {
                    "Handoff validated. End your turn now — the Stop hook will spawn the new terminal once your message finishes. No further tool calls are needed in this session."
                }
                'ROTATED' {
                    "Session already rotated. Close this terminal — work continues in the spawned one."
                }
            }
            $output = @{
                hookSpecificOutput = @{
                    hookEventName            = "PreToolUse"
                    permissionDecision       = "deny"
                    permissionDecisionReason = $denyReason
                }
            }
            Write-Output ($output | ConvertTo-Json -Compress -Depth 5)
            exit 0
        }
    }

    # ── Cleanup stale state files ──
    # PID-scoped:  delete files whose PID is dead and age > 60s.
    # Sess-scoped: delete files older than 2h (session-id can't be probed for
    #              liveness; statusline rewrites on every refresh so any sess
    #              file untouched for 2h belongs to a closed Claude window).
    Get-ChildItem -Path $env:TEMP -Filter "claude-ctx-state-*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        $age = ((Get-Date) - $_.LastWriteTime).TotalSeconds
        if ($_.Name -match '^claude-ctx-state-sess-.+\.json$') {
            if ($age -gt 7200) {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            }
        } elseif ($_.Name -match '^claude-ctx-state-(\d+)\.json$') {
            $filePid = [int]$Matches[1]
            if ($age -gt 60) {
                $proc = Get-Process -Id $filePid -ErrorAction SilentlyContinue
                if ($null -eq $proc) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # ── Session-id-scoped state file (canonical) ──
    # statusline.ps1 writes claude-ctx-state-sess-<sid>.json keyed on the
    # Claude session id from the statusline input. This is the ONLY safe
    # scope: PID is unstable across statusline refreshes, and the shared
    # file gets clobbered by every session. Reading those previously caused
    # cross-session false-triggers of context-guard.
    $ctxFile = $null
    if ($sessionId) {
        $candidate = Join-Path $env:TEMP "claude-ctx-state-sess-$sessionId.json"
        if (Test-Path $candidate) { $ctxFile = $candidate }
    }

    if (-not $ctxFile) { exit 0 }

    $fileAge = ((Get-Date) - (Get-Item $ctxFile).LastWriteTime).TotalSeconds
    if ($fileAge -gt 300) { exit 0 }  # stale > 5 min → skip

    $ctx = Get-Content $ctxFile -Raw | ConvertFrom-Json
    # Defense-in-depth: the filename already embeds the session id, but the
    # JSON payload also carries it — refuse to trust a mismatch.
    if ($ctx.sessionId -and $ctx.sessionId -ne $sessionId) { exit 0 }
    $tokens   = [long]$ctx.tokens
    $effLimit = [long]$ctx.effectiveLimit
    $limit    = [long]$ctx.limit
    if ($effLimit -le 0) { $effLimit = $limit }
    if ($effLimit -le 0) { exit 0 }

    $remaining = $effLimit - $tokens
    $pct       = [int]$ctx.pct
    $remainK   = [math]::Round($remaining / 1000)

    # Compute dynamic thresholds from effectiveLimit
    $WARN_REMAINING = [math]::Max($WARN_FLOOR, [math]::Round($effLimit * $WARN_PCT / 100))
    $CRIT_REMAINING = [math]::Max($CRIT_FLOOR, [math]::Round($effLimit * $CRIT_PCT / 100))

    # Fast path: plenty of context left
    if ($remaining -gt $WARN_REMAINING) { exit 0 }

    # WARN zone: allow but inject warning
    if ($remaining -gt $CRIT_REMAINING) {
        $output = @{
            hookSpecificOutput = @{
                hookEventName      = "PreToolUse"
                permissionDecision = "allow"
                additionalContext  = "WARNING: Context at ${remainK}k remaining (${pct}% used). Wrap up current task."
            }
        }
        Write-Output ($output | ConvertTo-Json -Compress -Depth 5)
        exit 0
    }

    # Legacy CRITICAL zone (fallback only — when state-machine isn't tracking)
    $isWhitelisted = $false

    if ($LEGACY_WHITELIST -contains $toolName) {
        $isWhitelisted = $true
    }

    if ($toolName -like 'mcp__rlm*') {
        $isWhitelisted = $true
    }

    if ($isWhitelisted) {
        $output = @{
            hookSpecificOutput = @{
                hookEventName      = "PreToolUse"
                permissionDecision = "allow"
                additionalContext  = "CRITICAL: Context at ${remainK}k remaining (${pct}% used). Only RLM/read-only tools allowed."
            }
        }
        Write-Output ($output | ConvertTo-Json -Compress -Depth 5)
        exit 0
    }

    # DENY
    $output = @{
        hookSpecificOutput = @{
            hookEventName            = "PreToolUse"
            permissionDecision       = "deny"
            permissionDecisionReason = "Context CRITICAL (${remainK}k remaining). Write result file with status=context_overflow and remaining work description to `$env:TEMP/orch-dispatch/result-PROJECT.json, then run /clear to exit. orchestrator will auto-relay a new agent to continue."
        }
    }
    Write-Output ($output | ConvertTo-Json -Compress -Depth 5)

    # Auto-signal for dispatched agents: write result + signal files
    $orchProject = $env:ORCH_PROJECT
    if ($orchProject) {
        $dispatchDir = Join-Path $env:TEMP "orch-dispatch"
        if (-not (Test-Path $dispatchDir)) { New-Item -ItemType Directory -Path $dispatchDir -Force | Out-Null }

        # Write result file (only if not already written)
        $resultPath = Join-Path $dispatchDir "result-$orchProject.json"
        if (-not (Test-Path $resultPath)) {
            $resultData = @{
                status    = "context_overflow"
                project   = $orchProject
                remaining = "Agent blocked by context-guard. Check RLM for progress details."
                timestamp = (Get-Date -Format o)
            } | ConvertTo-Json
            [System.IO.File]::WriteAllText($resultPath, $resultData, [System.Text.Encoding]::UTF8)
        }

        # Write signal file (triggers watcher immediately, only once)
        $signalPath = Join-Path $dispatchDir "signal-$orchProject.json"
        if (-not (Test-Path $signalPath)) {
            $signalData = @{
                project   = $orchProject
                status    = "context_overflow"
                timestamp = (Get-Date -Format o)
            } | ConvertTo-Json
            [System.IO.File]::WriteAllText($signalPath, $signalData, [System.Text.Encoding]::UTF8)
        }
    }

    exit 0

} catch {
    exit 0
}

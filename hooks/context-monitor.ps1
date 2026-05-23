# Context Monitor Hook — PostToolUse
#
# State-machine driven handoff flow (replaces direct CRIT -> spawn).
#
#   IDLE -> ARMED -> COMPLIANCE -> HANDOFF_VALIDATED -> ROTATED
#
# Bands (remaining tokens vs effectiveLimit):
#   1M model  : ARMED at <=85%, COMPLIANCE at <=75%
#   200k-class: ARMED at <=62%, COMPLIANCE at <=21%
#
# Per-fire actions:
#   * On state transition: imperative stdout message (one-shot per transition).
#   * On first COMPLIANCE entry: RLM auto-save baseline + write rlm-saved.flag.
#   * If $TEMP/orch-handoff/<sid>-ready.flag exists: read, validate, transition.
#
# Spawn lives in the Stop hook (stop-rotate.ps1), not in this file. PostToolUse
# only validates ready.flag and tells the agent to stop. The actual rotate
# happens when the assistant's turn ends, so the new terminal never races the
# parent mid-turn.

param()

$ErrorActionPreference = 'SilentlyContinue'

. "$PSScriptRoot/lib/rlm-client.ps1"
$statusLib = Join-Path $PSScriptRoot 'lib/session-status.ps1'
if (Test-Path $statusLib) { . $statusLib }
. "$PSScriptRoot/lib/handoff-state.ps1"
. "$PSScriptRoot/lib/handoff-validator.ps1"

$WARN_FLOOR = 40000
$CRIT_FLOOR = 20000

function Get-ContextThresholds {
    param([long]$EffectiveLimit)
    if ($EffectiveLimit -ge 500000) {
        return @{ WarnPct = 85; CritPct = 75 }
    } else {
        return @{ WarnPct = 62; CritPct = 21 }
    }
}

function Get-ProjectName {
    param($Event)
    if ($Event.cwd) { return (Split-Path $Event.cwd -Leaf) }
    return 'unknown'
}

function Get-ProjectPath {
    param($Event)
    if ($Event.cwd) { return $Event.cwd }
    return (Get-Location).Path
}

function Emit-StdoutOnce {
    # Per-session one-shot stdout via marker file in claude-ctx-alerts dir.
    param(
        [Parameter(Mandatory)][string]$MarkerPath,
        [Parameter(Mandatory)][string]$Message
    )
    if (Test-Path $MarkerPath) { return }
    New-Item -ItemType File -Path $MarkerPath -Force | Out-Null
    Write-Output $Message
}

function Write-MonitorLog {
    param([string]$Line)
    $logFile = "$env:TEMP\orch-context-monitor.log"
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    "$ts | $Line" | Add-Content $logFile -Encoding UTF8
}

try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop
    $sessionId = $event.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }

    # Read session-id-scoped context state. The shared file
    # ($env:TEMP\orch-ctx-state.json) is overwritten by EVERY session's
    # statusline refresh, so reading it directly caused cross-session
    # false-triggers (one session's high tokens armed another session's
    # handoff state). statusline.ps1 now writes
    # $env:TEMP\orch-ctx-state-sess-<sid>.json which is the ONLY safely
    # scoped source. Do NOT fall back to the shared file — that's the bug.
    $ctxFileSess = "$env:TEMP\orch-ctx-state-sess-$sessionId.json"
    if (-not (Test-Path $ctxFileSess)) { exit 0 }
    $fileAge = ((Get-Date) - (Get-Item $ctxFileSess).LastWriteTime).TotalSeconds
    if ($fileAge -gt 300) { exit 0 }
    $ctx = Get-Content $ctxFileSess -Raw | ConvertFrom-Json
    # Defense-in-depth: even though the filename embeds the session id, the
    # JSON payload also carries sessionId — if for any reason they disagree,
    # trust nothing.
    if ($ctx.sessionId -and $ctx.sessionId -ne $sessionId) { exit 0 }

    $tokens = [long]$ctx.tokens
    $limit  = [long]$ctx.effectiveLimit
    if ($limit -le 0) { $limit = [long]$ctx.limit }
    if ($limit -le 0) { exit 0 }

    $remaining = $limit - $tokens
    $pct = [int]$ctx.pct
    $remainK = [math]::Round($remaining / 1000)

    $thresholds = Get-ContextThresholds -EffectiveLimit $limit
    $WARN_REMAINING = [math]::Max($WARN_FLOOR, [math]::Round($limit * $thresholds.WarnPct / 100))
    $CRIT_REMAINING = [math]::Max($CRIT_FLOOR, [math]::Round($limit * $thresholds.CritPct / 100))

    if (Get-Command Update-SessionActivity -ErrorAction SilentlyContinue) {
        Update-SessionActivity -SessionId $sessionId -Tokens $tokens -Pct $pct
    }

    $stateDir = "$env:TEMP\orch-ctx-alerts"
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

    $projectName = Get-ProjectName -Event $event
    $projectPath = Get-ProjectPath -Event $event

    # ── State machine: read/init handoff state ──
    $handoff = Get-OrCreate-HandoffState -SessionId $sessionId -Project $projectName -ProjectPath $projectPath
    Update-HandoffState -SessionId $sessionId -Patch @{ last_remaining = $remaining; last_pct = $pct } | Out-Null

    # Terminal state: do nothing
    if ($handoff.state -eq 'ROTATED') { exit 0 }

    # ── Compute desired band from token level ──
    $desiredBand = 'IDLE'
    if ($remaining -le $CRIT_REMAINING) { $desiredBand = 'COMPLIANCE' }
    elseif ($remaining -le $WARN_REMAINING) { $desiredBand = 'ARMED' }

    # ── Transitions (forward-only) ──
    $stateOrder = @{ 'IDLE' = 0; 'ARMED' = 1; 'COMPLIANCE' = 2; 'HANDOFF_VALIDATED' = 3; 'ROTATED' = 4 }
    $curRank  = $stateOrder[$handoff.state]
    $bandRank = $stateOrder[$desiredBand]

    if ($bandRank -gt $curRank -and $handoff.state -in @('IDLE','ARMED')) {
        if ($desiredBand -eq 'COMPLIANCE' -and $handoff.state -eq 'IDLE') {
            # Skipped ARMED entirely (fast burn). Stamp armed_at too.
            Set-HandoffState -SessionId $sessionId -NewState 'ARMED' | Out-Null
        }
        $handoff = Set-HandoffState -SessionId $sessionId -NewState $desiredBand
        Write-MonitorLog "STATE_TRANSITION | $sessionId | -> $desiredBand | ${remainK}k remaining | ${pct}%"
    }

    $readyFlagPath = Get-HandoffReadyFlagPath -SessionId $sessionId
    $handoffDir    = Join-Path $env:TEMP 'orch-handoff'

    # ── Emit per-transition stdout (one-shot via marker) ──
    if ($handoff.state -eq 'ARMED') {
        $marker = Join-Path $stateDir "armed_stdout_${sessionId}"
        $msg = @"
CONTEXT-MONITOR ARMED: ${pct}% used (${remainK}k remaining). Wrap up the current operation in the next few minutes, then write a structured HANDOFF pointer-manifest for the next session.

HANDOFF FORMAT (raw text at $readyFlagPath):

  HANDOFF [project: $projectName] [parent-session: $sessionId] [created: <ISO timestamp>]
  task:           1-2 sentences — what this session was doing
  spec:           path to authoritative SDD/spec (or 'none')
  resume_prompt:  path to docs/next-session-prompts/*.md with full plan (or 'none')
  last_completed: short status, commit hash if applicable (optional)
  next_step:      single concrete imperative action for the child
  drafts:         paths to WIP files in `$env:TEMP/orch-handoff/ (or 'none', optional)
  blockers:       list (or 'none', optional)
  key_facts:      non-obvious learnings child can't infer from spec (or 'none', optional)

Required: task + next_step (>=20 chars each), AND at least one of spec/resume_prompt as a real path. The child reads the referenced doc for full context — do NOT duplicate SDD content here, just point to it.

STEPS:
  1. (Optional) mcp__rlm-toolkit__rlm_add_hierarchical_fact with the handoff text — archival.
  2. Write or Edit $readyFlagPath. Preferred: Write the full text yourself NOW while still in ARMED. If you wait until COMPLIANCE, a template file with the correct header will be pre-seeded — use Edit then, not Write.
  3. End your turn. The Stop hook (stop-rotate.ps1) spawns the new terminal AFTER your assistant message finishes, ONLY when the file validates. If you hit COMPLIANCE: Bash/Read/mcp__rlm-toolkit__* stay open, Write/Edit only to result-recording paths.

If validation fails, the hook auto-repairs a missing/malformed first-line header. Other validation errors (missing task / missing next_step / both spec and resume_prompt empty / banned placeholder phrases) are NOT auto-repaired — you must edit the file and retry.
"@
        Emit-StdoutOnce -MarkerPath $marker -Message $msg
    }

    if ($handoff.state -eq 'COMPLIANCE') {
        # NORMAL mode: marker file present → skip all COMPLIANCE side-effects.
        # Autonomous rotation is OFF, so we don't seed a handoff template, don't
        # auto-write an RLM baseline, don't write rlm-saved.flag. State machine
        # transition itself ran above (so the statusline reflects truth), but
        # we don't push the agent into a handoff lane it can't exit.
        if (Test-Path "$env:USERPROFILE\.claude\.orch-autonomous-off") {
            $marker = Join-Path $stateDir "compliance_normal_stdout_${sessionId}"
            Emit-StdoutOnce -MarkerPath $marker -Message "COMPLIANCE threshold crossed (${pct}% used, ${remainK}k remaining). Autonomous rotation is OFF (~/.claude/.orch-autonomous-off present) — consider /clear or operator handoff. Tools are not restricted."
            exit 0
        }

        # Pre-seed a template ready.flag with the correct header so the agent
        # cannot malform it. Agent only fills the body via Edit. Idempotent: if
        # the file already exists (agent or previous hook write), do nothing.
        if (-not (Test-Path $readyFlagPath)) {
            $tsNow = Get-Date -Format 'o'
            $template = @"
HANDOFF [project: $projectName] [parent-session: $sessionId] [created: $tsNow]
task:
spec:
resume_prompt:
next_step:
last_completed: none
drafts: none
blockers: none
key_facts: none
"@
            try {
                [System.IO.File]::WriteAllText($readyFlagPath, $template, [System.Text.Encoding]::UTF8)
                Write-MonitorLog "HANDOFF_TEMPLATE_SEEDED | $sessionId | $readyFlagPath"
            } catch {}
        }

        $marker = Join-Path $stateDir "compliance_stdout_${sessionId}"
        $msg = @"
CONTEXT-MONITOR COMPLIANCE: ${pct}% used (${remainK}k remaining). Hard limit crossed. PreToolUse restricts tools: Bash/Read/mcp__rlm-toolkit__* stay open; Write/Edit ONLY to result-recording paths.

A TEMPLATE ready.flag with the correct header is already on disk at:
  $readyFlagPath

DO NOT rewrite it from scratch with Write. Use the Edit tool to fill the empty fields (task, spec, resume_prompt, next_step). Touching the first line ('HANDOFF [project: ...] ...') is unnecessary and risky — the validator is strict about that header.

Required: task + next_step (>=20 chars each), AND at least one of spec/resume_prompt as a real path. Then end your turn. The Stop hook spawns the new terminal once the file validates.
"@
        Emit-StdoutOnce -MarkerPath $marker -Message $msg

        # ── RLM auto-save baseline on first COMPLIANCE entry (idempotent) ──
        if (-not $handoff.rlm_auto_saved) {
            $rlmLock = Join-Path $stateDir "rlmsaved_${sessionId}"
            $rlmAcquired = $false
            try {
                $fs = [System.IO.File]::Open($rlmLock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $fs.Close()
                $rlmAcquired = $true
            } catch { $rlmAcquired = $false }

            if ($rlmAcquired) {
                $filesEdited = @()
                $bufferFile = "$env:USERPROFILE\.claude\orch-autocapture-buffer.jsonl"
                if (Test-Path $bufferFile) {
                    foreach ($line in (Get-Content $bufferFile -Encoding UTF8)) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        try {
                            $entry = $line | ConvertFrom-Json
                            if ($entry.file) { $filesEdited += $entry.file }
                        } catch { continue }
                    }
                    $filesEdited = $filesEdited | Select-Object -Unique
                }
                $filesList = if ($filesEdited.Count -gt 0) { ($filesEdited | Select-Object -First 15) -join ", " } else { "none captured" }
                $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
                $factContent = "CONTEXT-MONITOR auto-save [project: $projectName] $ts (${remainK}k remaining, ${pct}% used). Files modified: $filesList. Session $sessionId hit compliance threshold. Baseline only — full HANDOFF fact is expected from the agent separately."

                Invoke-RLM -ToolName "rlm_start_session" -Arguments @{ restore = $true } | Out-Null
                Start-Sleep -Milliseconds 300
                Invoke-RLM -ToolName "rlm_add_hierarchical_fact" -Arguments @{ content = $factContent; domain = "workflow"; level = 1 } | Out-Null

                Write-MonitorLog "RLM_AUTO_SAVE | $sessionId | $projectName | ${remainK}k remaining"
                Update-HandoffState -SessionId $sessionId -Patch @{ rlm_auto_saved = $true } | Out-Null

                # rotate-session.ps1's guard requires this flag <120s old
                $flagDir = Join-Path $env:TEMP "orch-dispatch"
                if (-not (Test-Path $flagDir)) { New-Item -ItemType Directory -Path $flagDir -Force | Out-Null }
                Get-Date | Out-File (Join-Path $flagDir "rlm-saved.flag")
            }
        }
    }

    # ── Process ready.flag if agent produced one ──
    if ((Test-Path $readyFlagPath) -and $handoff.state -in @('ARMED','COMPLIANCE')) {
        $content = $null
        try { $content = [System.IO.File]::ReadAllText($readyFlagPath, [System.Text.Encoding]::UTF8) } catch {}
        $validation = Test-HandoffContent -Content $content
        $attempts = [int]$handoff.validation_attempts + 1

        # Auto-repair: if the only failure is the header line and the body has
        # the required fields, prepend the correct header instead of rejecting.
        # This catches the dominant failure mode where the agent overwrites the
        # template and forgets the magic first line.
        if (-not $validation.valid) {
            $headerErrors = @($validation.errors | Where-Object { $_ -like '*Missing or malformed header*' })
            $otherErrors  = @($validation.errors | Where-Object { $_ -notlike '*Missing or malformed header*' })
            if ($headerErrors.Count -gt 0 -and $otherErrors.Count -eq 0) {
                $tsNow = Get-Date -Format 'o'
                $newContent = "HANDOFF [project: $projectName] [parent-session: $sessionId] [created: $tsNow]`n" + ($content.TrimStart())
                try {
                    [System.IO.File]::WriteAllText($readyFlagPath, $newContent, [System.Text.Encoding]::UTF8)
                    $content = $newContent
                    $validation = Test-HandoffContent -Content $content
                    Write-MonitorLog "HANDOFF_AUTO_REPAIRED_HEADER | $sessionId"
                } catch {}
            }
        }

        if ($validation.valid) {
            $handoff = Set-HandoffState -SessionId $sessionId -NewState 'HANDOFF_VALIDATED' -Patch @{
                validation_attempts       = $attempts
                handoff_validation_errors = @()
            }
            Write-MonitorLog "HANDOFF_VALIDATED | $sessionId | attempt $attempts"
            $marker = Join-Path $stateDir "validated_stdout_${sessionId}"
            Emit-StdoutOnce -MarkerPath $marker -Message "HANDOFF VALIDATED. End your turn now — the new terminal will open AFTER your assistant message finishes (Stop hook owns the spawn, not PostToolUse). Do not start another tool chain; if you have a last commit/push to do, do it as the final action and then stop."
        } else {
            # Preserve the agent's partial content instead of deleting on failure.
            # Previous behavior: Remove-Item on every invalid attempt. That wiped
            # the agent's incremental Edit work and caused a destructive loop —
            # next PostToolUse cycle re-seeded the empty template (since Test-Path
            # was false), agent saw a blank slate, wrote partial again, deleted
            # again. Observed 2026-05-15: c2007ae7 needed 4 attempts, 0598b179
            # stalled forever after 4 attempts, every other COMPLIANCE session
            # today took multiple attempts to validate. With the file preserved,
            # the agent can incrementally Edit specific fields.
            Update-HandoffState -SessionId $sessionId -Patch @{
                validation_attempts       = $attempts
                handoff_validation_errors = $validation.errors
            } | Out-Null
            Write-MonitorLog ("HANDOFF_INVALID | $sessionId | attempt $attempts | errors: " + ($validation.errors -join '; '))
            # Re-emit (always — agent needs the error feedback on each invalid attempt)
            $errs = ($validation.errors | ForEach-Object { "  - $_" }) -join "`n"
            Write-Output "HANDOFF VALIDATION FAILED (attempt $attempts). Errors:`n$errs`n`nThe file at $readyFlagPath is preserved with your current content. Use Edit to fix the specific fields listed above — do NOT rewrite from scratch."
        }
    }

    # ── Spawn lives in the Stop hook (stop-rotate.ps1), not here. ──
    # PostToolUse only marks state HANDOFF_VALIDATED and emits the "stop now"
    # message. The actual rotate-session.ps1 spawn fires when the assistant's
    # turn ends, so the parent never races the child mid-turn.

} catch {
    exit 0
}

exit 0

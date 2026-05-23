# Stop-Rotate Hook — Stop event
#
# Spawns rotate-session.ps1 ONLY after the assistant's turn has fully ended.
# This is the second half of the handoff flow:
#
#   PostToolUse (context-monitor.ps1) — validates ready.flag, marks state
#     HANDOFF_VALIDATED, tells the agent "stop your turn now".
#   Stop (this file) — when state == HANDOFF_VALIDATED, run cooldown/grace
#     checks and spawn the child terminal.
#
# Splitting was forced by a race: when spawn lived in PostToolUse, the child
# opened while the parent was still mid-turn (more commits, RLM writes, TODO
# updates). Operator observed "new terminal opens before parent finishes the
# task" — wrong sequence. Stop hook fires AFTER the parent's final assistant
# message, so by definition the parent is done when this runs.

param()

$ErrorActionPreference = 'SilentlyContinue'

. "$PSScriptRoot/lib/handoff-state.ps1"
$statusLib = Join-Path $PSScriptRoot 'lib/session-status.ps1'
if (Test-Path $statusLib) { . $statusLib }

function Write-StopRotateLog {
    param([string]$Line)
    $logFile = "$env:TEMP\orch-stop-rotate.log"
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    "$ts | $Line" | Add-Content $logFile -Encoding UTF8
}

try {
    # Operator kill-switch: present => NORMAL mode, do not spawn rotation child
    # even if HANDOFF_VALIDATED. Symmetric with stop-autonomous-chain.ps1.
    if (Test-Path "$env:USERPROFILE\.claude\.orch-autonomous-off") {
        Write-StopRotateLog "KILL_SWITCH_ACTIVE | .autonomous-off present, skipping rotate spawn"
        exit 0
    }
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop
    $sessionId = $event.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }

    $handoff = Read-HandoffState -SessionId $sessionId
    if (-not $handoff) { exit 0 }
    if ($handoff.state -ne 'HANDOFF_VALIDATED') { exit 0 }
    if ($env:ORCH_AUTO_ROTATE -ne "1") {
        # Log so future debugging doesn't hit the same wall as 2026-05-15:
        # a session reached HANDOFF_VALIDATED but no terminal opened, with
        # zero log entries explaining why. Silent exit was the cause.
        Write-StopRotateLog "SKIPPED_AUTO_ROTATE_DISABLED | session $sessionId | state=HANDOFF_VALIDATED | ORCH_AUTO_ROTATE='$($env:ORCH_AUTO_ROTATE)' (set to '1' in ~/.claude/settings.json env to enable)"
        exit 0
    }

    $projectName = if ($handoff.project)      { $handoff.project }      else { 'unknown' }
    $projectPath = if ($handoff.project_path) { $handoff.project_path } else { (Get-Location).Path }
    $remainK = [math]::Round([long]$handoff.last_remaining / 1000)
    $pct     = [int]$handoff.last_pct

    $stateDir = "$env:TEMP\orch-ctx-alerts"
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

    $cooldownSec = 90
    if ($env:ORCH_ROTATE_COOLDOWN_SEC) {
        $tmpInt = 0
        if ([int]::TryParse($env:ORCH_ROTATE_COOLDOWN_SEC, [ref]$tmpInt)) { $cooldownSec = $tmpInt }
    }
    $graceSec = 300
    if ($env:ORCH_ROTATE_GRACE_SEC) {
        $tmpInt = 0
        if ([int]::TryParse($env:ORCH_ROTATE_GRACE_SEC, [ref]$tmpInt)) { $graceSec = $tmpInt }
    }

    # Per-project cooldown REMOVED (2026-05-16): it serialized legitimately
    # parallel parents on the same project. Two terminals on orch-v3 both
    # reaching HANDOFF_VALIDATED within 90s used to mean only one spawned a
    # child immediately; the other fell into a fragile deferred-spawn branch
    # that often silently dropped (hidden detached PS killable by AV/policy).
    # The per-session autorotated_${sessionId} lock below + the grace check
    # below are the actual cascade defense — cooldown was redundant.
    # Deferred-spawn machinery removed alongside.

    # Grace check: freshly-spawned child sessions (< 5min old) must not rotate
    # again. This catches the real cascade pattern A→B→A→... within seconds.
    # On grace-defer: log and exit. No detached scheduler — if the operator
    # really needs the child to rotate, they can /clear manually.
    if (Get-Command Read-SessionStatus -ErrorAction SilentlyContinue) {
        $journal = Read-SessionStatus -SessionId $sessionId
        if ($journal -and $journal.started_at) {
            try {
                $startedAt = [datetime]::Parse([string]$journal.started_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                $ageSec = ((Get-Date) - $startedAt).TotalSeconds
                if ($ageSec -lt $graceSec) {
                    Write-StopRotateLog "SPAWN_DEFERRED_GRACE | session $sessionId | age=$([int]$ageSec)s < ${graceSec}s | no scheduler"
                    exit 0
                }
            } catch {}
        }
    }

    $rotateLockFile = Join-Path $stateDir "autorotated_${sessionId}"
    $rotateAcquired = $false
    try {
        $fs2 = [System.IO.File]::Open($rotateLockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $fs2.Close()
        $rotateAcquired = $true
    } catch { $rotateAcquired = $false }

    if (-not $rotateAcquired) { exit 0 }

    $flagDir = Join-Path $env:TEMP "orch-dispatch"
    if (-not (Test-Path $flagDir)) { New-Item -ItemType Directory -Path $flagDir -Force | Out-Null }
    Get-Date | Out-File (Join-Path $flagDir "rlm-saved.flag")

    $readyFlagPath = Get-HandoffReadyFlagPath -SessionId $sessionId
    $relayBody = @{
        parent_session_id = $sessionId
        project           = $projectName
        project_path      = $projectPath
        created_at        = (Get-Date -Format "o")
        reason            = "handoff_validated_${remainK}k_remaining"
        handoff_file      = $readyFlagPath
        handoff_fact_key  = "HANDOFF [project: $projectName] [parent-session: $sessionId]"
    } | ConvertTo-Json -Depth 4
    $relayPath = Join-Path $flagDir "relay-pending.json"
    [System.IO.File]::WriteAllText($relayPath, $relayBody, [System.Text.Encoding]::UTF8)

    $rotateScript = $env:ORCH_ROTATE_SCRIPT
    if (Test-Path $rotateScript) {
        # DRYRUN affordance: smoke-test C, no-op spawn unless STOP_ROTATE_DRYRUN=1
        if ($env:STOP_ROTATE_DRYRUN -eq '1') {
            Write-StopRotateLog "DRYRUN_SPAWN | session $sessionId | project=$projectName | ${remainK}k remaining"
        } else {
            Start-Process powershell.exe -ArgumentList "-NoProfile", "-File", $rotateScript, "-ProjectPath", $projectPath, "-Title", $projectName -WindowStyle Hidden
        }
        Write-StopRotateLog "SPAWN_ROTATED | $projectName | parent $sessionId | ${remainK}k remaining | pct=${pct}"

        if (Get-Command Set-SessionRotated -ErrorAction SilentlyContinue) {
            Set-SessionRotated -SessionId $sessionId -Reason "handoff_validated_${remainK}k_remaining_${pct}pct"
        }
        Set-HandoffState -SessionId $sessionId -NewState 'ROTATED' | Out-Null
    }

} catch {
    exit 0
}

exit 0

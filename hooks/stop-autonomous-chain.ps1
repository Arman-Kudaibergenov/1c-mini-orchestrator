# Stop-Autonomous-Chain Hook — Stop event
#
# Backstop for the autonomous-chain pattern: when the agent finishes a
# task in a chain rotated session (ORCH_AUTONOMOUS_CHAIN=1) but the chain
# is not done AND context is not yet exhausted, models often reach a natural
# "task complete, awaiting next instruction" turn-end. That stalls the chain
# until the operator manually types "продолжай".
#
# This hook returns { "decision": "block", "reason": "..." } to refuse the
# Stop, injecting a system message that pushes the agent to pick the next
# chain item without operator input.
#
# Preconditions (ALL must hold to fire the block):
#   1. $env:ORCH_AUTONOMOUS_CHAIN == '1' (only autonomous-rotated sessions)
#   2. handoff state != HANDOFF_VALIDATED (stop-rotate would handle that)
#   3. anti-loop: no more than MAX_REPROMPTS in the last WINDOW_MIN minutes
#
# Anti-loop matters: if the agent keeps stopping immediately without doing
# work (e.g. model decided everything is done, or hit a bug), we don't want
# an infinite re-prompt cycle. After N back-to-back re-prompts within the
# window, give up and let the session stop normally — operator will see it
# and intervene.

param()

$ErrorActionPreference = 'SilentlyContinue'

. "$PSScriptRoot/lib/handoff-state.ps1"

$MAX_REPROMPTS = 4   # max re-prompts in window before giving up
$WINDOW_MIN    = 5   # rolling window in minutes

function Write-AutoChainLog {
    param([string]$Line)
    $logFile = "$env:TEMP\orch-stop-autonomous-chain.log"
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    "$ts | $Line" | Add-Content $logFile -Encoding UTF8
}

try {
    # Operator kill-switch: file marker beats env-var. Allows the user to take
    # over a rotated child terminal at the keyboard without restarting Claude
    # or hunting down where ORCH_AUTONOMOUS_CHAIN got set.
    if (Test-Path "$env:USERPROFILE\.claude\.orch-autonomous-off") {
        Write-AutoChainLog "KILL_SWITCH_ACTIVE | .autonomous-off present, skipping"
        exit 0
    }
    if ($env:ORCH_AUTONOMOUS_CHAIN -ne '1') { exit 0 }

    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop
    $sessionId = $event.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }

    # If the session is in (or past) the rotation lane, the rotation flow owns
    # the next step. Don't double-fire:
    #   HANDOFF_VALIDATED — stop-rotate.ps1 is about to spawn the child
    #   ROTATED           — child already running; parent must be allowed to
    #                       stop. Missing this branch (2026-05-15) caused the
    #                       parent terminal to be re-prompted 4 times after a
    #                       successful rotation, with the agent helplessly
    #                       reporting "Session already rotated. Close this
    #                       terminal" because context-guard blocked every tool.
    $handoff = Read-HandoffState -SessionId $sessionId
    if ($handoff -and $handoff.state -in @('HANDOFF_VALIDATED','ROTATED')) {
        Write-AutoChainLog "SKIP_STATE_$($handoff.state) | session $sessionId | rotation flow owns this"
        exit 0
    }

    # Anti-loop: count recent re-prompts for this session.
    $stateDir = "$env:TEMP\orch-ctx-alerts"
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $logFile = Join-Path $stateDir "chain_reprompts_${sessionId}.txt"

    $recentCount = 0
    if (Test-Path $logFile) {
        $cutoff = (Get-Date).AddMinutes(-$WINDOW_MIN)
        foreach ($line in (Get-Content $logFile -ErrorAction SilentlyContinue)) {
            try {
                $ts = [datetime]::Parse([string]$line, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if ($ts -gt $cutoff) { $recentCount++ }
            } catch {}
        }
    }

    if ($recentCount -ge $MAX_REPROMPTS) {
        Write-AutoChainLog "STALL_GIVE_UP | session $sessionId | $recentCount re-prompts in last ${WINDOW_MIN}min — letting stop proceed, operator must intervene"
        exit 0
    }

    # Append this re-prompt timestamp to the session log
    (Get-Date -Format 'o') | Add-Content -Path $logFile -Encoding UTF8

    $reason = "AUTONOMOUS CHAIN re-prompt #$($recentCount + 1)/$MAX_REPROMPTS. Бери следующий пункт цепочки и продолжай (код+commit+push). Завершить только если: '## CHAIN COMPLETE', handoff в *-ready.flag, или '## BLOCKED: <причина>'. Kill-switch: touch ~/.claude/.orch-autonomous-off"

    $output = @{
        decision = 'block'
        reason   = $reason
    }
    Write-Output ($output | ConvertTo-Json -Compress -Depth 4)
    Write-AutoChainLog "RE_PROMPTED | session $sessionId | recent_count=$($recentCount + 1)"
    exit 0

} catch {
    Write-AutoChainLog "EXCEPTION | $($_.Exception.Message)"
    exit 0
}

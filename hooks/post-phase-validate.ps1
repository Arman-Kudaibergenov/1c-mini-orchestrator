# post-phase-validate.ps1 — SessionEnd event hook for 1c-mini-orchestrator
#
# WHAT
#   When an L3 phase session (analyst / sdd-writer / implementer / auditor)
#   ends, automatically run the matching validate-*.ps1 against its task and
#   append the result to <task>/validate.log. Useful so the L2 orchestrator
#   can peek at the log instead of running validate manually after every L3
#   finishes.
#
# WHEN IT FIRES
#   Only when ALL of the following hold:
#     1. $env:ORCH_AUTO_VALIDATE -eq '1'    (opt-in env, default OFF)
#     2. cwd looks like an orchestrator repo (has projects.yaml + scripts/
#        validate-*.ps1 set)
#     3. The session is identifiable as a phase via $env:ORCH_PHASE
#        (analyst | sdd-writer | implementer | auditor) AND $env:ORCH_TASK_ID
#        — these are set by the spawn-*.ps1 wrapper into the L3 environment.
#
# OUTPUT
#   Silent (SessionEnd hooks have no effect on agent behavior — output is
#   informational only). Writes to:
#     <orch-root>/tasks/<task_id>/validate.log
#     $TEMP/orch-post-phase-validate.log

param()

$ErrorActionPreference = 'SilentlyContinue'

function Write-PhaseLog {
    param([string]$Line)
    $logFile = Join-Path $env:TEMP "orch-post-phase-validate.log"
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    "$ts | $Line" | Add-Content $logFile -Encoding UTF8
}

try {
    if ($env:ORCH_AUTO_VALIDATE -ne '1') { exit 0 }

    $phase  = $env:ORCH_PHASE
    $taskId = $env:ORCH_TASK_ID
    if ([string]::IsNullOrWhiteSpace($phase) -or [string]::IsNullOrWhiteSpace($taskId)) {
        Write-PhaseLog "SKIP | ORCH_PHASE='$phase' ORCH_TASK_ID='$taskId' — not set by spawner"
        exit 0
    }

    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $evt = $inputData | ConvertFrom-Json -ErrorAction Stop
    $cwd = $evt.cwd
    if ([string]::IsNullOrWhiteSpace($cwd)) { exit 0 }

    # Map phase -> validator script (relative to orchestrator root)
    $validatorMap = @{
        'analyst'      = 'scripts\validate-analysis.ps1'
        'sdd-writer'   = 'scripts\validate-sdd.ps1'
        'implementer'  = 'scripts\validate-impl.ps1'
        'auditor'      = 'scripts\validate-audit.ps1'
    }
    if (-not $validatorMap.ContainsKey($phase)) {
        Write-PhaseLog "SKIP | unknown phase '$phase'"
        exit 0
    }

    # Walk up from cwd to find orchestrator root (projects.yaml + scripts/)
    $orchRoot = $null
    $dir = (Resolve-Path $cwd).Path
    while ($dir -and $dir -ne (Split-Path $dir -Parent)) {
        if ((Test-Path (Join-Path $dir 'projects.yaml')) -and (Test-Path (Join-Path $dir 'scripts'))) {
            $orchRoot = $dir
            break
        }
        $dir = Split-Path $dir -Parent
    }
    if (-not $orchRoot) {
        Write-PhaseLog "SKIP | orchestrator root not found upward from $cwd"
        exit 0
    }

    $validator = Join-Path $orchRoot $validatorMap[$phase]
    if (-not (Test-Path $validator)) {
        Write-PhaseLog "SKIP | validator missing: $validator"
        exit 0
    }

    $taskDir = Join-Path $orchRoot "tasks\$taskId"
    if (-not (Test-Path $taskDir)) {
        Write-PhaseLog "SKIP | task dir missing: $taskDir"
        exit 0
    }

    $logPath = Join-Path $taskDir "validate.log"
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    Add-Content $logPath "==== $ts | phase=$phase task=$taskId ====" -Encoding UTF8

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File $validator -TaskId $taskId 2>&1
    $exit = $LASTEXITCODE

    $output | Out-String | Add-Content $logPath -Encoding UTF8
    Add-Content $logPath "==== exit=$exit ====" -Encoding UTF8

    Write-PhaseLog "RAN | phase=$phase task=$taskId exit=$exit -> $logPath"
    exit 0

} catch {
    Write-PhaseLog "EXCEPTION | $($_.Exception.Message)"
    exit 0
}

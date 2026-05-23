# Handoff State Machine — per-session state for the soft/hard stop flow.
#
# States: IDLE -> ARMED -> COMPLIANCE -> HANDOFF_VALIDATED -> ROTATED
#
# - IDLE: normal operation
# - ARMED: soft warning fired, agent asked to write handoff voluntarily
# - COMPLIANCE: hard threshold crossed, PreToolUse will narrow whitelist
# - HANDOFF_VALIDATED: agent's ready.flag exists and content passed validator
# - ROTATED: rotate-session.ps1 has been spawned, parent is done
#
# Agent contract: when state in {ARMED, COMPLIANCE}, write handoff content to
# $TEMP/orch-handoff/<sid>-ready.flag (raw text with required fields) and,
# best-effort, RLM as `HANDOFF [project: X] [parent-session: Y]`. Hook reads
# ready.flag, validates, transitions state.
#
# Dot-source from hooks: . "$PSScriptRoot/lib/handoff-state.ps1"
# All functions are best-effort: failures must never break the calling hook.

$script:HandoffDir = Join-Path $env:TEMP 'orch-handoff'

function Initialize-HandoffDir {
    if (-not (Test-Path $script:HandoffDir)) {
        New-Item -ItemType Directory -Path $script:HandoffDir -Force | Out-Null
    }
}

function Get-HandoffStatePath {
    param([Parameter(Mandatory)][string]$SessionId)
    return (Join-Path $script:HandoffDir "$SessionId.json")
}

function Get-HandoffReadyFlagPath {
    param([Parameter(Mandatory)][string]$SessionId)
    return (Join-Path $script:HandoffDir "$SessionId-ready.flag")
}

function ConvertTo-HandoffHashtable {
    param($Object)
    if ($null -eq $Object) { return @{} }
    $h = @{}
    foreach ($p in $Object.PSObject.Properties) {
        $h[$p.Name] = $p.Value
    }
    return $h
}

function Read-HandoffState {
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Get-HandoffStatePath -SessionId $SessionId
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        return ConvertTo-HandoffHashtable ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-HandoffStateAtomic {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][hashtable]$Data
    )
    try {
        Initialize-HandoffDir
        $path = Get-HandoffStatePath -SessionId $SessionId
        $tmp  = "$path.tmp"
        $json = $Data | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
        Move-Item -Path $tmp -Destination $path -Force
    } catch {
        # silent — hook must not break on state file errors
    }
}

function New-HandoffState {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Project = 'unknown',
        [string]$ProjectPath = ''
    )
    $existing = Read-HandoffState -SessionId $SessionId
    if ($existing) { return $existing }
    $now = (Get-Date -Format 'o')
    $data = @{
        session_id                 = $SessionId
        project                    = $Project
        project_path               = $ProjectPath
        state                      = 'IDLE'
        created_at                 = $now
        last_update                = $now
        armed_at                   = $null
        compliance_at              = $null
        handoff_validated_at       = $null
        rotated_at                 = $null
        rlm_auto_saved             = $false
        ready_flag_processed_at    = $null
        handoff_validation_errors  = @()
        validation_attempts        = 0
        last_remaining             = 0
        last_pct                   = 0
    }
    Write-HandoffStateAtomic -SessionId $SessionId -Data $data
    return $data
}

function Get-OrCreate-HandoffState {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Project = 'unknown',
        [string]$ProjectPath = ''
    )
    $data = Read-HandoffState -SessionId $SessionId
    if ($data) { return $data }
    return (New-HandoffState -SessionId $SessionId -Project $Project -ProjectPath $ProjectPath)
}

function Set-HandoffState {
    # Transition to a new state (forward-only). Stamps the corresponding
    # *_at field on first entry. Optional $Patch applies extra fields.
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$NewState,
        [hashtable]$Patch = @{}
    )
    $data = Read-HandoffState -SessionId $SessionId
    if (-not $data) { $data = New-HandoffState -SessionId $SessionId }
    $now = (Get-Date -Format 'o')
    $data.state = $NewState
    $data.last_update = $now
    switch ($NewState) {
        'ARMED'             { if (-not $data.armed_at)             { $data.armed_at = $now } }
        'COMPLIANCE'        { if (-not $data.compliance_at)        { $data.compliance_at = $now } }
        'HANDOFF_VALIDATED' { if (-not $data.handoff_validated_at) { $data.handoff_validated_at = $now } }
        'ROTATED'           { if (-not $data.rotated_at)           { $data.rotated_at = $now } }
    }
    foreach ($k in $Patch.Keys) { $data[$k] = $Patch[$k] }
    Write-HandoffStateAtomic -SessionId $SessionId -Data $data
    return $data
}

function Update-HandoffState {
    # Patch without changing the state value.
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][hashtable]$Patch
    )
    $data = Read-HandoffState -SessionId $SessionId
    if (-not $data) { $data = New-HandoffState -SessionId $SessionId }
    foreach ($k in $Patch.Keys) { $data[$k] = $Patch[$k] }
    $data.last_update = (Get-Date -Format 'o')
    Write-HandoffStateAtomic -SessionId $SessionId -Data $data
    return $data
}

function Test-HandoffStateIs {
    # Quick check — used by context-guard to decide whitelist mode without
    # reading the full file structure.
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string[]]$States
    )
    $data = Read-HandoffState -SessionId $SessionId
    if (-not $data) { return $false }
    return ($States -contains $data.state)
}

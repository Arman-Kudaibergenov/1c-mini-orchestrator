# Session Status Journal — per-session state for the auto-rotation chain.
# Each session writes $env:TEMP\orch-sessions\<session_id>.json so an
# operator (or later analysis) can reconstruct who spawned whom, what each
# session was supposed to do, and what actually happened.
#
# Dot-source this from hooks: . "$PSScriptRoot\lib\session-status.ps1"
# All functions are best-effort: failures must never break the calling hook.

$script:SessionStatusDir = Join-Path $env:TEMP 'orch-sessions'

function Initialize-SessionStatusDir {
    if (-not (Test-Path $script:SessionStatusDir)) {
        New-Item -ItemType Directory -Path $script:SessionStatusDir -Force | Out-Null
    }
}

function Get-SessionStatusPath {
    param([Parameter(Mandatory)][string]$SessionId)
    return (Join-Path $script:SessionStatusDir "$SessionId.json")
}

function ConvertTo-SessionHashtable {
    param($Object)
    # PS 5.1 has no ConvertFrom-Json -AsHashtable; we walk PSObject properties.
    if ($null -eq $Object) { return @{} }
    $h = @{}
    foreach ($p in $Object.PSObject.Properties) {
        $h[$p.Name] = $p.Value
    }
    return $h
}

function Write-SessionStatusAtomic {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][hashtable]$Data
    )
    try {
        Initialize-SessionStatusDir
        $path = Get-SessionStatusPath -SessionId $SessionId
        $tmp  = "$path.tmp"
        $json = $Data | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
        Move-Item -Path $tmp -Destination $path -Force
    } catch {
        # silent — hook must not break on status journal errors
    }
}

function Read-SessionStatus {
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Get-SessionStatusPath -SessionId $SessionId
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        return ConvertTo-SessionHashtable ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function New-SessionStatus {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Project = 'unknown',
        [string]$ProjectPath = '',
        [string]$ParentSessionId = '',
        [string]$Goal = '',
        [string]$InboundReason = '',
        [string]$Trigger = 'startup'
    )
    # Don't overwrite if file already exists — preserve children/activity that
    # may have been written by a faster fire of another hook on the same id.
    $existing = Read-SessionStatus -SessionId $SessionId
    if ($existing) {
        if (-not $existing.project_path -and $ProjectPath)   { $existing.project_path   = $ProjectPath }
        if (-not $existing.project      -and $Project)       { $existing.project        = $Project }
        if (-not $existing.parent_session_id -and $ParentSessionId) { $existing.parent_session_id = $ParentSessionId }
        if (-not $existing.goal         -and $Goal)          { $existing.goal           = $Goal }
        if (-not $existing.inbound_reason -and $InboundReason) { $existing.inbound_reason = $InboundReason }
        if (-not $existing.trigger      -and $Trigger)       { $existing.trigger        = $Trigger }
        Write-SessionStatusAtomic -SessionId $SessionId -Data $existing
        return
    }

    $now = (Get-Date -Format 'o')
    $data = @{
        session_id        = $SessionId
        project           = $Project
        project_path      = $ProjectPath
        parent_session_id = $ParentSessionId
        goal              = $Goal
        inbound_reason    = $InboundReason
        trigger           = $Trigger
        started_at        = $now
        last_activity     = $now
        last_tokens       = 0
        last_pct          = 0
        status            = 'active'
        rotation_reason   = ''
        children          = @()
        files_modified    = @()
        tool_calls        = 0
        problems          = @()
        ended_at          = $null
        outcome           = ''
    }
    Write-SessionStatusAtomic -SessionId $SessionId -Data $data
}

function Update-SessionActivity {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [long]$Tokens = -1,
        [int]$Pct = -1
    )
    $data = Read-SessionStatus -SessionId $SessionId
    if (-not $data) { return }
    $data.last_activity = (Get-Date -Format 'o')
    if ($Tokens -ge 0) { $data.last_tokens = $Tokens }
    if ($Pct    -ge 0) { $data.last_pct    = $Pct    }
    Write-SessionStatusAtomic -SessionId $SessionId -Data $data
}

function Set-SessionRotated {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Reason = ''
    )
    $data = Read-SessionStatus -SessionId $SessionId
    if (-not $data) { return }
    $data.status          = 'rotated'
    $data.rotation_reason = $Reason
    $data.last_activity   = (Get-Date -Format 'o')
    Write-SessionStatusAtomic -SessionId $SessionId -Data $data
}

function Add-SessionChild {
    param(
        [Parameter(Mandatory)][string]$ParentSessionId,
        [Parameter(Mandatory)][string]$ChildSessionId
    )
    $data = Read-SessionStatus -SessionId $ParentSessionId
    if (-not $data) {
        # Parent not journaled (pre-deployment session). Create a stub so the
        # chain can still be reconstructed.
        New-SessionStatus -SessionId $ParentSessionId -Project 'unknown' -Trigger 'inferred-parent'
        $data = Read-SessionStatus -SessionId $ParentSessionId
        if (-not $data) { return }
    }
    $children = @()
    if ($data.children) { $children = @($data.children) }
    if ($children -notcontains $ChildSessionId) {
        $children += $ChildSessionId
    }
    $data.children = $children
    Write-SessionStatusAtomic -SessionId $ParentSessionId -Data $data
}

function Add-SessionProblem {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Message
    )
    $data = Read-SessionStatus -SessionId $SessionId
    if (-not $data) { return }
    $problems = @()
    if ($data.problems) { $problems = @($data.problems) }
    $problems += @{ ts = (Get-Date -Format 'o'); msg = $Message }
    $data.problems = $problems
    Write-SessionStatusAtomic -SessionId $SessionId -Data $data
}

function Set-SessionEnded {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Outcome = '',
        [int]$ToolCalls = -1,
        [string[]]$FilesModified = @(),
        [string]$Reason = ''
    )
    $data = Read-SessionStatus -SessionId $SessionId
    if (-not $data) { return }
    # Don't downgrade a rotated session — rotation is a richer end-state.
    if ($data.status -ne 'rotated') { $data.status = 'ended' }
    $data.ended_at = (Get-Date -Format 'o')
    if ($Outcome)            { $data.outcome = $Outcome }
    if ($ToolCalls -ge 0)    { $data.tool_calls = $ToolCalls }
    if ($FilesModified -and $FilesModified.Count -gt 0) {
        $data.files_modified = @($FilesModified)
    }
    if ($Reason) { $data.end_reason = $Reason }
    Write-SessionStatusAtomic -SessionId $SessionId -Data $data
}

function Get-AllSessionStatuses {
    Initialize-SessionStatusDir
    $results = @()
    foreach ($f in (Get-ChildItem $script:SessionStatusDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $raw = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json
            $results += (ConvertTo-SessionHashtable $obj)
        } catch { continue }
    }
    return $results
}

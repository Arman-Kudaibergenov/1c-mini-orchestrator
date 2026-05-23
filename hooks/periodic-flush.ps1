# Periodic Flush Hook — PostToolUse (async, Edit|Write matcher)
# Every 20 edit/write tool calls: saves modified file list to RLM.
# Fast path (<10ms) when counter < 20.

param()

$ErrorActionPreference = 'SilentlyContinue'

. "$PSScriptRoot\lib\rlm-client.ps1"

try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop

    $sessionId = $event.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }

    $cwd = $event.cwd

    # ── Counter check (fast path) ──
    $counterFile = "$env:TEMP\orch-flush-count-$sessionId.txt"
    $count = 0
    if (Test-Path $counterFile) {
        $countStr = [System.IO.File]::ReadAllText($counterFile, [System.Text.Encoding]::UTF8).Trim()
        [int]::TryParse($countStr, [ref]$count) | Out-Null
    }
    $count++
    [System.IO.File]::WriteAllText($counterFile, "$count", [System.Text.Encoding]::UTF8)

    if ($count -lt 10) { exit 0 }

    # ── Flush ──
    $projectName = "unknown"
    if ($cwd) { $projectName = Split-Path $cwd -Leaf }

    $filesEdited = [System.Collections.Generic.HashSet[string]]::new()
    $bufferFile = "$env:USERPROFILE\.claude\orch-autocapture-buffer.jsonl"
    if (Test-Path $bufferFile) {
        $allLines = [System.IO.File]::ReadAllLines($bufferFile, [System.Text.Encoding]::UTF8)
        foreach ($line in $allLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.session -eq $sessionId -and $entry.file) {
                    $null = $filesEdited.Add($entry.file)
                }
            } catch { continue }
        }
    }

    $filesList = if ($filesEdited.Count -gt 0) {
        ($filesEdited | Select-Object -First 20) -join ", "
    } else { "none" }

    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $factContent = "AUTO-FLUSH [project: $projectName] $ts. Files modified: $filesList. Edit count: $count."

    Invoke-RLM "rlm_start_session" @{ restore = $true } | Out-Null
    Start-Sleep -Milliseconds 300
    Invoke-RLM "rlm_add_hierarchical_fact" @{
        content  = $factContent
        domain   = "workflow"
        level    = 1
        ttl_days = 14
    } | Out-Null

    # Reset counter
    [System.IO.File]::WriteAllText($counterFile, "0", [System.Text.Encoding]::UTF8)

} catch {
    exit 0
}

exit 0

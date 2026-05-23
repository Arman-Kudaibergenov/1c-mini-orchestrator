# Session End Save Hook — SessionEnd
# Saves session summary to RLM: files modified, commands run, git state, tool call count.

param()

$ErrorActionPreference = 'SilentlyContinue'

. "$PSScriptRoot\lib\rlm-client.ps1"
$statusLib = Join-Path $PSScriptRoot 'lib\session-status.ps1'
if (Test-Path $statusLib) { . $statusLib }

# Ensure RLM tunnel is alive before saving
$tunnelScript = $env:ORCH_RLM_TUNNEL_SCRIPT
if (Test-Path $tunnelScript) {
    bash $tunnelScript 2>$null | Out-Null
}

try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop

    $sessionId      = $event.session_id
    $cwd            = $event.cwd
    $reason         = if ($event.reason) { $event.reason } else { "unknown" }
    $transcriptPath = $event.transcript_path
    $ts             = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

    $projectName = "unknown"
    if ($cwd) { $projectName = Split-Path $cwd -Leaf }

    # ── 1. Read autocapture buffer, filter by session ──
    $filesEdited = [System.Collections.Generic.HashSet[string]]::new()
    $commandsRun = @()

    $bufferFile = "$env:USERPROFILE\.claude\orch-autocapture-buffer.jsonl"
    $otherSessionLines = @()

    if (Test-Path $bufferFile) {
        $allLines = [System.IO.File]::ReadAllLines($bufferFile, [System.Text.Encoding]::UTF8)
        foreach ($line in $allLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.session -eq $sessionId) {
                    if ($entry.file) { $null = $filesEdited.Add($entry.file) }
                    if ($entry.cmd)  { $commandsRun += $entry.cmd }
                } else {
                    $otherSessionLines += $line
                }
            } catch { $otherSessionLines += $line; continue }
        }
    }

    # ── 2. Count tool calls from mcp-stats ──
    $toolCallCount = 0
    $statsFile = "$env:USERPROFILE\.claude\orch-mcp-stats.jsonl"
    if (Test-Path $statsFile) {
        $statsLines = [System.IO.File]::ReadAllLines($statsFile, [System.Text.Encoding]::UTF8)
        foreach ($line in $statsLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.session -eq $sessionId) { $toolCallCount++ }
            } catch { continue }
        }
    }

    # ── 3. Skip trivial sessions ──
    if ($filesEdited.Count -eq 0 -and $toolCallCount -eq 0) { exit 0 }

    # ── 4. Extract last 3 user messages from transcript ──
    $userMessages = @()
    if ($transcriptPath -and (Test-Path $transcriptPath)) {
        $tailLines = Get-Content $transcriptPath -Tail 200 -Encoding UTF8 -ErrorAction Stop
        foreach ($line in $tailLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json -ErrorAction Stop
                $isUser = ($entry.type -eq "human") -or ($entry.role -eq "user")
                if ($isUser) {
                    $text = ""
                    if ($entry.content -is [string]) {
                        $text = $entry.content
                    } elseif ($entry.message.content -is [array]) {
                        foreach ($block in $entry.message.content) {
                            if ($block.type -eq "text" -and $block.text) { $text = $block.text; break }
                        }
                    } elseif ($entry.content -is [array]) {
                        foreach ($block in $entry.content) {
                            if ($block.type -eq "text" -and $block.text) { $text = $block.text; break }
                        }
                    }
                    if ($text.Length -gt 150) { $text = $text.Substring(0, 150) + "..." }
                    if ($text) { $userMessages += $text }
                }
            } catch { continue }
        }
    }

    # ── 5. Git status ──
    $gitBranch = "none"
    $gitStatus = "no-git"
    $gitDir = Join-Path $cwd ".git"
    if ($cwd -and (Test-Path $gitDir)) {
        $branchOut = (git -C $cwd branch --show-current 2>$null)
        if ($branchOut) { $gitBranch = $branchOut.Trim() }

        $statusOut = (git -C $cwd status --porcelain 2>$null)
        $dirtyCount = 0
        if ($statusOut) {
            $dirtyCount = ($statusOut -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        }
        $gitStatus = if ($dirtyCount -gt 0) { "dirty $dirtyCount files" } else { "clean" }
    }

    # ── 6. Build fact ──
    $filesList = if ($filesEdited.Count -gt 0) {
        ($filesEdited | Select-Object -First 20) -join ", "
    } else { "none" }

    $cmdsList = if ($commandsRun.Count -gt 0) {
        $truncated = $commandsRun | Select-Object -Last 5 | ForEach-Object {
            if ($_.Length -gt 80) { $_.Substring(0, 80) + "..." } else { $_ }
        }
        $truncated -join "; "
    } else { "none" }

    $lastMsgs = if ($userMessages.Count -gt 0) {
        ($userMessages | Select-Object -Last 3) -join " | "
    } else { "(none captured)" }

    $gitDiffStat = ""
    if ($cwd -and (Test-Path (Join-Path $cwd ".git"))) {
        $gitDiffStat = (git -C $cwd diff --stat HEAD~1 HEAD 2>$null) -join "; "
    }

    $factContent = "SESSION-END [project: $projectName] $ts (reason: $reason). " +
        "Session: $sessionId. " +
        "Files modified ($($filesEdited.Count)): $filesList. " +
        "Notable commands: $cmdsList. " +
        "Git: branch=$gitBranch, status=$gitStatus. " +
        "Git diff: $(if($gitDiffStat){$gitDiffStat}else{'none'}). " +
        "Tool calls: $toolCallCount. " +
        "Last user context: $lastMsgs"

    # ── 7. Save to RLM ──
    Invoke-RLM "rlm_start_session" @{ restore = $true } | Out-Null
    Start-Sleep -Milliseconds 300
    Invoke-RLM "rlm_add_hierarchical_fact" @{
        content  = $factContent
        domain   = "workflow"
        level    = 1
        ttl_days = 30
    } | Out-Null

    # ── 7b-pre. Preserve last known PENDING tasks ──
    try {
        $latestPending = Invoke-RLM-Read "rlm_search_facts" @{
            query = "PENDING tasks next session [project: $projectName]"
            keyword_weight = 0.8
            semantic_weight = 0.1
            recency_weight = 0.1
            top_k = 3
        }
        if ($latestPending) {
            $pendingSnippet = if ($latestPending.Length -gt 500) { $latestPending.Substring(0, 500) + "..." } else { $latestPending }
            Invoke-RLM "rlm_add_hierarchical_fact" @{
                content  = "SESSION-END PENDING preservation [project: $projectName] $ts. Last known: $pendingSnippet"
                domain   = "workflow"
                level    = 1
                ttl_days = 7
            } | Out-Null
        }
    } catch {}

    # ── 7b. Write dispatch signal if this was a dispatched session ──
    $orchProject = $env:ORCH_PROJECT
    if ($orchProject) {
        try {
            $signalDir = Join-Path $env:TEMP 'orch-dispatch'
            if (-not (Test-Path $signalDir)) { New-Item -ItemType Directory -Path $signalDir -Force | Out-Null }

            # Read result file if agent wrote one
            $resultFile = Join-Path $signalDir "result-$orchProject.json"
            $dispatchStatus = "completed"
            $summary = ""
            if (Test-Path $resultFile) {
                try {
                    $res = Get-Content $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($res.status) { $dispatchStatus = $res.status }
                    if ($res.summary) { $summary = $res.summary }
                } catch {}
            }

            # Git info from cwd
            $branch = ""
            if ($cwd -and (Test-Path (Join-Path $cwd ".git"))) {
                $branch = (git -C $cwd branch --show-current 2>$null)
            }

            $signalData = @{
                project   = $orchProject
                status    = $dispatchStatus
                source    = "session-end-hook"
                branch    = $branch
                summary   = $summary
                reason    = $reason
                timestamp = (Get-Date -Format o)
            } | ConvertTo-Json

            $signalPath = Join-Path $signalDir "signal-$orchProject.json"
            [System.IO.File]::WriteAllText($signalPath, $signalData, [System.Text.Encoding]::UTF8)
        } catch {
            # Silent fail - don't break session-end for signal issues
        }
    }

    # ── 8. Rewrite buffer keeping only other sessions ──
    if (Test-Path $bufferFile) {
        $newContent = ($otherSessionLines -join "`n")
        if ($newContent) { $newContent += "`n" }
        [System.IO.File]::WriteAllText($bufferFile, $newContent, [System.Text.Encoding]::UTF8)
    }

    # ── 9. Log ──
    "$ts | $reason | $projectName | files:$($filesEdited.Count) | tools:$toolCallCount | git:$gitStatus" |
        Add-Content "$env:TEMP\orch-session-end.log" -Encoding UTF8

    # ── 10. Finalize session status journal ──
    if (Get-Command Set-SessionEnded -ErrorAction SilentlyContinue) {
        $outcome = "files=$($filesEdited.Count); tools=$toolCallCount; git=$gitStatus; branch=$gitBranch"
        $filesArr = @($filesEdited)
        Set-SessionEnded -SessionId $sessionId -Outcome $outcome -ToolCalls $toolCallCount `
            -FilesModified $filesArr -Reason $reason
    }

} catch {
    "$((Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')) | ERROR: $_" |
        Add-Content "$env:TEMP\orch-session-end.log" -Encoding UTF8
}

exit 0

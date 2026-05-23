# Handoff Write Guard — PreToolUse
#
# Blocks Write/Edit/MultiEdit on *-ready.flag files when the proposed final
# content would fail Test-HandoffContent. Catches the failure synchronously
# so the agent sees the validator's complaint as a deny-reason from the tool
# call, instead of:
#   1. writing markdown (e.g. "## task" header), tool returns success,
#   2. context-monitor (PostToolUse) parses it, finds no `task:` field,
#   3. silently deletes the ready.flag,
#   4. agent ends its turn unaware, stop-rotate sees state != HANDOFF_VALIDATED
#      and never spawns the child terminal.
#
# Why a separate hook (not context-guard): context-guard already runs on every
# PreToolUse to enforce the COMPLIANCE whitelist; mixing schema validation
# into it would muddy two concerns. This file does one thing.

param()

$ErrorActionPreference = 'SilentlyContinue'

. "$PSScriptRoot/lib/handoff-validator.ps1"

function Write-HandoffWriteGuardLog {
    param([string]$Line)
    $logFile = "$env:TEMP\orch-handoff-write-guard.log"
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    "$ts | $Line" | Add-Content $logFile -Encoding UTF8
}

try {
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop
    $toolName = $event.tool_name
    if ($toolName -notin @('Write','Edit','MultiEdit')) { exit 0 }

    $filePath = [string]$event.tool_input.file_path
    if ([string]::IsNullOrWhiteSpace($filePath)) { exit 0 }
    if ($filePath -notlike '*-ready.flag') { exit 0 }

    # Compute the proposed post-tool content. For Edit/MultiEdit we apply the
    # replacement against the on-disk content; for Write we take `content` as-is.
    $proposed = $null
    switch ($toolName) {
        'Write' {
            $proposed = [string]$event.tool_input.content
        }
        'Edit' {
            $existing = ''
            if (Test-Path $filePath) {
                try { $existing = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8) } catch {}
            }
            $oldStr = [string]$event.tool_input.old_string
            $newStr = [string]$event.tool_input.new_string
            $replaceAll = [bool]$event.tool_input.replace_all
            if ([string]::IsNullOrEmpty($oldStr)) { exit 0 }
            if ($replaceAll) {
                $proposed = $existing.Replace($oldStr, $newStr)
            } else {
                $idx = $existing.IndexOf($oldStr)
                if ($idx -lt 0) { exit 0 }  # Edit will fail anyway, let the tool handle it
                $proposed = $existing.Substring(0, $idx) + $newStr + $existing.Substring($idx + $oldStr.Length)
            }
        }
        'MultiEdit' {
            $existing = ''
            if (Test-Path $filePath) {
                try { $existing = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8) } catch {}
            }
            $proposed = $existing
            foreach ($edit in @($event.tool_input.edits)) {
                $oldStr = [string]$edit.old_string
                $newStr = [string]$edit.new_string
                if ([string]::IsNullOrEmpty($oldStr)) { continue }
                if ([bool]$edit.replace_all) {
                    $proposed = $proposed.Replace($oldStr, $newStr)
                } else {
                    $idx = $proposed.IndexOf($oldStr)
                    if ($idx -lt 0) { continue }
                    $proposed = $proposed.Substring(0, $idx) + $newStr + $proposed.Substring($idx + $oldStr.Length)
                }
            }
        }
    }

    if ($null -eq $proposed) { exit 0 }

    $validation = Test-HandoffContent -Content $proposed
    if ($validation.valid) { exit 0 }

    $errLines = ($validation.errors | ForEach-Object { "  - $_" }) -join "`n"

    $template = @"
Required ready.flag schema (raw text — NOT markdown, NOT JSON):

HANDOFF [project: <name>] [parent-session: <uuid>] [created: <ISO-8601>]
task: <1-2 sentences describing what THIS session accomplished, >=20 chars>
spec: <absolute path to authoritative SDD/spec, or 'none'>
resume_prompt: <absolute path to docs/next-session-prompts/*.md, or 'none'>
last_completed: <optional: commit hash, stage label>
next_step: <single concrete imperative action for the child session, >=20 chars>
drafts: <optional: paths to WIP files, or 'none'>
blockers: <optional list, or 'none'>
key_facts: <optional non-obvious learnings, or 'none'>

Rules:
  * First line MUST start with literal 'HANDOFF [project:' — no '#', no '—', no decoration.
  * Field names are lowercase identifier + ':' (e.g. 'task:'), NOT markdown headers ('## task').
  * At least ONE of spec: or resume_prompt: must be a real path (not 'none').
  * Multi-line values are allowed: continuation lines attach to the previous field
    until the next 'field:' token appears.
  * No banned phrases (continue working / finish the task / etc).
"@

    $reason = "Handoff schema validation REFUSED this $toolName to $filePath. The file was NOT written/edited.`n`nErrors:`n$errLines`n`n$template`n`nRewrite the entire content in the schema above and retry."

    $output = @{
        hookSpecificOutput = @{
            hookEventName            = "PreToolUse"
            permissionDecision       = "deny"
            permissionDecisionReason = $reason
        }
    }
    Write-Output ($output | ConvertTo-Json -Compress -Depth 5)
    Write-HandoffWriteGuardLog ("DENIED | $toolName | $filePath | errors: " + ($validation.errors -join '; '))
    exit 0

} catch {
    Write-HandoffWriteGuardLog "EXCEPTION | $($_.Exception.Message)"
    exit 0
}

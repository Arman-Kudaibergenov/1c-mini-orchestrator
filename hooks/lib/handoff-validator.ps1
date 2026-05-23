# Handoff Schema Validator — checks ready.flag content for required fields.
#
# Expected format (raw text, NOT JSON) — pointer-based, not content-duplicating:
#   HANDOFF [project: X] [parent-session: Y] [created: ISO]
#   task:           1-2 sentences, what this session was doing
#   spec:           path to authoritative SDD/spec (or "none")
#   resume_prompt:  path to docs/next-session-prompts/*.md with full plan (or "none")
#   last_completed: short status (commit hash, stage label) — optional
#   next_step:      single concrete imperative action for child
#   drafts:         paths to WIP files in $TEMP/orch-handoff/ (or "none") — optional
#   blockers:       list (or "none") — optional
#   key_facts:      non-obvious learnings child can't infer from spec (or "none") — optional
#
# Validation rules:
#   - `task` and `next_step` required, ≥20 chars (must be meaningful)
#   - At least one of `spec` / `resume_prompt` must be a real path (≠ "none"/empty)
#   - Optional fields: if present, must not be empty (use "none" if N/A)
#
# Multi-line values allowed: continuation lines belong to the previous field
# until the next `field:` token. Field names are case-insensitive.
#
# Returns: @{ valid = $bool; errors = @(string) }

function Test-HandoffContent {
    param([string]$Content)

    $result = @{ valid = $true; errors = @() }

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @{ valid = $false; errors = @('Handoff content is empty') }
    }

    if ($Content -notmatch '(?im)HANDOFF\s*\[project:\s*\S+\]\s*\[parent-session:\s*\S+\]') {
        $result.errors += 'Missing or malformed header: HANDOFF [project: X] [parent-session: Y]'
    }

    # Parse `field: value` pairs with multi-line continuation
    $fields = @{}
    $currentField = $null
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^\s*([a-z_][a-z_0-9]*):\s*(.*)$') {
            $currentField = $matches[1].ToLower()
            $fields[$currentField] = $matches[2]
        } elseif ($currentField -and ($line.Trim() -ne '')) {
            $fields[$currentField] = ($fields[$currentField] + "`n" + $line).Trim()
        }
    }

    # Required meaningful fields (≥20 chars)
    $requiredMeaningful = @('task', 'next_step')
    foreach ($field in $requiredMeaningful) {
        if (-not $fields.ContainsKey($field)) {
            $result.errors += "Missing required field: ${field}:"
            continue
        }
        $value = $fields[$field].Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            $result.errors += "Empty field: ${field}"
            continue
        }
        if ($value.Length -lt 20) {
            $result.errors += "${field} too short ($($value.Length) chars, min 20)"
        }
    }

    # At least one of spec / resume_prompt must point somewhere real
    function Test-IsPointerField {
        param($Fields, [string]$Name)
        if (-not $Fields.ContainsKey($Name)) { return $false }
        $v = $Fields[$Name].Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.ToLower() -eq 'none') { return $false }
        return $true
    }
    $hasSpec   = Test-IsPointerField -Fields $fields -Name 'spec'
    $hasResume = Test-IsPointerField -Fields $fields -Name 'resume_prompt'
    if (-not ($hasSpec -or $hasResume)) {
        $result.errors += "At least one of 'spec:' or 'resume_prompt:' must be a real path (not 'none' or empty). The child session needs an authoritative document to read for full context."
    }

    # Optional fields: if present, must not be empty (but 'none' is OK)
    $optional = @('last_completed', 'drafts', 'blockers', 'key_facts')
    foreach ($field in $optional) {
        if ($fields.ContainsKey($field)) {
            $value = $fields[$field].Trim()
            if ([string]::IsNullOrWhiteSpace($value)) {
                $result.errors += "Optional field '${field}:' is present but empty (use 'none' if N/A)"
            }
        }
    }

    # Cyrillic phrases via char codes — survives ANY encoding mishap on disk
    # or pipe. Parens are mandatory: without them PowerShell parses
    # `[char]+[char], 'next'` as `[char]+[char]+([char], 'next')` and collapses
    # the array to a single space-joined string.
    $banned = @(
        ([string]([char]0x043F + [char]0x0440 + [char]0x043E + [char]0x0434 + [char]0x043E + [char]0x043B + [char]0x0436 + [char]0x0430 + [char]0x0439 + ' ' + [char]0x0440 + [char]0x0430 + [char]0x0431 + [char]0x043E + [char]0x0442 + [char]0x0443)),
        'complete the work',
        'all tasks done',
        'continue working',
        'finish the task',
        ([string]([char]0x043F + [char]0x0440 + [char]0x043E + [char]0x0434 + [char]0x043E + [char]0x043B + [char]0x0436 + [char]0x0438 + [char]0x0442 + [char]0x044C + ' ' + [char]0x0440 + [char]0x0430 + [char]0x0431 + [char]0x043E + [char]0x0442 + [char]0x0443))
    )
    foreach ($phrase in $banned) {
        if ($Content -imatch [regex]::Escape($phrase)) {
            $result.errors += "Banned placeholder phrase: '$phrase'"
        }
    }

    $result.valid = ($result.errors.Count -eq 0)
    return $result
}
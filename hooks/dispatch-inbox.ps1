# dispatch-inbox.ps1 — PostToolUse hook
# Checks for pending dispatch completion messages and surfaces them to Opus.
# Runs async, so does not block tool execution.

$ErrorActionPreference = "SilentlyContinue"

$dbPath = Join-Path $env:USERPROFILE "workspace\external-dispatch-system\data\orch.db"
if (-not (Test-Path $dbPath)) { exit 0 }

# Throttle: only check every 30 seconds
$flagDir = Join-Path $env:TEMP "orch-dispatch"
$lastCheckFile = Join-Path $flagDir "inbox-last-check.txt"
if (Test-Path $lastCheckFile) {
    $lastCheck = [System.IO.File]::ReadAllText($lastCheckFile).Trim()
    try {
        $lastTime = [datetime]::Parse($lastCheck)
        if (((Get-Date) - $lastTime).TotalSeconds -lt 30) { exit 0 }
    } catch {}
}

# Query pending dispatch_completed messages
try {
    $result = & python -c @"
import sqlite3, json, sys, os
db = os.path.expanduser(r'$dbPath')
conn = sqlite3.connect(db)
conn.row_factory = sqlite3.Row
rows = conn.execute(
    "SELECT id, content, dispatch_id FROM orchestrator_messages WHERE type='dispatch_completed' AND state='pending' ORDER BY id ASC LIMIT 5"
).fetchall()
conn.close()
if not rows:
    sys.exit(0)
msgs = []
for r in rows:
    msgs.append(dict(r))
print(json.dumps(msgs, ensure_ascii=False))
"@ 2>$null

    if (-not $result -or $result -eq "null") {
        # Update throttle
        [System.IO.Directory]::CreateDirectory($flagDir) | Out-Null
        [System.IO.File]::WriteAllText($lastCheckFile, (Get-Date -Format "o"))
        exit 0
    }

    $messages = $result | ConvertFrom-Json
    if ($messages.Count -eq 0) {
        [System.IO.Directory]::CreateDirectory($flagDir) | Out-Null
        [System.IO.File]::WriteAllText($lastCheckFile, (Get-Date -Format "o"))
        exit 0
    }

    # Build user-facing notification
    $lines = @()
    $ids = @()
    foreach ($msg in $messages) {
        $content = $msg.content -replace "`n", " | "
        $lines += "[DISPATCH] $content"
        $ids += $msg.id
    }
    $notification = ($lines -join "`n")

    # Output as user_message so Opus sees it
    $hookOutput = @{
        "user_message" = $notification
    } | ConvertTo-Json -Compress
    Write-Output $hookOutput

    # Mark as delivered
    $idList = ($ids -join ",")
    & python -c @"
import sqlite3, os
db = os.path.expanduser(r'$dbPath')
conn = sqlite3.connect(db)
conn.execute(f"UPDATE orchestrator_messages SET state='delivered' WHERE id IN ($idList)")
conn.commit()
conn.close()
"@ 2>$null

} catch {}

# Update throttle
[System.IO.Directory]::CreateDirectory($flagDir) | Out-Null
[System.IO.File]::WriteAllText($lastCheckFile, (Get-Date -Format "o"))

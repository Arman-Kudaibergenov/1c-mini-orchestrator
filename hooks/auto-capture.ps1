# Auto-Capture Hook — PostToolUse
# Silently records significant mutations (Edit, Write, notable Bash) to JSONL buffer.
# Buffer is flushed to RLM during "суммаризируем" ritual.
# Buffer path: $env:USERPROFILE\.claude\orch-autocapture-buffer.jsonl

param()

$ErrorActionPreference = 'SilentlyContinue'

$bufferFile = "$env:USERPROFILE\.claude\orch-autocapture-buffer.jsonl"

try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop

    $toolName = $event.tool_name
    if ([string]::IsNullOrWhiteSpace($toolName)) { exit 0 }

    $entry = $null

    switch ($toolName) {
        "Edit" {
            $filePath = $event.tool_input.file_path
            if ($filePath) {
                $entry = [ordered]@{
                    ts      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
                    tool    = "Edit"
                    file    = $filePath
                    session = $event.session_id
                }
            }
        }
        "Write" {
            $filePath = $event.tool_input.file_path
            if ($filePath) {
                $entry = [ordered]@{
                    ts      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
                    tool    = "Write"
                    file    = $filePath
                    session = $event.session_id
                }
            }
        }
        "Bash" {
            $cmd = $event.tool_input.command
            if ($cmd -match "(git commit|git push|git tag|git merge|npm run build|dotnet build|pytest|cargo build|make |mvn |gradle )") {
                $cmdShort = ($cmd -replace '\s+', ' ').Trim()
                if ($cmdShort.Length -gt 200) { $cmdShort = $cmdShort.Substring(0, 200) + "..." }
                $entry = [ordered]@{
                    ts      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
                    tool    = "Bash"
                    cmd     = $cmdShort
                    session = $event.session_id
                }
            }
        }
    }

    if ($entry) {
        ($entry | ConvertTo-Json -Compress) | Add-Content -Path $bufferFile -Encoding UTF8
    }

} catch {
    # Never block — hook must be silent on error
    exit 0
}

exit 0

# Bash Guard Hook — PreToolUse
# Warns when noisy test commands run without output redirect.
# Prevents large stdout from flooding agent context window.

param()

$ErrorActionPreference = 'SilentlyContinue'

$NOISY_RUNNERS = @('pytest', 'npm test', 'pnpm test', 'go test', 'cargo test', 'dotnet test', 'yarn test')
$REDIRECT_MARKERS = @('>', '| tee', '2>&1')

try {
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $inputData = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputData)) { exit 0 }

    $event = $inputData | ConvertFrom-Json -ErrorAction Stop

    if ($event.tool_name -ne 'Bash') { exit 0 }

    $cmd = $event.tool_input.command
    if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

    # Check if command contains a noisy test runner
    $isNoisy = $false
    foreach ($runner in $NOISY_RUNNERS) {
        if ($cmd -match [regex]::Escape($runner)) {
            $isNoisy = $true
            break
        }
    }
    if (-not $isNoisy) { exit 0 }

    # Check if output is already redirected
    foreach ($marker in $REDIRECT_MARKERS) {
        if ($cmd.Contains($marker)) { exit 0 }
    }

    # Noisy command without redirect — allow with warning
    $output = @{
        hookSpecificOutput = @{
            hookEventName      = "PreToolUse"
            permissionDecision = "allow"
            additionalContext  = "[bash-guard] Test command without redirect detected. Redirect output to avoid flooding context: $cmd > /tmp/test-out.txt 2>&1 && cat /tmp/test-out.txt"
        }
    }
    Write-Output ($output | ConvertTo-Json -Compress -Depth 5)
    exit 0

} catch {
    exit 0
}

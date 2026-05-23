# Session End Hygiene Hook — SessionEnd (async)
# Runs rlm-hygiene.py cleanup at most once per 24 hours.
# Async = does not block session exit.

param()

$ErrorActionPreference = 'SilentlyContinue'

$hygieneScript = $env:ORCH_HYGIENE_SCRIPT
$timestampFile = "$env:TEMP\orch-hygiene-last.txt"
$logFile = "$env:TEMP\orch-hygiene.log"
$cooldownHours = 24

try {
    # ── Throttle: skip if ran recently ──
    if (Test-Path $timestampFile) {
        $lastRun = [System.IO.File]::ReadAllText($timestampFile).Trim()
        $lastDt = [datetime]::Parse($lastRun)
        $elapsed = (Get-Date) - $lastDt
        if ($elapsed.TotalHours -lt $cooldownHours) {
            exit 0
        }
    }

    # ── Check script exists ──
    if (-not (Test-Path $hygieneScript)) {
        exit 0
    }

    # ── Run cleanup ──
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $result = & python $hygieneScript cleanup --execute 2>&1
    $exitCode = $LASTEXITCODE

    # ── Update timestamp ──
    [System.IO.File]::WriteAllText($timestampFile, $ts, [System.Text.Encoding]::UTF8)

    # ── Log ──
    $deletedMatch = $result | Select-String "Удалено\s*:\s*(\d+)"
    $deleted = if ($deletedMatch) { $deletedMatch.Matches[0].Groups[1].Value } else { "?" }
    "$ts | exit=$exitCode | deleted=$deleted" |
        Add-Content $logFile -Encoding UTF8

} catch {
    "$((Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')) | ERROR: $_" |
        Add-Content $logFile -Encoding UTF8
}

exit 0

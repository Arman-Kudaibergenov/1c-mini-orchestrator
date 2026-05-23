# Diagnostic RLM health check — warns user if RLM is unreachable
# This runs AFTER MCP init — it cannot fix missing tools, only inform.
# Fires on SessionStart (startup, clear, resume)
param()
$ErrorActionPreference = 'SilentlyContinue'

$rlmUrl = if ($env:ORCH_RLM_URL) { $env:ORCH_RLM_URL } else { "" }

try {
    $body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"health-check","version":"1.0"}}}'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    $req = [System.Net.HttpWebRequest]::Create($rlmUrl)
    $req.Method = "POST"
    $req.ContentType = "application/json"
    $req.Accept = "application/json"
    $req.Timeout = 5000
    $req.ContentLength = $bytes.Length

    $s = $req.GetRequestStream()
    $s.Write($bytes, 0, $bytes.Length)
    $s.Close()

    $resp = $req.GetResponse()
    $status = [int]$resp.StatusCode
    $resp.Close()

    if ($status -eq 200) {
        exit 0
    }
} catch {
    # RLM unreachable
}

Write-Output "WARNING: RLM MCP is UNREACHABLE. RLM tools will NOT be available this session. Check: see https://github.com/Arman-Kudaibergenov/rlm-workflow for setup"
exit 0

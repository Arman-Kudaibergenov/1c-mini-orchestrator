# RLM Client Library — shared by all hooks
# MCP Streamable HTTP transport: POST to /mcp with JSON responses
# Usage: . "$PSScriptRoot\lib\rlm-client.ps1"

$script:rlmBase = if ($env:ORCH_RLM_URL) { $env:ORCH_RLM_URL.TrimEnd("/mcp").TrimEnd("/") } else { "" }
$script:rlmUrl = "$($script:rlmBase)/mcp"
$script:rlmSessionId = $null

function Initialize-RLMSession {
    if ($script:rlmSessionId) { return $true }

    try {
        $initBody = @{
            jsonrpc = "2.0"
            id      = 1
            method  = "initialize"
            params  = @{
                protocolVersion = "2024-11-05"
                capabilities    = @{}
                clientInfo      = @{ name = "rlm-hook"; version = "2.0" }
            }
        } | ConvertTo-Json -Depth 5

        $req = [System.Net.HttpWebRequest]::Create($script:rlmUrl)
        $req.Method = "POST"
        $req.ContentType = "application/json"
        $req.Accept = "application/json"
        $req.Timeout = 5000

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($initBody)
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream()
        $s.Write($bytes, 0, $bytes.Length)
        $s.Close()

        $resp = $req.GetResponse()
        $script:rlmSessionId = $resp.Headers["Mcp-Session-Id"]
        $resp.Close()
        return ($null -ne $script:rlmSessionId)
    } catch {
        return $false
    }
}

function Invoke-RLM {
    param([string]$ToolName, [hashtable]$Arguments)

    if (-not (Initialize-RLMSession)) { return $false }

    $body = @{
        jsonrpc = "2.0"
        id      = (Get-Random -Maximum 99999)
        method  = "tools/call"
        params  = @{ name = $ToolName; arguments = $Arguments }
    } | ConvertTo-Json -Depth 5

    try {
        $req = [System.Net.HttpWebRequest]::Create($script:rlmUrl)
        $req.Method = "POST"
        $req.ContentType = "application/json"
        $req.Accept = "application/json"
        $req.Headers.Add("Mcp-Session-Id", $script:rlmSessionId)
        $req.Timeout = 5000

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()

        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch {
        return $false
    }
}

function Invoke-RLM-Read {
    param([string]$ToolName, [hashtable]$Arguments)

    if (-not (Initialize-RLMSession)) { return $null }

    $body = @{
        jsonrpc = "2.0"
        id      = (Get-Random -Maximum 99999)
        method  = "tools/call"
        params  = @{ name = $ToolName; arguments = $Arguments }
    } | ConvertTo-Json -Depth 5

    try {
        $req = [System.Net.HttpWebRequest]::Create($script:rlmUrl)
        $req.Method = "POST"
        $req.ContentType = "application/json"
        $req.Accept = "application/json"
        $req.Headers.Add("Mcp-Session-Id", $script:rlmSessionId)
        $req.Timeout = 10000

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()

        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $rawBody = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()

        $parsed = $rawBody | ConvertFrom-Json -ErrorAction Stop
        if ($parsed.result.content) {
            foreach ($block in $parsed.result.content) {
                if ($block.type -eq "text") { return $block.text }
            }
        }
        return $null
    } catch {
        return $null
    }
}

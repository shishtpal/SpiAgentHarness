function Invoke-AgentHarnessMcpRequest {
    param([hashtable]$Connection, [string]$Method, [hashtable]$Parameters = @{}, [switch]$Notification)

    $ErrorActionPreference = 'Stop'
    if ($Connection.Closed) { throw 'MCP connection is closed. Start a new harness invocation to reconnect.' }
    $Connection.NextId++
    $message = @{ jsonrpc = '2.0'; method = $Method; params = $Parameters.Clone() }
    if (-not $Notification) { $message.id = $Connection.NextId }
    if ($Connection.ProtocolVersion -eq '2026-07-28') {
        $message.params['_meta'] = @{
            'io.modelcontextprotocol/protocolVersion' = $Connection.ProtocolVersion
            'io.modelcontextprotocol/clientInfo' = @{ name = 'SpiAgentHarness'; version = '1.0.0' }
            'io.modelcontextprotocol/clientCapabilities' = @{}
        }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Connection.Transport -eq 'stdio') {
            $json = $message | ConvertTo-Json -Depth 100 -Compress
            Wait-AgentHarnessMcpTask -Task ($Connection.Process.StandardInput.WriteLineAsync($json)) -Timer $timer -TimeoutSec $Connection.TimeoutSec | Out-Null
            Wait-AgentHarnessMcpTask -Task ($Connection.Process.StandardInput.FlushAsync()) -Timer $timer -TimeoutSec $Connection.TimeoutSec | Out-Null
            if ($Notification) { return }
            $response = Read-AgentHarnessMcpResponse -Reader $Connection.Reader -Connection $Connection -Id $message.id -Timer $timer
        }
        else {
            $response = Invoke-AgentHarnessMcpHttp -Connection $Connection -Message $message -Timer $timer -Notification:$Notification
            if ($Notification) { return }
        }
        if ($response.ContainsKey('error')) {
            if ($response.error -isnot [hashtable] -or $response.error.code -isnot [ValueType] -or
                $response.error.code -is [bool] -or [double]$response.error.code -lt [int]::MinValue -or
                [double]$response.error.code -gt [int]::MaxValue -or [double]$response.error.code -ne [Math]::Truncate([double]$response.error.code)) {
                throw 'Invalid MCP error code.'
            }
            # Server error messages/data can echo authentication. Only expose the code.
            $code = [int]$response.error.code
            $ex = [Exception]::new("MCP '$($Connection.Name)' request '$Method' failed (JSON-RPC $code).")
            $ex.Data['McpCode'] = $code
            if ($response.__HttpStatus) { $ex.Data['HttpStatus'] = $response.__HttpStatus }
            if ($response.error.data.supported) { $ex.Data['SupportedVersions'] = $response.error.data.supported }
            throw $ex
        }
        if (-not $response.ContainsKey('result') -or $response.result -isnot [hashtable]) { throw 'MCP response must contain a result object.' }
        return $response.result
    }
    catch {
        if (-not $_.Exception.Data.Contains('McpCode') -and -not $_.Exception.Data.Contains('HttpStatus')) {
            if ($Connection.Transport -eq 'stdio' -and $_.Exception -is [TimeoutException]) {
                try {
                    $cancelMessage = @{ jsonrpc = '2.0'; method = 'notifications/cancelled'; params = @{ requestId = $message.id; reason = 'Request deadline exceeded.' } } | ConvertTo-Json -Compress
                    $cancelTask = $Connection.Process.StandardInput.WriteLineAsync($cancelMessage)
                    $null = $cancelTask.Wait(100)
                }
                catch { }
            }
            # A timed-out or malformed stream cannot safely be reused.
            Close-AgentHarnessMcpConnection -Connection $Connection
            throw "MCP '$($Connection.Name)' transport failed; the connection was closed. Calls are not retried."
        }
        throw
    }
    finally { $timer.Stop() }
}
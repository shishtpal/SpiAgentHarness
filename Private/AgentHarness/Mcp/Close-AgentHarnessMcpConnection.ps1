function Close-AgentHarnessMcpConnection {
    param([hashtable]$Connection)

    if (-not $Connection -or $Connection.Closed) { return }
    $Connection.Closed = $true
    if ($Connection.Process) {
        try { $Connection.Process.StandardInput.Close() } catch { }
        try {
            if (-not $Connection.Process.WaitForExit(500)) {
                $Connection.Process.Kill($true)
                $null = $Connection.Process.WaitForExit(1000)
            }
        }
        catch { } # Cleanup must not replace the original failure or user interruption.
        finally { $Connection.Process.Dispose() }
    }
    if ($Connection.HttpClient) {
        # Release legacy HTTP sessions, without allowing teardown to hold up exit.
        if ($Connection.SessionId) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Delete, $Connection.Url)
            try {
                foreach ($key in $Connection.Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($key, [string]$Connection.Headers[$key]) }
                $null = $request.Headers.TryAddWithoutValidation('Mcp-Session-Id', $Connection.SessionId)
                $null = $request.Headers.TryAddWithoutValidation('MCP-Protocol-Version', $Connection.ProtocolVersion)
                $cancel = [Threading.CancellationTokenSource]::new(1000)
                try {
                    $response = $Connection.HttpClient.SendAsync($request, $cancel.Token).GetAwaiter().GetResult()
                    $response.Dispose()
                }
                finally { $cancel.Dispose() }
            }
            catch { }
            finally { $request.Dispose() }
        }
        $Connection.HttpClient.Dispose()
    }
}
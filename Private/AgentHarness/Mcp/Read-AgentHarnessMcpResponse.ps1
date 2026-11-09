function Read-AgentHarnessMcpResponse {
    param(
        $Reader, [hashtable]$Connection, [object]$Id,
        [Diagnostics.Stopwatch]$Timer, [switch]$Sse
    )

    $size = 0
    $eventData = [Collections.Generic.List[string]]::new()
    while ($true) {
        $line = Wait-AgentHarnessMcpTask -Task ($Reader.ReadLineAsync()) -Timer $Timer -TimeoutSec $Connection.TimeoutSec
        if ($null -eq $line) { throw 'MCP connection ended before a matching response arrived.' }
        $size += $line.Length
        if ($size -gt $Connection.MaxResponseChars) { throw 'MCP response exceeded MaxResponseChars.' }
        if ($Sse) {
            if ($line.StartsWith('data:')) {
                $eventData.Add($line.Substring(5).TrimStart(' '))
                continue
            }
            if ($line.Length -or -not $eventData.Count) { continue }
            $line = $eventData -join "`n"
            $eventData.Clear()
        }
        elseif ([string]::IsNullOrWhiteSpace($line)) { continue }

        $message = ConvertFrom-Json -InputObject $line -AsHashtable -NoEnumerate -ErrorAction Stop
        if ($message -isnot [hashtable] -or $message.jsonrpc -cne '2.0') { throw 'Invalid MCP JSON-RPC response.' }
        if ($message.ContainsKey('method')) {
            if ($message.ContainsKey('id')) {
                # No sampling, roots, or elicitation capability is advertised. Reject unsolicited requests.
                $reply = @{ jsonrpc = '2.0'; id = $message.id; error = @{ code = -32601; message = 'Client method not supported.' } }
                if ($Connection.Transport -eq 'stdio') {
                    Wait-AgentHarnessMcpTask -Task ($Connection.Process.StandardInput.WriteLineAsync(($reply | ConvertTo-Json -Depth 20 -Compress))) -Timer $Timer -TimeoutSec $Connection.TimeoutSec | Out-Null
                    Wait-AgentHarnessMcpTask -Task ($Connection.Process.StandardInput.FlushAsync()) -Timer $Timer -TimeoutSec $Connection.TimeoutSec | Out-Null
                }
                else {
                    Invoke-AgentHarnessMcpHttp -Connection $Connection -Message $reply -Timer $Timer -Notification | Out-Null
                }
            }
            continue
        }
        if (-not ($message.ContainsKey('error') -and $null -eq $message.id) -and
            (-not $message.ContainsKey('id') -or [string]$message.id -cne [string]$Id -or ($message.id -is [string]) -ne ($Id -is [string]))) { continue }
        return $message
    }
}
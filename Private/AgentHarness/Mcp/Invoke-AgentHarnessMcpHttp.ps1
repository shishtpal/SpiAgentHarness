function Invoke-AgentHarnessMcpHttp {
    param([hashtable]$Connection, [hashtable]$Message, [Diagnostics.Stopwatch]$Timer, [switch]$Notification)

    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $Connection.Url)
    $response = $null; $reader = $null
    $remaining = [Math]::Max(1, [Math]::Min([int]::MaxValue, ($Connection.TimeoutSec * 1000.0 - $Timer.Elapsed.TotalMilliseconds)))
    $cancel = [Threading.CancellationTokenSource]::new([int]$remaining)
    try {
        foreach ($key in $Connection.Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($key, [string]$Connection.Headers[$key]) }
        $null = $request.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream')
        $null = $request.Headers.TryAddWithoutValidation('MCP-Protocol-Version', $Connection.ProtocolVersion)
        if ($Connection.SessionId) { $null = $request.Headers.TryAddWithoutValidation('Mcp-Session-Id', $Connection.SessionId) }
        if ($Connection.ProtocolVersion -eq '2026-07-28') {
            $null = $request.Headers.TryAddWithoutValidation('Mcp-Method', $Message.method)
            if ($Message.method -eq 'tools/call') {
                # Exported names can differ; the original tool name is mirrored on the wire.
                $value = ConvertTo-AgentHarnessMcpHeaderValue ([string]$Message.params.name)
                $null = $request.Headers.TryAddWithoutValidation('Mcp-Name', $value)
                foreach ($mapping in $Connection.ToolHeaders[[string]$Message.params.name]) {
                    $value = $Message.params.arguments
                    $present = $true
                    foreach ($part in $mapping.Path) {
                        if ($value -isnot [Collections.IDictionary] -or -not $value.Contains($part)) { $present = $false; break }
                        $value = $value[$part]
                    }
                    if ($present -and $null -ne $value) {
                        if (($mapping.Type -eq 'string' -and $value -isnot [string]) -or
                            ($mapping.Type -eq 'boolean' -and $value -isnot [bool]) -or
                            ($mapping.Type -eq 'integer' -and ($value -isnot [ValueType] -or $value -is [bool] -or [Math]::Abs([double]$value) -gt 9007199254740991 -or [double]$value -ne [Math]::Truncate([double]$value)))) {
                            throw 'Invalid value for an MCP header parameter.'
                        }
                        $encoded = ConvertTo-AgentHarnessMcpHeaderValue -Value ($value | ConvertTo-Json -Compress -Depth 10) -Json
                        $null = $request.Headers.TryAddWithoutValidation(('Mcp-Param-' + $mapping.Name), $encoded)
                    }
                }
            }
        }
        $request.Content = [Net.Http.StringContent]::new(($Message | ConvertTo-Json -Depth 100 -Compress), [Text.Encoding]::UTF8, 'application/json')
        $response = Wait-AgentHarnessMcpTask -Task ($Connection.HttpClient.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token)) -Timer $Timer -TimeoutSec $Connection.TimeoutSec
        if ($response.Headers.Contains('Mcp-Session-Id') -and $Connection.ProtocolVersion -ne '2026-07-28') {
            $Connection.SessionId = @($response.Headers.GetValues('Mcp-Session-Id'))[0]
        }
        if ($Notification) {
            if (-not $response.IsSuccessStatusCode) { throw "MCP HTTP status $([int]$response.StatusCode)." }
            return
        }
        $type = $response.Content.Headers.ContentType.MediaType
        if ($type -notin 'application/json', 'text/event-stream') {
            $ex = [Exception]::new("MCP HTTP status $([int]$response.StatusCode), unsupported response content type.")
            $ex.Data['HttpStatus'] = [int]$response.StatusCode
            throw $ex
        }
        $stream = Wait-AgentHarnessMcpTask -Task ($response.Content.ReadAsStreamAsync()) -Timer $Timer -TimeoutSec $Connection.TimeoutSec
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        if ($type -eq 'text/event-stream') {
            $boundedReader = New-AgentHarnessMcpReader -Reader $reader -MaxResponseChars $Connection.MaxResponseChars
            $result = Read-AgentHarnessMcpResponse -Reader $boundedReader -Connection $Connection -Id $Message.id -Timer $Timer -Sse
        }
        else {
            # Read in bounded chunks; do not buffer an arbitrary HTTP body.
            $buffer = [char[]]::new(4096)
            $text = [Text.StringBuilder]::new()
            while ($true) {
                $count = Wait-AgentHarnessMcpTask -Task ($reader.ReadAsync($buffer, 0, $buffer.Length)) -Timer $Timer -TimeoutSec $Connection.TimeoutSec
                if (-not $count) { break }
                if ($text.Length + $count -gt $Connection.MaxResponseChars) { throw 'MCP response exceeded MaxResponseChars.' }
                $null = $text.Append($buffer, 0, $count)
            }
            try { $result = ConvertFrom-Json -InputObject $text.ToString() -AsHashtable -NoEnumerate -ErrorAction Stop }
            catch {
                if ([int]$response.StatusCode -ne 400 -or $Message.method -ne 'server/discover') { throw }
                $ex = [Exception]::new('MCP HTTP discovery received a non-protocol 400 response.')
                $ex.Data['HttpStatus'] = 400
                throw $ex
            }
            $unidentifiedError = $result -is [hashtable] -and $result.ContainsKey('error') -and $null -eq $result.id
            if ($result -isnot [hashtable] -or $result.jsonrpc -cne '2.0' -or (-not $unidentifiedError -and
                ([string]$result.id -cne [string]$Message.id -or ($result.id -is [string]) -ne ($Message.id -is [string])))) { throw 'Invalid MCP HTTP JSON-RPC response.' }
        }
        if (-not $response.IsSuccessStatusCode -and -not $result.ContainsKey('error')) { throw "MCP HTTP status $([int]$response.StatusCode)." }
        if (-not $response.IsSuccessStatusCode) { $result['__HttpStatus'] = [int]$response.StatusCode }
        return $result
    }
    finally {
        $cancel.Cancel()
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $cancel.Dispose()
    }
}
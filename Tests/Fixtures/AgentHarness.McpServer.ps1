#requires -Version 7.0
param(
    [ValidateSet('stdio', 'http')][string]$Transport = 'stdio',
    [string]$Mode = 'legacy', [string]$LogPath, [string]$ReadyPath, [int]$Port
)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$initialized = $false
$callCount = 0
$listener = $null

function Get-FixtureReply {
    param([hashtable]$Message)
    [IO.File]::AppendAllText($LogPath, (($Message | ConvertTo-Json -Compress -Depth 100) + "`n"))
    if (-not $Message.ContainsKey('method') -or -not $Message.ContainsKey('id')) { return }
    $reply = @{ jsonrpc = '2.0'; id = $Message.id }
    switch ($Message.method) {
        'server/discover' {
            if ($Mode -eq 'legacy') { $reply.error = @{ code = -32601; message = 'Not supported' } }
            elseif ($Mode -eq 'reject-version') { $reply.error = @{ code = -32022; message = 'Unsupported version'; data = @{ supported = @('2099-01-01') } } }
            else { $reply.result = @{ supportedVersions = @('2026-07-28'); capabilities = @{ tools = @{} }; serverInfo = @{ name = 'fixture'; version = '1' } } }
        }
        'initialize' {
            $script:initialized = $true
            $reply.result = @{ protocolVersion = $Message.params.protocolVersion; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'fixture'; version = '1' } }
        }
        'tools/list' {
            $schema = @{ type = 'object'; properties = @{ text = @{ type = 'string' }; values = @{ type = 'array'; items = @{ type = 'string' } } } }
            if ($Mode -eq 'gateway') {
                $reply.result = @{ tools = @(
                    @{ name = 'search_tool'; description = 'Discover underlying tools'; inputSchema = $schema },
                    @{ name = 'call_tool'; description = 'Execute an underlying tool'; inputSchema = $schema }
                ) }
            }
            elseif ($Message.params.cursor) {
                $reply.result = @{ tools = @(@{ name = 'structured'; description = 'Structured output'; inputSchema = $schema }) }
                if ($Mode -eq 'cursor') { $reply.result.nextCursor = 'page2' }
            }
            else {
                $tools = @('echo', 'Search', 'search', 'namespace/tool', ('long_' + ('x' * 90)), 'fail', 'rpcfail', 'sleep', 'disconnect', 'oversize', 'malformed', 'client_request') | ForEach-Object {
                    @{ name = $_; description = 'Synthetic tool'; inputSchema = $schema }
                }
                $headerSchema = @{ type = 'object'; properties = @{ context = @{ type = 'object'; properties = @{ region = @{ type = 'string'; 'x-mcp-header' = 'Region' } } } } }
                $tools += @{ name = 'headers'; description = 'Header mapping'; inputSchema = $headerSchema }
                if ($Mode -eq 'bad-header') { $tools += @{ name = 'badheader'; inputSchema = @{ type = 'object'; properties = @{ region = @{ type = 'string'; 'x-mcp-header' = "invalid`nheader" } } } } }
                $reply.result = @{ tools = @($tools); nextCursor = 'page2' }
            }
        }
        'tools/call' {
            $script:callCount++
            switch ($Message.params.name) {
                'sleep' { Start-Sleep -Seconds 5; $reply.result = @{ content = @(@{ type = 'text'; text = 'late' }) } }
                'disconnect' { exit 0 }
                'oversize' { $reply.result = @{ content = @(@{ type = 'text'; text = ('x' * 20000) }) } }
                'malformed' { return 'not json' }
                'structured' { $reply.result = @{ content = @(@{ type = 'text'; text = 'structured result' }, @{ type = 'audio'; data = 'SYNTHETIC'; mimeType = 'audio/wav' }); structuredContent = @{ ok = $true; values = @(1, 2) } } }
                'fail' { $reply.result = @{ isError = $true; content = @(@{ type = 'text'; text = 'synthetic tool failure' }) } }
                'rpcfail' { $reply.error = @{ code = -32602; message = 'Do not echo secret-test-value'; data = @{ secret = 'secret-test-value' } } }
                default {
                    $text = @{ name = $Message.params.name; arguments = $Message.params.arguments; calls = $script:callCount; pid = $PID; cwd = (Get-Location).Path; environment = $env:SPI_MCP_FIXTURE_VALUE } | ConvertTo-Json -Depth 100 -Compress
                    $reply.result = @{ content = @(@{ type = 'text'; text = $text }) }
                }
            }
        }
        default { $reply.error = @{ code = -32601; message = 'Not supported' } }
    }
    return ($reply | ConvertTo-Json -Depth 100 -Compress)
}

try {
    if ($Transport -eq 'stdio') {
        # Larger than a typical OS pipe buffer: client must drain concurrently.
        [Console]::Error.Write(('diagnostic noise ' * 8000))
        if ($ReadyPath) { [IO.File]::WriteAllText($ReadyPath, [string]$PID) }
        while ($null -ne ($line = [Console]::ReadLine())) {
            $message = ConvertFrom-Json -InputObject $line -AsHashtable -NoEnumerate
            if ($message.method -eq 'tools/call') {
                [Console]::WriteLine('{"jsonrpc":"2.0","method":"notifications/message","params":{"data":"fixture notice"}}')
                [Console]::WriteLine('{"jsonrpc":"2.0","id":"unrelated","result":{}}')
                if ($message.params.name -eq 'client_request') { [Console]::WriteLine('{"jsonrpc":"2.0","id":"server_request","method":"sampling/createMessage","params":{}}') }
            }
            $reply = Get-FixtureReply $message
            if ($reply) { [Console]::WriteLine($reply) }
        }
    }
    else {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        [IO.File]::WriteAllText($ReadyPath, [string]$PID)
        while ($true) {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $false, 4096, $true)
            try {
                $requestLine = $reader.ReadLine()
                $headers = @{}
                while ($line = $reader.ReadLine()) {
                    $pair = $line.Split(':', 2); $headers[$pair[0]] = $pair[1].Trim()
                }
                if ($requestLine.StartsWith('DELETE ')) {
                    [IO.File]::AppendAllText($LogPath, '{"delete":true}' + "`n")
                    $body = ''; $status = '204 No Content'; $type = 'application/json'
                }
                else {
                    $buffer = [char[]]::new([int]$headers['Content-Length'])
                    $read = 0
                    while ($read -lt $buffer.Length) { $count = $reader.Read($buffer, $read, $buffer.Length - $read); if (-not $count) { throw 'Unexpected EOF' }; $read += $count }
                    $message = ConvertFrom-Json -InputObject (-join $buffer) -AsHashtable -NoEnumerate
                    $message['fixtureHeaders'] = $headers
                    $body = Get-FixtureReply $message
                    $status = '200 OK'; $type = 'application/json'
                    if (-not $body) { $status = '202 Accepted'; $body = '' }
                    elseif ($Mode -eq 'sse' -or $message.method -eq 'tools/call') {
                        $type = 'text/event-stream'
                        $body = ": comment`n`ndata: {`"jsonrpc`":`"2.0`",`"method`":`"notifications/message`",`"params`":{}}`n`ndata: $body`n`n"
                    }
                }
                $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                $sessionHeader = if ($Mode -eq 'legacy') { "Mcp-Session-Id: fixture-session`r`n" } else { '' }
                $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: $type`r`nContent-Length: $($bytes.Length)`r`n${sessionHeader}Connection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
            }
            catch { } # Clients intentionally disconnect in timeout and malformed-response tests.
            finally { $reader.Dispose(); $stream.Dispose(); $client.Dispose() }
        }
    }
}
finally { if ($listener) { $listener.Stop() } }
# The real HttpClient request, SSE parser and accumulator run against an in-memory handler.
# No sockets, user configuration, skills or live provider are used.
Add-Type -Path (Join-Path $PSScriptRoot 'Fixtures/ChatStreamingHandler.cs') -ErrorAction Stop
$savedStreamingRequest = & $module { ${function:Invoke-AgentHarnessChatRequest} }
$savedStreamingClient = & $module { ${function:New-AgentHarnessChatClient} }

function New-StreamingEvent {
    param([hashtable]$Delta = @{}, [object]$Finish = $null)
    'data: ' + (ConvertTo-Json -InputObject @{ choices = @(@{ index = 0; delta = $Delta; finish_reason = $Finish }) } -Depth 20 -Compress) + "`n`n"
}

function New-StreamingResponse {
    param([string]$Text = 'streamed answer')
    (New-StreamingEvent @{ role = 'assistant'; content = $Text }) + (New-StreamingEvent @{} stop) + "data: [DONE]`n`n"
}

function Set-StreamingResponses {
    param([object[]]$Responses)
    $script:streamHandler = [SpiAgentHarness.Tests.ChatHandler]::new()
    foreach ($item in $Responses) {
        $response = [SpiAgentHarness.Tests.ChatResponse]::new()
        if ($item -is [string]) { $response.Body = $item }
        else { foreach ($key in $item.Keys) { $response.$key = $item[$key] } }
        $script:streamHandler.Responses.Enqueue($response)
    }
    & $module { param($handler) $script:StreamingHandler = $handler; $script:Delays.Clear() } $script:streamHandler
}

function Invoke-StreamingChat {
    param([scriptblock]$OnText, [int]$Timeout = 5)
    & $module {
        param($callback, $timeout)
        Invoke-AgentHarnessChat -Uri https://provider.invalid/chat -Body @{ model = 'synthetic'; messages = @() } -TimeoutSec $timeout -Stream -OnText $callback
    } $OnText $Timeout
}

function Get-StreamingFailure {
    param([scriptblock]$Action)
    $caught = $null
    try { $null = & $Action } catch { $caught = $_ }
    Assert-Harness ($null -ne $caught) "Streaming failure is terminating: $($Action.ToString().Trim())"
    $caught
}

try {
    & $module {
        param($path)
        . $path
        $real = ${function:Invoke-AgentHarnessChatRequest}
        Set-Item Function:script:Invoke-AgentHarnessChatRequest -Value $real
        function script:New-AgentHarnessChatClient {
            $client = [Net.Http.HttpClient]::new($script:StreamingHandler, $false)
            $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
            $client
        }
    } (Join-Path $fixture 'Private/AgentHarness/Streaming/Invoke-AgentHarnessChatRequest.ps1')

    $streamOptions = @{ Model = 'stream-model'; ChatUri = 'https://provider.invalid/chat'; WorkingDirectory = $fixture; NoAgentsFile = $true; NoBuiltinTools = $true; NoPromptHistory = $true; NoModelRecovery = $true; NoPromptSound = $true }
    Set-StreamingResponses @((New-StreamingResponse 'Hello 🌍'))
    $captured = @(Invoke-AgentHarness 'Synthetic streaming task' @streamOptions -PassThru -InformationVariable streamInfo 6>$null)
    $request = ConvertFrom-Json -InputObject $streamHandler.Bodies[0]
    Assert-Harness ($captured.Count -eq 1 -and $captured[0].Answer -ceq 'Hello 🌍') 'Live text does not leak into the success pipeline or PassThru'
    Assert-Harness ($request.stream -eq $true -and $request.stream_options.include_usage -eq $true) 'Streaming is requested by default with usage reporting'
    Assert-Harness (($streamInfo -join '') -like '*Hello*🌍*') 'UTF-8 split across individual bytes reaches live information output'
    Assert-Harness ($streamHandler.Streams[0].Disposed) 'Completed HTTP response stream is disposed'

    # The next read fails unless the first content callback has already run.
    $first = New-StreamingEvent @{ content = 'first' }
    Set-StreamingResponses @(@{ Body = $first + (New-StreamingEvent @{ content = 'second' } stop) + "data: [DONE]`n`n"; ReadSize = 4096; GateAt = [Text.Encoding]::UTF8.GetByteCount($first) })
    $live = [Collections.Generic.List[string]]::new()
    $handlerForCallback = $streamHandler
    $callback = { param($text) $live.Add($text); $handlerForCallback.Streams[0].Released = $true; 'callback output must be discarded' }.GetNewClosure()
    $response = Invoke-StreamingChat -OnText $callback
    Assert-Harness ($response.choices[0].message.content -ceq 'firstsecond' -and ($live -join ',') -ceq 'first,second') 'Content is delivered before the remaining response is read and callback output is discarded'

    Set-StreamingResponses @((New-StreamingResponse 'quiet answer'))
    $quietResult = Invoke-AgentHarness 'Quiet task' @streamOptions -Quiet -InformationVariable quietStreamInfo 6>$null
    Assert-Harness ($quietResult -ceq 'quiet answer' -and @($quietStreamInfo).Count -eq 0) 'Quiet suppresses live display while preserving one final answer'
    Assert-Harness ((ConvertFrom-Json -InputObject $streamHandler.Bodies[0]).stream) 'Quiet still requests streaming'

    Set-HarnessResponses @((New-HarnessResponse 'buffered answer'))
    $buffered = Invoke-AgentHarness 'Buffered task' @streamOptions -NoStream -Quiet
    $bufferedRequest = @(Get-HarnessRequests)[0]
    Assert-Harness ($buffered -ceq 'buffered answer' -and -not $bufferedRequest.Body.PSObject.Properties['stream']) 'NoStream uses the buffered request without streaming fields'
    Assert-Harness ($streamHandler.Bodies.Count -eq 1) 'NoStream never opens an HttpClient request'

    Set-StreamingResponses @(@{ Body = (New-HarnessResponse 'JSON fallback' | ConvertTo-Json -Depth 20 -Compress); MediaType = 'application/json' })
    Assert-Harness ((Invoke-AgentHarness 'JSON endpoint' @streamOptions -Quiet) -ceq 'JSON fallback') 'A provider that ignores stream=true can return a completed JSON response'

    $wire = ": heartbeat`r`revent: message`rdata: {`rdata: " + '"choices":[{"index":0,"delta":{"content":"framed"},"finish_reason":"stop"}]}' + "`r`rdata: [DONE]`r`r"
    Set-StreamingResponses @($wire)
    Assert-Harness ((Invoke-StreamingChat).choices[0].message.content -ceq 'framed') 'SSE comments, CR line endings and multiline data fields are parsed'
    Set-StreamingResponses @((New-StreamingResponse 'CRLF').Replace("`n", "`r`n"))
    Assert-Harness ((Invoke-StreamingChat).choices[0].message.content -ceq 'CRLF') 'CRLF boundaries split across reads are parsed'

    $toolWire = New-StreamingEvent @{ reasoning_content = 'private synthetic reasoning'; tool_calls = @(@{ index = 1; id = 'call_b'; type = 'function'; function = @{ name = 'ec'; arguments = '{"items":' } }, @{ index = 0; id = 'call_a'; type = 'function'; function = @{ name = 'echo'; arguments = '{"items":' } }) }
    $toolWire += New-StreamingEvent @{ tool_calls = @(@{ index = 0; function = @{ arguments = '[]}' } }, @{ index = 1; function = @{ name = 'ho'; arguments = '["b"]}' } }) } tool_calls
    $toolWire += 'data: {"model":"served-stream-model","choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7}}' + "`n`ndata: [DONE]`n`n"
    Set-StreamingResponses @($toolWire, (New-StreamingResponse 'tools done'))
    $streamToolCounter = @{ Count = 0 }
    $streamTools = @{ echo = @{ Parameters = @{ type = 'object'; properties = @{ items = @{ type = 'array'; items = @{ type = 'string' } } } }; Script = { param($a, $ctx) $streamToolCounter.Count++; 'synthetic tool result' }.GetNewClosure() } }
    $toolRun = Invoke-AgentHarness 'Tool streaming task' @streamOptions -Tools $streamTools -Quiet -PassThru
    $toolMessage = @($toolRun.Messages | Where-Object { $_.role -eq 'assistant' -and $_.tool_calls.Count })[0]
    Assert-Harness ($streamToolCounter.Count -eq 2 -and $toolRun.Answer -ceq 'tools done') 'Complete interleaved tool calls execute once each before the next streamed turn'
    Assert-Harness (($toolMessage.tool_calls.id -join ',') -ceq 'call_a,call_b' -and $toolMessage.tool_calls[0].function.arguments -ceq '{"items":[]}') 'Tool indexes determine order and JSON argument arrays retain their shape'
    Assert-Harness ($toolRun.PromptTokens -eq 11 -and $toolRun.CompletionTokens -eq 7) 'Final usage-only chunk contributes token accounting'

    Set-StreamingResponses @(@{ Status = 503 }, (New-StreamingResponse 'retried'))
    Assert-Harness ((Invoke-StreamingChat).choices[0].message.content -ceq 'retried') 'Retryable HTTP status before deltas retains retry behavior'
    Assert-Harness ($streamHandler.Bodies.Count -eq 2 -and ((& $module { $script:Delays.ToArray() }) -join ',') -ceq '2') 'HTTP retry uses the existing delay policy'
    Assert-Harness (@($streamHandler.Streams | Where-Object { -not $_.Disposed }).Count -eq 0) 'Failed HTTP attempts also dispose streams'
    Set-StreamingResponses @(('data: {"error":{"code":503,"message":"synthetic error"}}' + "`n`n"), (New-StreamingResponse 'event retry'))
    Assert-Harness ((Invoke-StreamingChat).choices[0].message.content -ceq 'event retry') 'An SSE API error before deltas retains retryable status'
    Set-StreamingResponses @(@{ Status = 503 }, @{ Status = 503 }, @{ Status = 503 }, @{ Status = 503 })
    $failure = Get-StreamingFailure { Invoke-StreamingChat }
    Assert-Harness ($failure.Exception.Data['Status'] -eq 503 -and $streamHandler.Bodies.Count -eq 4 -and ((& $module { $script:Delays.ToArray() }) -join ',') -ceq '2,4,8') 'Streaming retains the four-attempt retry limit and status metadata'
    Set-StreamingResponses @(@{ Status = 401 })
    $failure = Get-StreamingFailure { Invoke-StreamingChat }
    Assert-Harness ($failure.Exception.Data['Status'] -eq 401 -and $streamHandler.Bodies.Count -eq 1) 'Authentication failures preserve status without transport retries'
    Set-StreamingResponses @(@{ Status = 400; MediaType = 'application/json'; Body = '{"error":{"code":"context_length_exceeded","message":"maximum context window exceeded"}}' })
    $failure = Get-StreamingFailure { Invoke-StreamingChat }
    $isContextLength = & $module { param($errorRecord) Invoke-AgentHarnessCompaction -Classify -Failure $errorRecord } $failure
    Assert-Harness ($failure.Exception.Data['Status'] -eq 400 -and $isContextLength) 'Streaming HTTP errors retain context-length compaction classification'

    foreach ($preference in 'Continue', 'Stop') {
        $truncated = (New-StreamingEvent @{ content = 'partial answer'; tool_calls = @(@{ index = 0; id = 'partial'; function = @{ name = 'echo'; arguments = '{"items":' } }) })
        Set-StreamingResponses @(@{ Body = $truncated; FaultAtEnd = $true }, (New-StreamingResponse 'must not retry'))
        $failure = $null
        try { $null = Invoke-AgentHarness 'Interrupted task' @streamOptions -NoModelRecovery:$false -Tools $streamTools -SaveContextOnFailure -ErrorAction $preference -InformationVariable interruptedInfo 6>$null 3>$null }
        catch { $failure = $_ }
        Assert-Harness ($null -ne $failure) 'Interrupted public streaming request throws'
        Assert-Harness ($failure.Exception.Data['StreamStarted'] -and $failure.Exception.Message -like '*Partial output was not saved*') 'Partial stream failure is explicit under either error preference'
        Assert-Harness ($streamHandler.Bodies.Count -eq 1 -and $streamToolCounter.Count -eq 2) 'Interrupted streamed response bypasses retries, model recovery and tool execution'
        $recovered = Get-Content -LiteralPath $failure.Exception.Data['RecoveryContextPath'] -Raw | ConvertFrom-Json
        Assert-Harness (-not @($recovered.messages | Where-Object role -eq assistant).Count) 'Recovery context excludes unfinished assistant text and tool calls'
        Assert-Harness (($interruptedInfo -join '') -like '*partial answer*') 'Provisional text was displayed before the disconnect'
    }

    $invalidCases = @(
        @{ Body = New-StreamingEvent @{ content = 'unfinished' }; Started = $true },
        @{ Body = (New-StreamingEvent @{ content = 'x' } stop) + 'data: [DONE]'; Started = $true },
        @{ Body = "data: not-json`n`n"; Started = $false },
        @{ Body = "data: []`n`n"; Started = $false },
        @{ Body = "data: 7`n`n"; Started = $false },
        @{ Body = 'data: {"choices":{}}' + "`n`n"; Started = $false },
        @{ Body = "data: [DONE]`n`n"; Started = $false },
        @{ Body = (New-StreamingEvent @{ tool_calls = @(@{ index = 0; id = 'bad'; function = @{ name = 'echo'; arguments = '[{}]' } }) } tool_calls) + "data: [DONE]`n`n"; Started = $true },
        @{ Body = (New-StreamingEvent @{ tool_calls = @(@{ index = 0; id = 'bad'; function = @{ name = 'echo'; arguments = '{' } }) } tool_calls) + "data: [DONE]`n`n"; Started = $true },
        @{ Body = (New-StreamingEvent @{ tool_calls = @(@{ index = 0; id = 'bad'; function = @{ name = 'echo'; arguments = '{}' } }) } length) + "data: [DONE]`n`n"; Started = $true }
    )
    $caseNumber = 0
    foreach ($case in $invalidCases) {
        $caseNumber++
        Set-StreamingResponses @($case.Body)
        $failure = $null
        try { $null = Invoke-StreamingChat } catch { $failure = $_ }
        Assert-Harness ($null -ne $failure) "Invalid streaming case $caseNumber throws"
        Assert-Harness ([bool]$failure.Exception.Data['StreamStarted'] -eq $case.Started -and $streamHandler.Bodies.Count -eq 1) 'Malformed, incomplete or truncated stream cannot produce a completed response or replay partial output'
        Assert-Harness ($streamHandler.Streams[0].Disposed) 'Protocol failure disposes the stream'
    }

    foreach ($body in '', (New-StreamingEvent @{ content = 'stalled' })) {
        Set-StreamingResponses @(@{ Body = $body; StallAtEnd = $true })
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $failure = Get-StreamingFailure { Invoke-StreamingChat -Timeout 1 }
        Assert-Harness ($deadline.Elapsed.TotalSeconds -lt 4 -and $streamHandler.Streams[0].Disposed) 'Body read timeout is enforced and resources are disposed, including after visible content'
    }
    Set-StreamingResponses @(@{ Body = 'data: ' + ('x' * 1000) })
    $failure = Get-StreamingFailure {
        & $module { Invoke-AgentHarnessChatRequest -Uri https://provider.invalid/chat -Headers @{} -Json '{}' -TimeoutSec 5 -Stream -MaxResponseChars 64 }
    }
    Assert-Harness ($failure.Exception.Message -like '*size limit*' -and $streamHandler.Streams[0].Disposed) 'A single unterminated oversized SSE line is bounded'

    Set-StreamingResponses @((New-StreamingResponse 'header test'))
    $body = @{ model = 'synthetic'; messages = @() }
    $null = & $module {
        param($body)
        Invoke-AgentHarnessChat -Uri https://provider.invalid/chat -ApiKey 'synthetic-stream-key' -Body $body -TimeoutSec 5 -Stream -RequestHeaders @{ 'X-Title' = 'synthetic-title' }
    } $body
    Assert-Harness (-not $body.ContainsKey('stream') -and $streamHandler.Headers[0]['X-Title'] -ceq 'synthetic-title' -and $streamHandler.Headers[0]['Authorization'] -ceq 'Bearer synthetic-stream-key') 'Streaming preserves request headers and does not mutate the caller body'

    Set-StreamingResponses @((New-StreamingResponse 'summary source'))
    $summary = @{ goal = 'synthetic'; constraints = 'synthetic'; decisions = 'synthetic'; completed_work = 'synthetic'; verification = 'synthetic'; unfinished_work = 'synthetic'; next_steps = 'synthetic' } | ConvertTo-Json -Compress
    Set-HarnessResponses @((New-HarnessResponse $summary))
    $saved = Invoke-AgentHarness 'Summary task' @streamOptions -SaveContextPath 'stream-summary.json' -ContextMode Summary -Quiet -PassThru
    Assert-Harness ($saved.ContextPath -and $streamHandler.Bodies.Count -eq 1 -and -not (@(Get-HarnessRequests)[0].Body.PSObject.Properties['stream'])) 'Structured context summary remains buffered after a streamed chat turn'

    # Large literal writes traverse the actual HTTP reader, SSE/JSON parser, gate and writer.
    $largeWriteOptions = @{ Model = 'synthetic'; ChatUri = 'https://provider.invalid/chat'; WorkingDirectory = $fixture; NoAgentsFile = $true; NoPromptHistory = $true; NoModelRecovery = $true; NoPromptSound = $true; Quiet = $true; YOLO = $true }
    foreach ($size in 17000, 102400, 1048576) {
        $seed = "abc`"\`n"
        $literal = ($seed * ([int][Math]::Ceiling($size / $seed.Length))).Substring(0, $size)
        $arguments = ConvertTo-Json -InputObject @{ path = 'stream-large.txt'; content = $literal; expected_bytes = $size } -Compress
        $wire = [Text.StringBuilder]::new()
        for ($offset = 0; $offset -lt $arguments.Length; $offset += 4096) {
            $call = @{ index = 0; function = @{ arguments = $arguments.Substring($offset, [Math]::Min(4096, $arguments.Length - $offset)) } }
            if ($offset -eq 0) { $call.id = 'large_write'; $call.type = 'function'; $call.function.name = 'write_file' }
            $null = $wire.Append((New-StreamingEvent @{ tool_calls = @($call) }))
        }
        $null = $wire.Append((New-StreamingEvent @{} tool_calls)).Append("data: [DONE]`n`n")
        foreach ($media in 'text/event-stream', 'application/json') {
            $body = if ($media -eq 'text/event-stream') { $wire.ToString() } else { New-HarnessResponse '' @((New-HarnessCall write_file $arguments)) | ConvertTo-Json -Depth 20 -Compress }
            Set-StreamingResponses @(@{ Body = $body; MediaType = $media; ReadSize = 65536 }, @{ Body = (New-StreamingResponse 'large write done'); ReadSize = 65536 })
            $null = Invoke-AgentHarness 'Synthetic large literal write' @largeWriteOptions
            $actual = [IO.File]::ReadAllBytes((Join-Path $fixture 'stream-large.txt'))
            Assert-Harness ($actual.Length -eq $size -and [Text.Encoding]::UTF8.GetString($actual) -ceq $literal) "$media preserves $size literal bytes through the real transport and writer"
        }
    }
    foreach ($media in 'text/event-stream', 'application/json') {
        $arguments = '{"path":"stream-partial.txt","content":"must not write"}'
        $response = New-HarnessResponse '' @((New-HarnessCall write_file $arguments))
        $response.choices[0].finish_reason = 'length'
        $body = if ($media -eq 'text/event-stream') {
            (New-StreamingEvent @{ tool_calls = @(@{ index = 0; id = 'partial_write'; type = 'function'; function = @{ name = 'write_file'; arguments = $arguments } }) } length) + "data: [DONE]`n`n"
        }
        else { ConvertTo-Json -InputObject $response -Depth 20 -Compress }
        Set-StreamingResponses @(@{ Body = $body; MediaType = $media; ReadSize = 65536 })
        $failure = Get-StreamingFailure { Invoke-AgentHarness 'Incomplete provider output' @largeWriteOptions }
        Assert-Harness ($failure.Exception.Message -like '*finish_reason=length*' -and -not (Test-Path -LiteralPath (Join-Path $fixture 'stream-partial.txt')) -and $streamHandler.Bodies.Count -eq 1) "$media rejects length completion with no write or replay"
    }

    $arguments = '{"path":"stream-diagnostic.txt","content":"synthetic diagnostic text"}'
    $wire = (New-StreamingEvent @{ tool_calls = @(@{ index = 0; id = 'diagnostic_write'; type = 'function'; function = @{ name = 'write_file'; arguments = $arguments.Substring(0, 20) } }) }) +
        (New-StreamingEvent @{ tool_calls = @(@{ index = 0; function = @{ arguments = $arguments.Substring(20) } }) } tool_calls) + "data: [DONE]`n`n"
    Set-StreamingResponses @(@{ Body = $wire; ReadSize = 4096 }, (New-StreamingResponse 'diagnostics done'))
    $streamDiagnosticInfo = @()
    $null = Invoke-AgentHarness 'Synthetic streaming diagnostics' @largeWriteOptions -Quiet:$false -ToolPayloadDiagnostics -InformationVariable streamDiagnosticInfo 6>$null
    $assembly = @($streamDiagnosticInfo | ForEach-Object { [string]$_.MessageData } | Where-Object { $_ -like 'Payload: *' } | ForEach-Object { ConvertFrom-Json -InputObject $_.Substring(9) } | Where-Object boundary -eq assembly)
    Assert-Harness ($assembly.Count -eq 1 -and $assembly[0].fragment_count -eq 2 -and $assembly[0].fragment_chars -eq $arguments.Length -and $assembly[0].assembled_chars -eq $arguments.Length) 'Streaming diagnostics independently count received fragments and assembled arguments'
    $failure = Get-StreamingFailure {
        & $module {
            $state = @{ Started = $false; SeenChoice = $false; Finished = $false; Calls = @{}; Response = @{}; Text = @{} }
            foreach ($field in 'content','reasoning','reasoning_content','refusal') { $state.Text[$field] = [Text.StringBuilder]::new() }
            $chunk = '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"fault","type":"function","function":{"name":"probe","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}' | ConvertFrom-Json
            Add-AgentHarnessChatChunk -State $state -Chunk $chunk
            $null = $state.Calls[0].arguments.Append(' ')
            $reader = [IO.StringReader]::new("data: [DONE]`n`n")
            try { Read-AgentHarnessChatStream -Reader $reader -State $state -Timer ([Diagnostics.Stopwatch]::StartNew()) -TimeoutSec 5 }
            finally { $reader.Dispose() }
        }
    }
    Assert-Harness ($failure.Exception.Message -like '*assembly length mismatch*') 'Injected assembly loss/addition fails before a completed response can execute'

    # Checkpoint acknowledges completion without repeating streamed content.
    & $module { function script:Read-Host { param($Prompt) 'exit' } }
    try {
        Set-StreamingResponses @((New-StreamingResponse 'unique displayed answer'))
        $null = Invoke-AgentHarness 'Completion streaming task' @streamOptions -NoCompletionPrompt:$false -InformationVariable completionStreamInfo 6>$null
        $displayText = $completionStreamInfo -join ''
        Assert-Harness (([regex]::Matches($displayText, 'unique displayed answer')).Count -eq 1 -and $displayText.Contains('Task complete')) 'Continuation checkpoint does not repeat the streamed answer'
    }
    finally { & $module { Remove-Item Function:script:Read-Host } }
}
finally {
    & $module {
        param($request, $client)
        Set-Item Function:script:Invoke-AgentHarnessChatRequest -Value $request
        Set-Item Function:script:New-AgentHarnessChatClient -Value $client
    } $savedStreamingRequest $savedStreamingClient
}
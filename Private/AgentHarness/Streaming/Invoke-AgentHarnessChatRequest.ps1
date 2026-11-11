function Invoke-AgentHarnessChatRequest {
    param([string]$Uri, [hashtable]$Headers, [string]$Json, [int]$TimeoutSec, [switch]$Stream, [scriptblock]$OnText, [int]$MaxResponseChars = 16777216)

    if (-not $Stream) {
        return Invoke-RestMethod -Method Post -Uri $Uri -Headers $Headers -ContentType 'application/json' -Body $Json -TimeoutSec $TimeoutSec -ErrorAction Stop
    }
    $client = $null; $request = $null; $response = $null; $reader = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $cancel = [Threading.CancellationTokenSource]::new()
    $cancel.CancelAfter([TimeSpan]::FromSeconds($TimeoutSec))
    $state = @{ Started = $false; SeenChoice = $false; Finished = $false; FinishReason = $null; Calls = @{}; Response = @{}; Text = @{} }
    foreach ($field in 'content', 'reasoning', 'reasoning_content', 'refusal') { $state.Text[$field] = [Text.StringBuilder]::new() }
    try {
        $client = New-AgentHarnessChatClient
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $Uri)
        foreach ($name in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name]) }
        $null = $request.Headers.TryAddWithoutValidation('Accept', 'text/event-stream, application/json')
        $request.Content = [Net.Http.StringContent]::new($Json, [Text.Encoding]::UTF8, 'application/json')
        $response = Wait-AgentHarnessChatTask -Task ($client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token)) -Timer $timer -TimeoutSec $TimeoutSec
        $failed = -not $response.IsSuccessStatusCode
        if ($failed -and [int]$response.StatusCode -notin 400, 413, 422) {
            $ex = [Exception]::new("Chat HTTP status $([int]$response.StatusCode).")
            $ex.Data['Status'] = [int]$response.StatusCode
            throw $ex
        }
        $type = $response.Content.Headers.ContentType.MediaType
        if ($failed -and $type -ne 'application/json') {
            $ex = [Exception]::new("Chat HTTP status $([int]$response.StatusCode).")
            $ex.Data['Status'] = [int]$response.StatusCode
            throw $ex
        }
        if ($type -notin 'text/event-stream', 'application/json') { throw 'Unsupported chat response content type. Use -NoStream if the provider does not support streaming.' }
        $streamBody = Wait-AgentHarnessChatTask -Task ($response.Content.ReadAsStreamAsync()) -Timer $timer -TimeoutSec $TimeoutSec
        $reader = [IO.StreamReader]::new($streamBody, [Text.UTF8Encoding]::new($false, $true), $true, 4096)
        if ($type -eq 'text/event-stream') {
            if (-not ('SpiAgentHarness.ChatLineReader' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ChatLineReader.cs') -ErrorAction Stop }
            $reader = [SpiAgentHarness.ChatLineReader]::new($reader, $MaxResponseChars)
            return Read-AgentHarnessChatStream -Reader $reader -State $state -Timer $timer -TimeoutSec $TimeoutSec -OnText $OnText
        }
        # Some compatible endpoints ignore stream=true and return a normal JSON response.
        $buffer = [char[]]::new(4096)
        $text = [Text.StringBuilder]::new()
        while ($true) {
            $count = Wait-AgentHarnessChatTask -Task ($reader.ReadAsync($buffer, 0, $buffer.Length)) -Timer $timer -TimeoutSec $TimeoutSec
            if (-not $count) { break }
            if ($text.Length + $count -gt $MaxResponseChars) { throw 'Chat response exceeded the size limit.' }
            $null = $text.Append($buffer, 0, $count)
        }
        try { $result = ConvertFrom-Json -InputObject $text.ToString() -NoEnumerate -ErrorAction Stop }
        catch { throw 'Chat response contained invalid JSON.' }
        if ($result -isnot [Management.Automation.PSCustomObject]) { throw 'Chat response must contain a JSON object.' }
        if ($failed) {
            # Preserve context-length recovery without echoing arbitrary provider response bodies.
            $tooLong = ([string]$result.error.code + ' ' + [string]$result.error.message) -match '(?i)context.length|context window|too long|maximum context|token limit|too many tokens'
            $detail = if ($tooLong) { ': context length exceeded.' } else { '.' }
            $ex = [Exception]::new("Chat HTTP status $([int]$response.StatusCode)$detail")
            $ex.Data['Status'] = [int]$response.StatusCode
            throw $ex
        }
        return $result
    }
    catch {
        if ($response -and -not $response.IsSuccessStatusCode -and -not $_.Exception.Data.Contains('Status')) {
            $_.Exception.Data['Status'] = [int]$response.StatusCode
        }
        if ($state.Started) {
            $ex = [Exception]::new('Chat stream interrupted. Partial output was not saved; no tools from this response were executed. Start a new request to retry.', $_.Exception)
            $ex.Data['StreamStarted'] = $true
            $ex.Data['Status'] = [int]($_.Exception.Data['Status'] ?? 0)
            throw $ex
        }
        throw
    }
    finally {
        $cancel.Cancel()
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() }
        $cancel.Dispose()
        $timer.Stop()
    }
}
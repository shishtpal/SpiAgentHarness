function Read-AgentHarnessChatStream {
    param($Reader, [hashtable]$State, [Diagnostics.Stopwatch]$Timer, [int]$TimeoutSec, [scriptblock]$OnText)

    $data = [Collections.Generic.List[string]]::new()
    $done = $false
    while (-not $done) {
        $line = Wait-AgentHarnessChatTask -Task ($Reader.ReadLineAsync()) -Timer $Timer -TimeoutSec $TimeoutSec
        if ($null -eq $line) { throw 'Chat stream ended before its completion marker.' }
        if ($line.Length) {
            if ($line[0] -eq ':') { continue }
            $separator = $line.IndexOf(':')
            $field = if ($separator -lt 0) { $line } else { $line.Substring(0, $separator) }
            if ($field -cne 'data') { continue }
            $value = if ($separator -lt 0) { '' } else { $line.Substring($separator + 1) }
            if ($value.StartsWith(' ')) { $value = $value.Substring(1) }
            $data.Add($value)
            continue
        }
        if (-not $data.Count) { continue }
        $payload = $data -join "`n"
        $data.Clear()
        if ($payload -ceq '[DONE]') { $done = $true; break }
        try { $chunk = ConvertFrom-Json -InputObject $payload -NoEnumerate -ErrorAction Stop }
        catch { throw 'Chat stream contained invalid JSON.' }
        if ($chunk -isnot [Management.Automation.PSCustomObject]) { throw 'Chat stream event must contain a JSON object.' }
        Add-AgentHarnessChatChunk -State $State -Chunk $chunk -OnText $OnText
    }
    if (-not $State.SeenChoice -or -not $State.Finished) { throw 'Chat stream did not contain a completed assistant message.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $calls = @(
        foreach ($index in @($State.Calls.Keys | Sort-Object)) {
            $parts = $State.Calls[$index]
            $call = @{ id = $parts.id.ToString(); type = 'function'; function = @{ name = $parts.name.ToString(); arguments = $parts.arguments.ToString() } }
            if ([string]::IsNullOrWhiteSpace($call.id) -or [string]::IsNullOrWhiteSpace($call.function.name)) { throw 'Chat stream contained an incomplete tool call.' }
            if (-not $ids.Add($call.id)) { throw 'Chat stream contained duplicate tool-call IDs.' }
            try { $arguments = ConvertFrom-Json -InputObject $call.function.arguments -NoEnumerate -ErrorAction Stop }
            catch { throw 'Chat stream contained invalid tool arguments.' }
            if ($arguments -isnot [Management.Automation.PSCustomObject]) { throw 'Streamed tool arguments must be a JSON object.' }
            $call
        }
    )
    if ($calls.Count -and $State.FinishReason -ne 'tool_calls') { throw 'Chat stream did not finish its tool calls.' }
    if (-not $calls.Count -and $State.FinishReason -eq 'tool_calls') { throw 'Chat stream finished without its tool calls.' }
    $message = @{ role = 'assistant'; content = $(if ($State.Text.content.Length) { $State.Text.content.ToString() } else { $null }); tool_calls = $calls }
    foreach ($field in 'reasoning', 'reasoning_content', 'refusal') {
        if ($State.Text[$field].Length) { $message[$field] = $State.Text[$field].ToString() }
    }
    $State.Response.choices = @(@{ index = 0; message = $message; finish_reason = $State.FinishReason })
    # Match the buffered provider response shape, retaining empty/singleton arrays.
    ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $State.Response -Depth 40 -Compress) -NoEnumerate
}
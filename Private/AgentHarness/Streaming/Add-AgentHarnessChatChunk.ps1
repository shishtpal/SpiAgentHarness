function Add-AgentHarnessChatChunk {
    param(
        [hashtable]$State,
        [object]$Chunk,
        [scriptblock]$OnText
    )

    if ($Chunk.error) {
        $code = 0
        [void][int]::TryParse([string]$Chunk.error.code, [ref]$code)
        $tooLong = ([string]$Chunk.error.code + ' ' + [string]$Chunk.error.message) -match '(?i)context.length|context window|too long|maximum context|token limit|too many tokens'
        $message = if ($tooLong) { 'Streaming API error: context length exceeded.' } else { 'Streaming API returned an error.' }
        if ($tooLong -and -not $code) { $code = 400 }
        $ex = [Exception]::new($message)
        $ex.Data['Status'] = $code
        throw $ex
    }
    if ($Chunk.choices -isnot [array]) { throw 'Streaming choices must be a JSON array.' }
    foreach ($field in 'id', 'model', 'created', 'system_fingerprint') {
        if ($Chunk.PSObject.Properties[$field]) { $State.Response[$field] = $Chunk.$field }
    }
    if ($Chunk.usage) { $State.Response.usage = $Chunk.usage }
    foreach ($choice in @($Chunk.choices)) {
        if ($null -eq $choice) { continue }
        if ($choice -isnot [Management.Automation.PSCustomObject]) { throw 'Invalid streaming choice.' }
        if ($null -eq $choice.index -or [string]$choice.index -cne '0') { throw 'Unsupported streaming choice index.' }
        if ($State.Finished -and $choice.delta -and @($choice.delta.PSObject.Properties).Count) { throw 'Received a delta after the streaming choice finished.' }
        $State.SeenChoice = $true
        $delta = $choice.delta
        if ($null -ne $delta -and $delta -isnot [Management.Automation.PSCustomObject]) { throw 'Invalid streaming delta.' }
        if ($delta.role -and $delta.role -cne 'assistant') { throw 'Invalid streaming assistant role.' }
        foreach ($field in 'content', 'reasoning', 'reasoning_content', 'refusal') {
            if ($null -eq $delta.$field) { continue }
            if ($delta.$field -isnot [string]) { throw 'Invalid streaming text delta.' }
            if ($delta.$field.Length) { $State.Started = $true }
            $null = $State.Text[$field].Append($delta.$field)
            if ($field -eq 'content' -and $delta.$field.Length -and $OnText) { $null = & $OnText $delta.$field }
        }
        if ($null -ne $delta.tool_calls -and $delta.tool_calls -isnot [array]) { throw 'Streaming tool calls must be a JSON array.' }
        foreach ($call in @($delta.tool_calls)) {
            if ($null -eq $call) { continue }
            $State.Started = $true
            $index = 0
            if (-not [int]::TryParse([string]$call.index, [ref]$index) -or $index -lt 0 -or $index -gt 1023) { throw 'Invalid streaming tool-call index.' }
            if (-not $State.Calls.ContainsKey($index)) {
                $State.Calls[$index] = @{ id = [Text.StringBuilder]::new(); name = [Text.StringBuilder]::new(); arguments = [Text.StringBuilder]::new() }
            }
            $target = $State.Calls[$index]
            if ($call.type -and $call.type -cne 'function') { throw 'Unsupported streaming tool-call type.' }
            foreach ($field in 'id', 'type') {
                if ($null -ne $call.$field -and $call.$field -isnot [string]) { throw 'Invalid streaming tool-call field.' }
            }
            if ($call.id) { $null = $target.id.Append($call.id) }
            foreach ($field in 'name', 'arguments') {
                if ($null -eq $call.function.$field) { continue }
                if ($call.function.$field -isnot [string]) { throw 'Invalid streaming tool-call delta.' }
                $null = $target[$field].Append($call.function.$field)
            }
        }
        if ($null -ne $choice.finish_reason) {
            if ($choice.finish_reason -isnot [string] -or -not $choice.finish_reason.Length) { throw 'Invalid streaming finish reason.' }
            $State.Finished = $true
            $State.FinishReason = $choice.finish_reason
        }
    }
}
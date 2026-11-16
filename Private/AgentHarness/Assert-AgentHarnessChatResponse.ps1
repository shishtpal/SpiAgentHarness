function Assert-AgentHarnessChatResponse {
    param([object]$Response, [hashtable]$Context, [switch]$Stream)

    try {
        if ($Response.choices -isnot [array] -or $Response.choices.Count -ne 1 -or -not $Response.choices[0].message) {
            throw 'Response contained no assistant message or an unsupported choices shape.'
        }
        $choice = $Response.choices[0]
        $message = $choice.message
        if ($message.role -cne 'assistant') { throw 'Response message role must be assistant.' }
        $reason = $choice.finish_reason
        Write-AgentHarnessPayloadDiagnostic -Context $Context -Data @{
            boundary = 'response'; transport = $(if ($Stream) { 'stream-request' } else { 'buffered-json' })
            model = $Response.model; finish_reason = $reason; calls = $message.tool_calls.Count
            prompt_tokens = $Response.usage.prompt_tokens; completion_tokens = $Response.usage.completion_tokens
        }
        if ($reason -ceq 'length') { throw 'Provider response reached its output limit (finish_reason=length); no tools from this response were executed. Use smaller chunks or an approved local generation script.' }
        if ($reason -cnotin 'stop', 'tool_calls' -or $message.refusal) { throw 'Provider response was incomplete, filtered or refused; no tools from this response were executed.' }
        if ($null -ne $message.tool_calls -and $message.tool_calls -isnot [array]) { throw 'Response tool_calls must be a JSON array.' }
        $calls = @($message.tool_calls | Where-Object { $null -ne $_ })
        if (($calls.Count -and $reason -cne 'tool_calls') -or (-not $calls.Count -and $reason -ceq 'tool_calls')) {
            throw 'Response completion reason does not match its tool calls.'
        }
        if ($null -ne $message.tool_calls -and $calls.Count -ne $message.tool_calls.Count) { throw 'Response contains a null tool call.' }
        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($call in $calls) {
            if ($call.type -cne 'function' -or $call.id -isnot [string] -or [string]::IsNullOrWhiteSpace($call.id) -or
                $call.function.name -isnot [string] -or [string]::IsNullOrWhiteSpace($call.function.name)) {
                throw 'Response contained an incomplete function call.'
            }
            if (-not $ids.Add($call.id)) { throw 'Response contained duplicate tool-call IDs.' }
            # Preserve compatible endpoints that return an argument object, but never coerce a scalar/array.
            $arguments = $call.function.arguments
            if ($arguments -is [string]) {
                try { $parsed = ConvertFrom-Json -InputObject $arguments -AsHashtable -NoEnumerate -ErrorAction Stop }
                catch { throw 'Response contained invalid tool argument JSON; no tools from this response were executed.' }
            }
            elseif ($arguments -is [Collections.IDictionary] -or $arguments -is [Management.Automation.PSCustomObject]) { $parsed = $arguments }
            else { throw 'Response tool arguments must be a JSON object.' }
            if ($parsed -isnot [Collections.IDictionary] -and $parsed -isnot [Management.Automation.PSCustomObject]) { throw 'Response tool arguments must be a JSON object.' }
        }
    }
    catch {
        $failure = [Exception]::new($_.Exception.Message)
        $failure.Data['ResponseIncomplete'] = $true
        throw $failure
    }
}
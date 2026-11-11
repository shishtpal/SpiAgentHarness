function ConvertTo-AgentHarnessContextMessages {
    param([object[]]$Messages, [switch]$AllowInterrupted)

    $ErrorActionPreference = 'Stop'
    # Clone before validating, preserving singleton arrays and rejecting excessive depth.
    $json = ConvertTo-Json -InputObject @($Messages) -Depth 30 -Compress -WarningAction Stop
    $items = ConvertFrom-AgentHarnessContextJson -Json $json
    if ($items -isnot [array] -or $items.Count -eq 0) { throw 'Context messages must be a nonempty array.' }
    $result = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($item in $items) {
        if ($item -isnot [Collections.IDictionary] -or $item.role -isnot [string] -or $item.role -cnotin @('system', 'user', 'assistant', 'tool')) {
            throw 'Context contains an invalid message role.'
        }
        if ($item.role -eq 'system' -and $result.Count -ne 0) { throw 'Context system instructions must be first.' }
        if ($pending.Count -and $item.role -ne 'tool') { throw 'Context contains unresolved tool calls.' }
        $content = $item.content
        if ($content -is [array]) {
            if (-not $content.Count) { throw 'Context content arrays cannot be empty.' }
            foreach ($part in $content) {
                if ($part -isnot [Collections.IDictionary] -or $part.type -isnot [string]) { throw 'Context contains an invalid content part.' }
                switch -CaseSensitive ($part.type) {
                    'text' { if ($part.text -isnot [string]) { throw 'Context text parts require text.' } }
                    'image_url' {
                        if ($part.image_url -isnot [Collections.IDictionary] -or $part.image_url.url -isnot [string] -or [string]::IsNullOrWhiteSpace($part.image_url.url)) { throw 'Context contains an invalid image part.' }
                    }
                    'video_url' {
                        if ($part.video_url -isnot [Collections.IDictionary] -or $part.video_url.url -isnot [string] -or [string]::IsNullOrWhiteSpace($part.video_url.url)) { throw 'Context contains an invalid video part.' }
                    }
                    'file' {
                        if ($part.file -isnot [Collections.IDictionary] -or $part.file.filename -isnot [string] -or $part.file.file_data -isnot [string]) { throw 'Context contains an invalid file part.' }
                    }
                    default { throw 'Context contains an unsupported content part.' }
                }
            }
        }
        elseif ($content -isnot [string] -and -not ($null -eq $content -and $item.role -eq 'assistant' -and $item.tool_calls.Count)) {
            throw 'Context message content must be text or a content array.'
        }
        $message = @{ role = $item.role; content = $content }
        if ($item.Contains('tool_calls')) {
            if ($item.role -ne 'assistant' -or $item.tool_calls -isnot [array] -or -not $item.tool_calls.Count) {
                throw 'Context tool calls must be a nonempty assistant array.'
            }
            $calls = [Collections.Generic.List[object]]::new()
            foreach ($call in $item.tool_calls) {
                if ($call -isnot [Collections.IDictionary] -or $call.type -isnot [string] -or $call.type -cne 'function' -or $call.id -isnot [string] -or [string]::IsNullOrWhiteSpace($call.id) -or $call.function -isnot [Collections.IDictionary] -or $call.function.name -isnot [string] -or [string]::IsNullOrWhiteSpace($call.function.name) -or $call.function.arguments -isnot [string]) {
                    throw 'Context contains an invalid tool call.'
                }
                try { $arguments = ConvertFrom-AgentHarnessContextJson -Json $call.function.arguments }
                catch { throw 'Context tool arguments must be a JSON object.' }
                if ($arguments -isnot [Collections.IDictionary]) { throw 'Context tool arguments must be a JSON object.' }
                if ($pending.ContainsKey($call.id)) { throw 'Context contains duplicate tool-call IDs in a batch.' }
                $pending.Add($call.id, $call.function.name)
                $calls.Add(@{ id = $call.id; type = 'function'; function = @{ name = $call.function.name; arguments = $call.function.arguments } })
            }
            $message.tool_calls = $calls.ToArray()
        }
        if ($item.role -eq 'tool') {
            if ($item.tool_call_id -isnot [string] -or -not $pending.ContainsKey($item.tool_call_id)) { throw 'Context contains an orphan or duplicate tool result.' }
            if ($item.Contains('name') -and $item.name -cne $pending[$item.tool_call_id]) { throw 'Context tool result name does not match its call.' }
            $message.tool_call_id = $item.tool_call_id
            if ($item.Contains('name')) { $message.name = $item.name }
            $null = $pending.Remove($item.tool_call_id)
        }
        elseif ($item.Contains('tool_call_id')) { throw 'Only tool results may contain tool_call_id.' }
        $result.Add($message)
    }
    if ($pending.Count) { throw 'Context contains unresolved tool calls.' }
    if ($AllowInterrupted -and $result[-1].role -eq 'system') {
        throw 'Recovery context must contain a user message, completed tool batch or assistant answer.'
    }
    if (-not $AllowInterrupted -and ($result[-1].role -ne 'assistant' -or $result[-1].tool_calls)) {
        throw 'Context must end at a completed assistant answer.'
    }
    , $result.ToArray()
}
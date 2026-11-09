function ConvertTo-AgentHarnessToolCall {
    param([object[]]$Calls)

    foreach ($call in $Calls) {
        if (-not $call) { continue }
        $arguments = $call.function.arguments
        if ($null -eq $arguments) { $arguments = '{}' }
        elseif ($arguments -isnot [string]) { $arguments = ConvertTo-Json -InputObject $arguments -Depth 20 -Compress }
        if ([string]::IsNullOrWhiteSpace($arguments)) { $arguments = '{}' }
        @{
            id       = ($call.id ? $call.id : ('call_' + [guid]::NewGuid().ToString('N').Substring(0, 12)))
            type     = 'function'
            function = @{ name = $call.function.name; arguments = $arguments }
        }
    }
}
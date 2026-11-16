function Write-AgentHarnessPayloadDiagnostic {
    param([hashtable]$Context, [hashtable]$Data)

    if (-not $Context.ToolPayloadDiagnostics -or $Context.Quiet) { return }
    $record = @{ invocation = $Context.ContextSessionId; turn = $Context.PayloadTurn; call_id = $Context.PayloadCallId; provider = $Context.PayloadProvider; model = $Context.PayloadModel }
    foreach ($key in $Data.Keys) { $record[$key] = $Data[$key] }
    foreach ($key in @($record.Keys)) {
        $value = $record[$key]
        if ($value -is [string]) { $record[$key] = $value.Substring(0, [Math]::Min(256, $value.Length)) }
        elseif ($null -ne $value -and $value -isnot [ValueType]) { $record[$key] = '[invalid metadata type]' }
    }
    Write-Information -MessageData ('Payload: ' + (ConvertTo-Json -InputObject $record -Depth 5 -Compress)) -InformationAction Continue
}
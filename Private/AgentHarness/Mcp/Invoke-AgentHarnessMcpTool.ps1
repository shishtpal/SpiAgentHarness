function Invoke-AgentHarnessMcpTool {
    param([hashtable]$Binding, [hashtable]$Arguments, [hashtable]$Context)

    $ErrorActionPreference = 'Stop'
    $connection = $Binding.Connection
    if (-not $Binding.AutoApprove) {
        $details = Protect-AgentHarnessMcpText -Text ($Arguments | ConvertTo-Json -Depth 100) -Connection $connection
        if (-not (Confirm-AgentHarnessAction -Ctx $Context -Description "MCP server: $($connection.Name)`nTool: $($Binding.OriginalName)`n$details")) {
            return 'Denied: MCP tool was not executed.'
        }
    }
    $result = Invoke-AgentHarnessMcpRequest -Connection $connection -Method 'tools/call' -Parameters @{
        name = $Binding.OriginalName; arguments = $Arguments
    }
    if ($result.resultType -eq 'input_required') { return 'ERROR: MCP server requested an unsupported client interaction. Sampling, roots, and elicitation are not enabled.' }
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($item in $result.content) {
        if ($item.type -eq 'text') { $parts.Add([string]$item.text) }
        elseif ($item.type -eq 'resource' -and $item.resource.ContainsKey('text')) { $parts.Add([string]$item.resource.text) }
        elseif ($item.type -eq 'resource_link') { $parts.Add("Resource link: $($item.uri)") }
        else { $parts.Add("[Unsupported MCP content: $($item.type); binary data omitted]") }
    }
    if ($result.ContainsKey('structuredContent')) {
        $parts.Add((ConvertTo-Json -InputObject $result.structuredContent -Depth 100 -Compress))
    }
    $text = Protect-AgentHarnessMcpText -Text ($parts -join "`n") -Connection $connection
    if ($result.isError) { return "ERROR: $text" }
    $text
}
function Get-AgentHarnessMcpTools {
    param(
        [hashtable]$Servers, [Collections.IDictionary]$ToolTable,
        [Collections.Generic.List[hashtable]]$Connections, [string]$WorkingDirectory
    )

    $ErrorActionPreference = 'Stop'
    $invoke = ${function:Invoke-AgentHarnessMcpTool}
    foreach ($serverName in $Servers.Keys) {
        if ([string]::IsNullOrWhiteSpace($serverName) -or $Servers[$serverName] -isnot [hashtable]) { throw 'McpServers must map nonempty server names to configuration hashtables.' }
        $config = $Servers[$serverName]
        $connection = Open-AgentHarnessMcpConnection -Name $serverName -Config $config -WorkingDirectory $WorkingDirectory
        $Connections.Add($connection)
        $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($name in $config.AllowedTools) { $null = $allowed.Add($name) }
        $autoApprove = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($name in $config.AutoApproveTools) { $null = $autoApprove.Add($name) }
        $seenNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $cursors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $parameters = @{}
        $pageCount = 0
        do {
            $pageCount++
            if ($pageCount -gt 100) { throw "MCP '$serverName': tools/list exceeded 100 pages." }
            $page = Invoke-AgentHarnessMcpRequest -Connection $connection -Method 'tools/list' -Parameters $parameters
            if ($page.tools -isnot [array]) { throw "MCP '$serverName': tools/list must return a tools array." }
            foreach ($tool in $page.tools) {
                $originalName = [string]$tool.name
                if ($tool -isnot [hashtable] -or [string]::IsNullOrWhiteSpace($originalName) -or -not $seenNames.Add($originalName)) { throw "MCP '$serverName': invalid or duplicate tool name." }
                if ($config.ContainsKey('AllowedTools') -and -not $allowed.Contains($originalName)) { continue }
                if ($tool.inputSchema -isnot [hashtable] -or $tool.inputSchema.type -ne 'object') { throw "MCP '$serverName': tools must use object input schemas." }
                if ($connection.Transport -eq 'http' -and $connection.ProtocolVersion -eq '2026-07-28') {
                    try { $connection.ToolHeaders[$originalName] = @(Get-AgentHarnessMcpHeaderMappings -Schema $tool.inputSchema) }
                    catch { Write-Warning "MCP '$serverName': excluded a tool with invalid x-mcp-header annotations."; continue }
                }

                $safeName = 'mcp_' + ($serverName -replace '[^A-Za-z0-9_-]', '_') + '_' + ($originalName -replace '[^A-Za-z0-9_-]', '_')
                if ($safeName.Length -gt 64 -or $ToolTable.Contains($safeName) -or $originalName -cmatch '[^A-Za-z0-9_-]' -or $serverName -cmatch '[^A-Za-z0-9_-]') {
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$serverName`n$originalName"))).Replace('-', '').Substring(0, 12).ToLowerInvariant() }
                    finally { $sha.Dispose() }
                    $safeName = $safeName.Substring(0, [Math]::Min(51, $safeName.Length)) + '_' + $hash
                }
                if ($ToolTable.Contains($safeName)) { throw "MCP '$serverName': exported tool name collides with another registered tool." }
                $binding = @{ Connection = $connection; OriginalName = $originalName; AutoApprove = $autoApprove.Contains($originalName) }
                $ToolTable[$safeName] = @{
                    Description = Protect-AgentHarnessMcpText -Text "[MCP: $serverName] $($tool.description)" -Connection $connection
                    Parameters = $tool.inputSchema
                    RequiresApproval = -not $binding.AutoApprove
                    # Capture the module-bound executor so private commands remain resolvable.
                    Script = { param($a, $ctx) & $invoke -Binding $binding -Arguments $a -Context $ctx }.GetNewClosure()
                    McpBinding = $binding
                }
            }
            $cursor = [string]$page.nextCursor
            if ($cursor -and -not $cursors.Add($cursor)) { throw "MCP '$serverName': tools/list repeated a pagination cursor." }
            $parameters = @{ cursor = $cursor }
        } while ($cursor)
        $advertised = @($seenNames | Sort-Object | Select-Object -First 20) -join ', '
        if ($seenNames.Count -gt 20) { $advertised += ', ...' }
        foreach ($name in $allowed) {
            if (-not $seenNames.Contains($name)) {
                throw (Protect-AgentHarnessMcpText -Connection $connection -Text "MCP '$serverName': AllowedTools entry '$name' was not advertised by the server. Advertised top-level tools: $advertised.")
            }
        }
        foreach ($name in $autoApprove) {
            if (-not $seenNames.Contains($name)) {
                $hint = if ($seenNames.Contains('search_tool') -and $seenNames.Contains('call_tool')) {
                    ' This server exposes a dispatcher: underlying tools are discovered using search_tool and executed using call_tool. Remove underlying tool names from AutoApproveTools.'
                } else { ' Remove this entry or use an advertised top-level tool name.' }
                throw (Protect-AgentHarnessMcpText -Connection $connection -Text "MCP '$serverName': AutoApproveTools entry '$name' was not advertised by the server. Advertised top-level tools: $advertised.$hint")
            }
            if ($config.ContainsKey('AllowedTools') -and -not $allowed.Contains($name)) {
                throw (Protect-AgentHarnessMcpText -Connection $connection -Text "MCP '$serverName': AutoApproveTools entry '$name' is excluded by AllowedTools. Remove it from AutoApproveTools or include it in AllowedTools.")
            }
        }
    }
}
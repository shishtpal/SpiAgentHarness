function Select-AgentHarnessMcpServers {
    param([hashtable]$Servers, [AllowEmptyCollection()][string[]]$Name)

    $selected = @{}
    foreach ($item in $Name) {
        if ([string]::IsNullOrWhiteSpace($item)) { throw 'McpServer must contain nonempty server names, or * to activate all.' }
    }
    if ('*' -in $Name) {
        if ($Name.Count -ne 1) { throw 'Use McpServer * alone, or specify a list of exact server names.' }
        return $Servers
    }
    foreach ($item in $Name) {
        if (-not $Servers.ContainsKey($item)) { throw "Unknown MCP server '$item'. Use Get-McpServer to list configured servers." }
        $selected[$item] = $Servers[$item]
    }
    $selected
}
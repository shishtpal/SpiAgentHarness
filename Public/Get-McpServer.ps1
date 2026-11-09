#requires -Version 7.0
<#
.SYNOPSIS
    List configured MCP servers without connecting to them.
.DESCRIPTION
    Reads the same JSON configuration as Invoke-AgentHarness, or accepts its
    McpServers hashtable. Returns pipeline objects with a safe connection summary
    and tool allowlists. Arguments, environment values and headers are omitted;
    URL user information, queries and fragments are removed. No server process
    is started, network request made, or credential environment variable read.
.PARAMETER McpConfigPath
    Defaults to mcp.json in the module directory. Explicit relative paths resolve
    against WorkingDirectory. An absent default file returns no servers.
.PARAMETER Name
    Wildcard filter on the configured server name.
.EXAMPLE
    Get-McpServer
.EXAMPLE
    Get-McpServer -McpConfigPath './Config/AgentHarness.mcp.example.json'
.EXAMPLE
    Get-McpServer './mcp.json' -Name 'browser*' | Format-List *
.EXAMPLE
    Get-McpServer -McpServers $servers
#>
function Get-McpServer {
    [CmdletBinding(DefaultParameterSetName = 'File')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'File')]
        [Alias('McpConfigFile', 'McpConfig', 'Path')][ValidateNotNullOrEmpty()][string]$McpConfigPath,
        [Parameter(Mandatory, ParameterSetName = 'Servers')][AllowEmptyCollection()][hashtable]$McpServers,
        [string]$Name = '*',
        [string]$WorkingDirectory = (Get-Location).Path
    )

    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $options = @{ WorkingDirectory = $WorkingDirectory }
        if ($PSBoundParameters.ContainsKey('McpConfigPath')) { $options.Path = $McpConfigPath }
        $McpServers = Read-AgentHarnessMcpConfig @options
    }
    foreach ($serverName in @($McpServers.Keys | Sort-Object)) {
        if ($serverName -notlike $Name) { continue }
        if ([string]::IsNullOrWhiteSpace($serverName) -or $McpServers[$serverName] -isnot [hashtable]) {
            throw 'McpServers must map nonempty server names to configuration hashtables.'
        }
        ConvertTo-AgentHarnessMcpServerInfo -Name $serverName -Config $McpServers[$serverName] -WorkingDirectory $WorkingDirectory
    }
}
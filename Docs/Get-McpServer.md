# Get-McpServer

List servers configured in the shared [mcp.json](../mcp.json) at the PowerShell module root, from any working directory. Configured JSON servers remain inactive until selected for a harness invocation.

```powershell
Get-McpServer
Get-McpServer -Name 'browser*'
Get-McpServer | Format-List *
Invoke-AgentHarness 'Use one source' -McpServer browser
Invoke-AgentHarness 'Use selected sources' -McpServer browser,other
Invoke-AgentHarness 'Use all sources' -McpServer '*'

# Inspect another JSON file or an inline server map.
Get-McpServer -McpConfigPath './other-mcp.json'
Get-McpServer -McpServers $servers
```

The command returns pipeline objects, sorted by name. The default table shows `Name`, `Transport`, and `Endpoint`. Additional properties are `WorkingDirectory`, `AllToolsAllowed`, `AllowedTools`, and `AutoApproveTools`. `AllToolsAllowed` distinguishes an absent allowlist from an explicitly empty list.

Listing does not launch executables, connect to endpoints, discover available tools, or read credential environment variables. It reports configuration rather than live connection status. Arguments, environment variables, and headers are omitted. Endpoint URLs exclude user information, query strings, and fragments; known configured credential values are redacted.

`-McpConfigPath` accepts `-McpConfigFile`, `-McpConfig`, and `-Path` as aliases and supports position 0. Explicit relative paths resolve against `-WorkingDirectory`, which defaults to the current directory. The shared default always resolves against the module directory. An absent shared file returns no servers; a missing explicit file or malformed JSON raises an error.

See [MCP configuration](Invoke-AgentHarness.md#mcp-servers) for the JSON format and server options.
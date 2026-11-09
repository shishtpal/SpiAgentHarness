#requires -Version 7.0
<#
.SYNOPSIS
    Explicit opt-in read-only MCP smoke test; no live model/provider requests.
.DESCRIPTION
    Loads the shared module configuration or the supplied server configuration,
    and performs one fixed read-only call: list_memory with limit 1, or
    search_tool loading the list_memory definition on dispatcher servers.
    Uses an isolated module assembled from harness sources, without bootstrap or
    the repository manifest. Does not print memory content or server diagnostics.
#>
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [Parameter(ParameterSetName = 'Default')][switch]$UseModuleConfig,
    [Parameter(Mandatory, ParameterSetName = 'Command')][string]$Command,
    [Parameter(Mandatory, ParameterSetName = 'Command')][string[]]$ServerArguments,
    [Parameter(Mandatory, ParameterSetName = 'Json')][string]$McpConfigPath,
    [string]$ServerWorkingDirectory = (Get-Location).Path
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$module = New-Module -Name ('SpiMcpSmoke_' + [guid]::NewGuid().ToString('N')) -ArgumentList $repo -ScriptBlock {
    param($sourceRoot)
    . (Join-Path $sourceRoot 'Public/Invoke-AgentHarness.ps1')
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'Private/AgentHarness') -Filter '*.ps1' -Recurse) { . $file.FullName }
    function Write-LogMessage { param($Message, $Color, [switch]$NoTimestamp, [switch]$Silent) }
    $script:SmokeTurns = 0
    $script:SmokeResultPattern = ''
    function Invoke-AgentHarnessTurn {
        param($State, $Messages, $ToolSpecs, $ChatUri, $ApiKey, $TimeoutSec, $Temperature, $MaxModelAttempts, $Iteration, $Log, $NoModelRecovery)
        $script:SmokeTurns++
        if ($script:SmokeTurns -eq 1) {
            $selected = @($ToolSpecs | Where-Object { $_.function.name -match '_list_memory$' }) | Select-Object -First 1
            if ($selected) {
                $arguments = '{"limit":1,"detail":"titles","parent":"mem_projects","tags":["agent-harness"]}'
                $script:SmokeResultPattern = 'MEMORY_LIST'
            }
            else {
                $selected = @($ToolSpecs | Where-Object { $_.function.name -match '_search_tool$' }) | Select-Object -First 1
                if (-not $selected) { throw 'Smoke test requires an advertised list_memory or search_tool tool.' }
                $arguments = '{"action":"load","names":["list_memory"]}'
                $script:SmokeResultPattern = '"name"\s*:\s*"list_memory"'
            }
            $message = @{ content = ''; tool_calls = @(@{ id = 'mcp_smoke'; type = 'function'; function = @{
                name = $selected.function.name
                arguments = $arguments
            } }) }
        }
        else {
            if ($Messages[$Messages.Count - 1].content -like 'ERROR:*') { throw 'MCP smoke tool failed.' }
            $message = @{ content = 'MCP smoke test passed'; tool_calls = @() }
        }
        $response = @{ choices = @(@{ message = $message; finish_reason = 'stop' }) } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        @{ Response = $response; Candidate = $State.Candidates[0]; ElapsedMilliseconds = 0 }
    }
    Export-ModuleMember -Function Invoke-AgentHarness
}
try {
    $result = & $module {
        param($commandPath, $serverArgs, $serverRoot, $configPath)
        $mcpOptions = if ($configPath) { @{ McpConfigPath = $configPath } }
        elseif ($commandPath) { @{ McpServers = @{ browser = @{
            Command = $commandPath; Arguments = $serverArgs; WorkingDirectory = $serverRoot
            TimeoutSec = 30
        } } } }
        else { @{} }
        Invoke-AgentHarness 'Read-only MCP connectivity check' -Model synthetic-smoke -ChatUri https://provider.invalid/chat `
            -NoAgentsFile -NoBuiltinTools -Quiet -NoPromptSound -NoCompletionPrompt -NoModelRecovery -PassThru `
            -McpServer '*' -YOLO @mcpOptions
    } $Command $ServerArguments $ServerWorkingDirectory $McpConfigPath
    $expected = & $module { $script:SmokeResultPattern }
    if ($result.Answer -ne 'MCP smoke test passed' -or $result.Iterations -ne 2 -or $result.Messages[3].content -notmatch $expected) { throw 'MCP smoke test did not complete the expected read-only tool round trip.' }
    Write-Host 'Passed: discovery, configured allowlists, provider schema, fixed read-only tool dispatch, result, and cleanup. No live model request or memory changes.'
}
finally { Remove-Module $module -Force -ErrorAction SilentlyContinue }
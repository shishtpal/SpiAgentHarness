#requires -Version 7.0
<#
.SYNOPSIS
    Explicit opt-in integration check for an already installed REA CLI.
.DESCRIPTION
    Starts REA only with -Run. Uses synthetic Electron/JavaScript and managed
    files, a mocked model, and fixed static tool calls through the real harness.
    Installs nothing and never copies local configuration or global skills.
#>
[CmdletBinding(DefaultParameterSetName = 'Command')]
param(
    [switch]$Run,
    [Parameter(ParameterSetName = 'Command')][string]$Command = 'rea',
    [Parameter(Mandatory, ParameterSetName = 'Json')][string]$McpConfigPath
)
$ErrorActionPreference = 'Stop'
if (-not $Run) {
    Write-Host 'Skipped REA smoke test. Use -Run to opt in to the installed local REA server; no packages are installed.'
    return
}
if (Test-Path Env:HOPPER_TARGET_PATH) { throw 'Clear HOPPER_TARGET_PATH before this synthetic target-free test.' }
$repo = Split-Path $PSScriptRoot -Parent
$fixtureRoot = Join-Path $repo '.agent-harness'
$fixture = Join-Path $fixtureRoot ('rea-smoke-' + [guid]::NewGuid().ToString('N'))
$module = $null
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $app = Join-Path $fixture 'electron-app'
    $null = New-Item -ItemType Directory -Path $app
    [IO.File]::WriteAllText((Join-Path $app 'package.json'), '{"name":"rea-static-fixture","version":"1.0.0","main":"main.cjs"}')
    [IO.File]::WriteAllText((Join-Path $app 'main.cjs'), @'
const { ipcMain } = require('electron');
const count = require('./count.cjs');
ipcMain.handle('rea:count', (_event, value) => count(value));
throw new Error('REA_SMOKE_TARGET_MUST_NOT_EXECUTE');
'@)
    [IO.File]::WriteAllText((Join-Path $app 'count.cjs'), 'module.exports = function count(value) { return value + 1; };')
    $assembly = Join-Path $fixture 'ReaStaticFixture.dll'
    Add-Type -OutputAssembly $assembly -TypeDefinition @'
namespace ReaStaticFixture {
    public static class Sample {
        public static string Describe(int count) { return "REA_STATIC_MANAGED_" + count; }
    }
}
'@
    $before = @{}
    foreach ($file in Get-ChildItem -LiteralPath $fixture -File -Recurse) { $before[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash }
    $module = New-Module -Name ('SpiReaSmoke_' + [guid]::NewGuid().ToString('N')) -ArgumentList $repo, $app, $assembly -ScriptBlock {
        param($sourceRoot, $applicationPath, $assemblyPath)
        . (Join-Path $sourceRoot 'Public/Invoke-AgentHarness.ps1')
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'Private/AgentHarness') -Filter '*.ps1' -File -Recurse) { . $file.FullName }
        function Write-LogMessage { param($Message, $Color, [switch]$NoTimestamp, [switch]$Silent) }
        $script:ReaTurn = 0
        $script:ReaApplicationPath = $applicationPath
        $script:ReaAssemblyPath = $assemblyPath
        $script:ReaClosedProcessIds = [Collections.Generic.List[int]]::new()
        $script:ReaClose = ${function:Close-AgentHarnessMcpConnection}
        function script:Close-AgentHarnessMcpConnection {
            param([hashtable]$Connection)
            if ($Connection.Process -and -not $Connection.Closed) { $script:ReaClosedProcessIds.Add($Connection.Process.Id) }
            & $script:ReaClose -Connection $Connection
        }
        function script:Invoke-AgentHarnessTurn {
            param($State, $Messages, $ToolSpecs, $ChatUri, $ApiKey, $TimeoutSec, $Temperature, $MaxModelAttempts, $Iteration, $Log, $NoModelRecovery)
            $script:ReaTurn++
            $turn = $script:ReaTurn
            if ($turn -eq 1) {
                $script:ReaToolNames = @($ToolSpecs.function.name)
                foreach ($required in 'analyze_javascript_application', 'inspect_analysis_view', 'inspect_managed_artifact', 'inspect_managed_members') {
                    if ('mcp_rea_' + $required -notin $script:ReaToolNames) { throw 'A required REA tool was not exposed.' }
                }
                foreach ($spec in $ToolSpecs) {
                    if ($spec.function.parameters.type -ne 'object') { throw 'REA advertised a non-object tool schema.' }
                }
                if ($script:ReaToolNames -contains 'mcp_rea_capture_process_scenario') { throw 'The static REA allowlist was not applied.' }
            }
            else {
                $previous = [string]$Messages[$Messages.Count - 1].content
                if ($turn -eq 7) {
                    if ($previous -notlike 'ERROR:*') { throw 'A missing synthetic assembly did not produce a tool error.' }
                }
                elseif ($previous -like 'ERROR:*' -or $previous -match '\.\.\.\[truncated') {
                    $reason = if ($previous -match '"message"\s*:\s*"([^"\r\n]*)"') { $Matches[1] } else { 'Tool error or truncated response.' }
                    throw "REA smoke step $($turn - 1): $reason"
                }
                if ($turn -in 2, 4, 5) {
                    $parents = [regex]::Matches($previous, '"parent_evidence_id"\s*:\s*"([^"]+)"')
                    if (-not $parents.Count) { throw 'REA did not retain complete parent Evidence for a summary.' }
                    $parentId = $parents[0].Groups[1].Value
                    if (@($parents | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique).Count -ne 1) { throw 'Conflicting parent Evidence identities.' }
                }
                if ($turn -eq 3 -and $previous -notmatch 'main\.cjs') { throw 'Retained JavaScript modules did not include the fixture entry point.' }
                if ($turn -eq 6 -and ($previous -notmatch 'Describe' -or $previous -notmatch 'ldstr')) { throw 'Retained CIL members did not include the synthetic method and its string-load instruction.' }
            }
            $tool = ''
            $arguments = @{}
            switch ($turn) {
                1 { $tool = 'analyze_javascript_application'; $arguments = @{ input_path = $script:ReaApplicationPath; detail = 'summary' } }
                2 { $tool = 'inspect_analysis_view'; $arguments = @{ source = @{ kind = 'retained-evidence'; evidence_id = $parentId }; view = @{ kind = 'page'; collection = 'modules'; offset = 0; limit = 4 } } }
                3 { $tool = 'inspect_managed_artifact'; $arguments = @{ path = $script:ReaAssemblyPath; detail = 'summary' } }
                4 { $tool = 'inspect_managed_members'; $arguments = @{ path = $script:ReaAssemblyPath; type_names = @('ReaStaticFixture.Sample'); detail = 'summary' } }
                5 { $tool = 'inspect_analysis_view'; $arguments = @{ source = @{ kind = 'retained-evidence'; evidence_id = $parentId }; view = @{ kind = 'managed-members'; collection = 'methods'; offset = 0; limit = 2 } } }
                6 { $tool = 'inspect_managed_artifact'; $arguments = @{ path = (Join-Path (Split-Path $script:ReaAssemblyPath -Parent) 'absent.dll'); detail = 'summary' } }
            }
            $message = if ($tool) {
                @{ content = ''; tool_calls = @(@{ id = "rea_smoke_$turn"; type = 'function'; function = @{
                                name = 'mcp_rea_' + $tool; arguments = (ConvertTo-Json -InputObject $arguments -Depth 20 -Compress)
                            }
                        })
                }
            }
            else { @{ content = 'REA static smoke passed'; tool_calls = @() } }
            $response = @{ choices = @(@{ message = $message; finish_reason = 'stop' }) } | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            @{ Response = $response; Candidate = $State.Candidates[0]; ElapsedMilliseconds = 0 }
        }
        Export-ModuleMember -Function Invoke-AgentHarness
    }
    $result = & $module {
        param($configPath, $commandPath, $workRoot, $examplePath)
        $options = if ($configPath) { @{ McpConfigPath = $configPath; McpServer = @('rea') } }
        else {
            $configuration = Read-AgentHarnessMcpConfig -Path $examplePath -WorkingDirectory $workRoot
            $configuration.rea.Command = (Get-Command $commandPath -CommandType Application -ErrorAction Stop).Source
            @{ McpServers = $configuration }
        }
        Invoke-AgentHarness 'Synthetic static REA integration check' -WorkingDirectory $workRoot -Model synthetic-rea-smoke `
            -ChatUri https://provider.invalid/chat -NoAgentsFile -NoSkills -NoBuiltinTools -Quiet -NoPromptSound `
            -NoCompletionPrompt -NoModelRecovery -MaxToolOutputChars 32768 -PassThru -YOLO @options
    } $McpConfigPath $Command $fixture (Join-Path $repo 'Config/AgentHarness.rea.mcp.example.json')
    if ($result.Answer -ne 'REA static smoke passed' -or $result.Iterations -ne 7) { throw 'The expected static REA round trips did not finish.' }
    $processIds = @(& $module { $script:ReaClosedProcessIds.ToArray() })
    if ($processIds.Count -ne 1 -or (Get-Process -Id $processIds[0] -ErrorAction SilentlyContinue)) { throw 'The REA connection did not close its process.' }
    foreach ($path in $before.Keys) {
        if ((Get-FileHash -LiteralPath $path).Hash -ne $before[$path]) { throw 'Static inspection changed a synthetic input.' }
    }
    Write-Host 'Passed: static JavaScript/Electron analysis, managed metadata and CIL, retained Evidence paging, missing-file error, unchanged inputs, and process cleanup. Model transport mocked; no installations.'
}
finally {
    if ($module) { Remove-Module $module -Force }
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath
        $expectedRoot = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'rea-smoke-*') { throw 'Refusing to remove a fixture outside the expected isolated directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
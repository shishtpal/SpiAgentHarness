#requires -Version 7.0
# Run with pwsh -NoProfile -File ./Tests/Invoke-ModuleIntegration.Tests.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('SpiStandaloneTests-' + [guid]::NewGuid().ToString('N'))
$checks = 0
$module = $null
$previousModulePath = $env:PSModulePath
$previousAutoLoading = $PSModuleAutoLoadingPreference
$previousBootstrap = $env:IS_SPI_POWERSHELL_BOOTSTRAP

function Assert-Standalone {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}

try {
    $null = New-Item -ItemType Directory -Path $fixture
    foreach ($name in 'SpiAgentHarness.psd1', 'SpiAgentHarness.psm1', 'SpiAgentHarness.Format.ps1xml') {
        Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $fixture
    }
    foreach ($directory in 'Public', 'Private') {
        Copy-Item -LiteralPath (Join-Path $repo $directory) -Destination $fixture -Recurse
    }

    # Remove access to user-installed modules; poison external dependencies so an
    # accidental global lookup fails even if an old module is installed locally.
    $env:PSModulePath = Join-Path $PSHOME 'Modules'
    Import-Module Microsoft.PowerShell.Utility
    Import-Module Microsoft.PowerShell.Management
    $PSModuleAutoLoadingPreference = 'None'
    function global:Show-InteractiveMenu { throw 'External menu dependency used.' }
    function global:Write-LogMessage { throw 'External logging dependency used.' }
    function global:Invoke-Sound { throw 'External sound dependency used.' }
    function global:Invoke-RestMethod { throw 'Unexpected live provider request.' }
    function global:Invoke-WebRequest { throw 'Unexpected live decision request.' }

    $manifestPath = Join-Path $fixture 'SpiAgentHarness.psd1'
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $validated = Test-ModuleManifest -Path $manifestPath
    Assert-Standalone ($validated.Name -eq 'SpiAgentHarness') 'Manifest validates after relocation'
    Assert-Standalone (-not $manifest.RequiredModules -and -not $manifest.NestedModules -and -not $manifest.ScriptsToProcess) 'Manifest has no external module or initialization dependencies'
    Assert-Standalone ($manifest.PowerShellVersion -eq '7.0') 'Minimum supported PowerShell version is preserved'
    $module = Import-Module $manifestPath -PassThru -Force
    $expected = @('Get-DecisionModels', 'Get-FreeModels', 'Get-McpServer', 'Invoke-AgentHarness', 'Invoke-DecisionModel', 'Register-FreeModelProvider')
    Assert-Standalone (($module.ExportedFunctions.Keys | Sort-Object) -join ',' -ceq ($expected -join ',')) 'Exactly the six requested commands are exported'
    Assert-Standalone ($module.ExportedAliases.Count -eq 0 -and $module.ExportedVariables.Count -eq 0) 'No helper aliases or variables leak'
    Assert-Standalone (-not (Get-Module SpiPowershell)) 'Import does not load SpiPowershell'
    Assert-Standalone ($env:IS_SPI_POWERSHELL_BOOTSTRAP -eq $previousBootstrap) 'Import does not run the legacy bootstrap'
    foreach ($name in 'Show-InteractiveMenu', 'Write-LogMessage', 'Invoke-Sound') {
        $privatePath = & $module { param($command) (Get-Command $command).ScriptBlock.File } $name
        Assert-Standalone ($privatePath.StartsWith((Join-Path $fixture 'Private/Console'), [StringComparison]::OrdinalIgnoreCase)) "$name resolves to the relocated private dependency"
        Assert-Standalone (-not $module.ExportedFunctions.ContainsKey($name)) "$name remains private"
    }
    Assert-Standalone (@(Get-DecisionModels -All).Count -gt 0) 'Bundled decision catalogue works without external modules or requests'
    Assert-Standalone (@(Get-McpServer).Count -eq 0) 'Absent relocated MCP configuration starts no server'
    $root = & $module { Get-AgentHarnessDefaultSkillPath }
    Assert-Standalone ($root -eq (Join-Path $fixture '.agents/skills')) 'Default skills belong to the relocated module'

    Register-FreeModelProvider -Name StandaloneFixture -Uri 'https://provider.invalid/v1/models' -ChatUri 'https://provider.invalid/v1/chat/completions'
    $config = & $module { Get-AgentHarnessProviderConfig -Provider StandaloneFixture }
    Assert-Standalone ($config.ChatUri -eq 'https://provider.invalid/v1/chat/completions' -and -not $config.KeyEnvVar) 'Provider registration updates the module-owned registry'
    $completion = 'Invoke-AgentHarness -Provider Standalone'
    Assert-Standalone ((TabExpansion2 $completion $completion.Length).CompletionMatches.CompletionText -contains 'StandaloneFixture') 'Provider completion uses the independent registry'

    & $module {
        $script:StandaloneRequests = 0
        function script:Invoke-RestMethod {
            [CmdletBinding()]
            param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
            if ($Uri -ne 'https://provider.invalid/v1/chat/completions') { throw 'Unexpected synthetic endpoint.' }
            $script:StandaloneRequests++
            @{ choices = @(@{ message = @{ role = 'assistant'; content = 'Independent runtime completed.' }; finish_reason = 'stop' }) } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        }
    }
    $answer = Invoke-AgentHarness 'Synthetic independence check' -Provider StandaloneFixture -Model synthetic-model -WorkingDirectory $fixture -NoAgentsFile -NoSkills -NoSubAgents -NoCompletionPrompt -NoModelRecovery -NoPromptSound -Quiet
    Assert-Standalone ($answer -eq 'Independent runtime completed.' -and (& $module { $script:StandaloneRequests }) -eq 1) 'Relocated runtime completes using only its private helpers and mocked transport'
    Assert-Standalone (-not (Get-Module SpiPowershell)) 'Running the harness does not load SpiPowershell'
    Write-Host "Passed $checks standalone integration checks. Relocated fixture; no live requests or user configuration."
}
finally {
    if ($module) { Remove-Module $module -Force }
    foreach ($name in 'Show-InteractiveMenu', 'Write-LogMessage', 'Invoke-Sound', 'Invoke-RestMethod', 'Invoke-WebRequest') {
        Remove-Item -LiteralPath "Function:global:$name" -ErrorAction SilentlyContinue
    }
    $env:PSModulePath = $previousModulePath
    $PSModuleAutoLoadingPreference = $previousAutoLoading
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'SpiStandaloneTests-*') { throw 'Refusing cleanup outside the integration fixture.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
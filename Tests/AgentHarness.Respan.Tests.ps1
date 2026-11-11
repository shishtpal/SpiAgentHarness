# Run by Invoke-AgentHarness.Tests.ps1 after the fixture HTTP and menu mocks are installed.
& $module {
    param($provider)
    $script:FreeModelProviders[$provider.Name] = $provider
    $script:Catalog[$provider.Uri] = @(
        [pscustomobject]@{ id = 'respan-paid'; context_length = 128000; pricing = [pscustomobject]@{ input_cost = 0.15; output_cost = 0.6; input_price_unit = 'token'; output_price_unit = 'token' } },
        [pscustomobject]@{ id = 'respan-zero'; name = 'Respan Zero'; context_length = 64000; pricing = [pscustomobject]@{ input_cost = 0; output_cost = 0 } },
        [pscustomobject]@{ id = 'respan-unknown'; pricing = [pscustomobject]@{ input_cost = $null; output_cost = $null } },
        [pscustomobject]@{ id = 'respan-unknown:free' },
        [pscustomobject]@{ id = 'respan-partial'; pricing = [pscustomobject]@{ input_cost = 0 } },
        [pscustomobject]@{ id = 'respan-invalid'; pricing = [pscustomobject]@{ input_cost = ''; output_cost = 'invalid' } },
        [pscustomobject]@{ id = 'respan-output-paid'; pricing = [pscustomobject]@{ input_cost = 0; output_cost = 0.6 } }
    )
} $respanProvider
$previousRespanKey = [Environment]::GetEnvironmentVariable('RESPAN_API_KEY')
try {
    [Environment]::SetEnvironmentVariable('RESPAN_API_KEY', $null)
    $models = @(Get-FreeModels -Provider Respan -All)
    $request = & $module { $script:CatalogRequests[-1] }
    Assert-Harness ($models.Count -eq 7 -and -not $request.Headers.ContainsKey('Authorization')) 'Respan supports public discovery without a key'
    Assert-Harness ($models[0].Id -eq 'respan-paid' -and $models[0].Name -eq 'respan-paid' -and $models[0].Context -eq 128000) 'Respan discovery preserves catalogue ids and context with id as display-name fallback'
    foreach ($preference in 'Continue', 'Stop') {
        & {
            $ErrorActionPreference = $preference
            Assert-Harness ((@(Get-FreeModels -Provider Respan).Id -join ',') -eq 'respan-zero') "Respan free detection requires two explicit zero prices under $preference"
        }
    }
    Assert-Harness ((@(Get-FreeModels -Provider Respan -All -Name '*Zero').Id -join ',') -eq 'respan-zero') 'Respan discovery filters display names'

    [Environment]::SetEnvironmentVariable('RESPAN_API_KEY', 'fake-respan-test-key')
    $null = Get-FreeModels -Provider Respan -All
    $request = & $module { $script:CatalogRequests[-1] }
    Assert-Harness ($request.Uri -eq $respanProvider.Uri -and $request.Headers.Authorization -eq 'Bearer fake-respan-test-key') 'Respan authenticated discovery uses the project key'

    $respan = @{ Provider = 'Respan'; Quiet = $true; NoBuiltinTools = $true; NoAgentsFile = $true; WorkingDirectory = $fixture; NoModelRecovery = $true }
    Set-HarnessRecoveryChoices @(0)
    Set-HarnessResponses @((New-HarnessResponse 'respan picked'))
    $picked = Invoke-AgentHarness 'Pick a Respan model' @respan -Pick -All -PassThru
    Assert-Harness ($picked.Provider -eq 'Respan' -and $picked.Model -eq 'respan-paid' -and (& $module { $script:RecoveryMenus[0].Options.Count }) -eq 7) 'Respan Pick All offers the full catalogue'

    $respanTools = @{ echo = @{ Script = { param($a, $ctx) "echo:$($a.text)" } } }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall echo '{"text":"respan tool"}'))), (New-HarnessResponse 'respan complete'))
    $result = Invoke-AgentHarness 'Use echo' @respan -All -ModelFilter 'respan-paid' -Tools $respanTools -PassThru
    $requests = @(Get-HarnessRequests)
    Assert-Harness ($result.Answer -eq 'respan complete' -and $result.Model -eq 'respan-paid' -and $requests.Count -eq 2) 'Respan auto-selection completes a tool-calling round trip'
    Assert-Harness (@($requests | Where-Object { $_.Uri -ne $respanProvider.ChatUri -or $_.Headers.Authorization -ne 'Bearer fake-respan-test-key' }).Count -eq 0) 'Respan chat uses the gateway and environment key'
    Assert-Harness ($requests[0].Body.tools[0].function.name -eq 'echo' -and $requests[0].Body.tool_choice -eq 'auto') 'Respan sends standard tool definitions and tool choice'
    Assert-Harness ($requests[1].Body.messages[-1].role -eq 'tool' -and $requests[1].Body.messages[-1].tool_call_id -eq 'call_test' -and $requests[1].Body.messages[-1].content -eq 'echo:respan tool') 'Respan tool results preserve call ids and content'

    [Environment]::SetEnvironmentVariable('RESPAN_API_KEY', $null)
    $catalogCount = & $module { $script:CatalogRequests.Count }
    Set-HarnessResponses @((New-HarnessApiError 429), (New-HarnessResponse 'respan override'))
    $explicit = Invoke-AgentHarness 'Say hi' @respan -Model respan-custom -ApiKey fake-override-key -ChatUri 'https://provider.invalid/respan/override'
    $requests = @(Get-HarnessRequests)
    Assert-Harness ($explicit -eq 'respan override' -and $requests.Count -eq 2 -and $requests[-1].Body.model -eq 'respan-custom' -and (& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Explicit Respan models bypass discovery and use existing retries'
    Assert-Harness ($requests[-1].Uri -eq 'https://provider.invalid/respan/override' -and $requests[-1].Headers.Authorization -eq 'Bearer fake-override-key') 'Respan connection overrides take precedence'

    & $module { $script:CatalogResponses[$script:FreeModelProviders['Respan'].Uri] = [Exception]::new('mock Respan catalogue failure') }
    foreach ($preference in 'Continue', 'Stop') {
        & {
            $ErrorActionPreference = $preference
            $warnings = @()
            $models = @(Get-FreeModels -Provider Respan -All -WarningVariable warnings 3>$null)
            Assert-Harness ($models.Count -eq 0 -and ($warnings -join ' ') -like '*mock Respan catalogue failure*') "Respan catalogue failures warn under $preference"
        }
    }
}
finally {
    [Environment]::SetEnvironmentVariable('RESPAN_API_KEY', $previousRespanKey)
    & $module { $script:FreeModelProviders.Remove('Respan') }
}
# Run by Invoke-AgentHarness.Tests.ps1 after the fixture HTTP and menu mocks are installed.
& $module {
    param($provider)
    $script:FreeModelProviders[$provider.Name] = $provider
    $script:Catalog[$provider.Uri] = @(
        [pscustomobject]@{ id = 'arena-test-paid'; name = 'Arena Paid'; context_length = 128000; pricing = [pscustomobject]@{ prompt = '0.00000025'; completion = '0.00000075' } },
        [pscustomobject]@{ id = 'arena-test-zero'; name = 'Arena Zero'; context_length = 260000; pricing = [pscustomobject]@{ prompt = '0'; completion = '0' } },
        [pscustomobject]@{ id = 'arena-test-unknown'; name = 'Arena Unknown' },
        [pscustomobject]@{ id = 'coding-router-preview'; name = 'Arena Coding Router'; type = 'routing'; supported_models = @('arena-test-paid') }
    )
} $arenaProvider
$previousArenaKey = [Environment]::GetEnvironmentVariable('ARENA_API_KEY')
try {
    [Environment]::SetEnvironmentVariable('ARENA_API_KEY', $null)
    $catalogCount = & $module { $script:CatalogRequests.Count }
    $warnings = @()
    $models = @(Get-FreeModels -Provider Arena -All -WarningVariable warnings 3>$null)
    Assert-Harness ($models.Count -eq 0 -and ($warnings -join ' ') -like '*ARENA_API_KEY*') 'Missing Arena key warns and skips discovery'
    Assert-Harness ((& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Missing Arena key sends no catalogue request'

    [Environment]::SetEnvironmentVariable('ARENA_API_KEY', 'fake-arena-test-key')
    $models = @(Get-FreeModels -Provider Arena -All)
    $catalogRequest = & $module { $script:CatalogRequests[-1] }
    Assert-Harness (($models.Id -join ',') -eq 'arena-test-paid,arena-test-zero,arena-test-unknown,coding-router-preview') 'Arena All includes paid, zero-price, unknown-price and routing entries'
    Assert-Harness ($models[0].Provider -eq 'Arena' -and $models[0].Name -eq 'Arena Paid' -and $models[0].Context -eq 128000) 'Arena discovery preserves model metadata'
    Assert-Harness ($catalogRequest.Uri -eq $arenaProvider.Uri -and $catalogRequest.Headers.Authorization -eq 'Bearer fake-arena-test-key') 'Arena discovery uses the authenticated catalogue'
    Assert-Harness ((@(Get-FreeModels -Provider Arena).Id -join ',') -eq 'arena-test-zero') 'Arena default discovery includes only models reporting zero input and output prices'
    Assert-Harness ((@(Get-FreeModels -Provider Arena -All -Name '*Unknown').Id -join ',') -eq 'arena-test-unknown') 'Arena discovery filters by display name'

    $arena = @{ Provider = 'Arena'; Quiet = $true; NoBuiltinTools = $true; NoAgentsFile = $true; WorkingDirectory = $fixture; NoModelRecovery = $true }
    Set-HarnessRecoveryChoices @(0)
    Set-HarnessResponses @((New-HarnessResponse 'arena picked'))
    $picked = Invoke-AgentHarness 'Pick an Arena model' @arena -Pick -All -PassThru
    Assert-Harness ($picked.Provider -eq 'Arena' -and $picked.Model -eq 'arena-test-paid' -and (& $module { $script:RecoveryMenus[0].Options.Count }) -eq 4) 'Arena Pick All offers the full catalogue'

    $arenaTools = @{ echo = @{ Script = { param($a, $ctx) "echo:$($a.text)" } } }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall echo '{"text":"arena tool"}'))), (New-HarnessResponse 'arena complete'))
    $roundTrip = Invoke-AgentHarness 'Use echo' @arena -All -ModelFilter '*paid' -Tools $arenaTools -PassThru
    $requests = @(Get-HarnessRequests)
    Assert-Harness ($roundTrip.Answer -eq 'arena complete' -and $roundTrip.Model -eq 'arena-test-paid' -and $requests.Count -eq 2) 'Arena auto-selection completes a tool-calling round trip'
    Assert-Harness (@($requests | Where-Object { $_.Uri -ne $arenaProvider.ChatUri -or $_.Headers.Authorization -ne 'Bearer fake-arena-test-key' }).Count -eq 0) 'Arena chat uses the registered endpoint and environment key'
    Assert-Harness ($requests[0].Body.tools[0].function.name -eq 'echo' -and $requests[0].Body.tool_choice -eq 'auto') 'Arena sends standard tool definitions and automatic tool choice'
    Assert-Harness ($requests[0].Body.stream -and $requests[0].Body.stream_options.include_usage) 'Arena uses default streaming with usage reporting'
    Assert-Harness ($requests[1].Body.messages[-1].role -eq 'tool' -and $requests[1].Body.messages[-1].tool_call_id -eq 'call_test' -and $requests[1].Body.messages[-1].content -eq 'echo:arena tool') 'Arena tool results preserve call ids and content'

    [Environment]::SetEnvironmentVariable('ARENA_API_KEY', $null)
    $catalogCount = & $module { $script:CatalogRequests.Count }
    Set-HarnessResponses @((New-HarnessApiError 429), (New-HarnessResponse 'arena override'))
    $explicit = Invoke-AgentHarness 'Say hi' @arena -Model arena-custom -ApiKey fake-override-key -ChatUri 'https://provider.invalid/arena/override'
    $requests = @(Get-HarnessRequests)
    Assert-Harness ($explicit -eq 'arena override' -and $requests[-1].Body.model -eq 'arena-custom' -and (& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Explicit Arena models bypass discovery and use existing retries even without an environment key'
    Assert-Harness ($requests[-1].Uri -eq 'https://provider.invalid/arena/override' -and $requests[-1].Headers.Authorization -eq 'Bearer fake-override-key') 'Arena connection overrides take precedence'

    [Environment]::SetEnvironmentVariable('ARENA_API_KEY', 'fake-arena-test-key')
    & $module { $script:CatalogResponses[$script:FreeModelProviders['Arena'].Uri] = [Exception]::new('mock Arena catalogue failure') }
    foreach ($preference in 'Continue', 'Stop') {
        & {
            $ErrorActionPreference = $preference
            $warnings = @()
            $models = @(Get-FreeModels -Provider Arena -All -WarningVariable warnings 3>$null)
            Assert-Harness ($models.Count -eq 0 -and ($warnings -join ' ') -like '*mock Arena catalogue failure*') "Arena catalogue failures warn under $preference"
        }
    }
}
finally {
    [Environment]::SetEnvironmentVariable('ARENA_API_KEY', $previousArenaKey)
    & $module { $script:FreeModelProviders.Remove('Arena') }
}
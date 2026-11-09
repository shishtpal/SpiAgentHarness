# Run by Invoke-AgentHarness.Tests.ps1 after the fixture HTTP and menu mocks are installed.
& $module {
    param($provider)
    $script:FreeModelProviders[$provider.Name] = $provider
    $script:Catalog[$provider.Uri] = @(
        [pscustomobject]@{ id = 'mercury-test-paid'; name = 'Mercury Paid'; context_length = 128000; pricing = [pscustomobject]@{ prompt = '0.00000025'; completion = '0.00000075' } },
        [pscustomobject]@{ id = 'mercury-test-zero'; name = 'Mercury Zero'; context_length = 260000; pricing = [pscustomobject]@{ prompt = '0'; completion = '0' } },
        [pscustomobject]@{ id = 'mercury-test-unknown'; name = 'Mercury Unknown' }
    )
} $inceptionProvider
$previousInceptionKey = [Environment]::GetEnvironmentVariable('INCEPTION_API_KEY')
try {
    [Environment]::SetEnvironmentVariable('INCEPTION_API_KEY', $null)
    $catalogCount = & $module { $script:CatalogRequests.Count }
    $warnings = @()
    $models = @(Get-FreeModels -Provider Inception -All -WarningVariable warnings 3>$null)
    Assert-Harness ($models.Count -eq 0 -and ($warnings -join ' ') -like '*INCEPTION_API_KEY*') 'Missing Inception key warns and skips discovery'
    Assert-Harness ((& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Missing Inception key sends no catalogue request'

    [Environment]::SetEnvironmentVariable('INCEPTION_API_KEY', 'fake-inception-test-key')
    $models = @(Get-FreeModels -Provider Inception -All)
    $catalogRequest = & $module { $script:CatalogRequests[-1] }
    Assert-Harness (($models.Id -join ',') -eq 'mercury-test-paid,mercury-test-zero,mercury-test-unknown') 'Inception All includes paid, zero-price and unknown-price chat models'
    Assert-Harness ($models[0].Provider -eq 'Inception' -and $models[0].Name -eq 'Mercury Paid' -and $models[0].Context -eq 128000) 'Inception discovery preserves model metadata'
    Assert-Harness ($catalogRequest.Uri -eq $inceptionProvider.Uri -and $catalogRequest.Headers.Authorization -eq 'Bearer fake-inception-test-key') 'Inception discovery uses the authenticated chat-only catalogue'
    Assert-Harness ((@(Get-FreeModels -Provider Inception).Id -join ',') -eq 'mercury-test-zero') 'Inception default discovery includes only models reporting zero input and output prices'
    Assert-Harness ((@(Get-FreeModels -Provider Inception -All -Name '*Unknown').Id -join ',') -eq 'mercury-test-unknown') 'Inception discovery filters by display name'

    $inception = @{ Provider = 'Inception'; Quiet = $true; NoBuiltinTools = $true; NoAgentsFile = $true; WorkingDirectory = $fixture; NoModelRecovery = $true }
    Set-HarnessRecoveryChoices @(0)
    Set-HarnessResponses @((New-HarnessResponse 'inception picked'))
    $picked = Invoke-AgentHarness 'Pick an Inception model' @inception -Pick -All -PassThru
    Assert-Harness ($picked.Provider -eq 'Inception' -and $picked.Model -eq 'mercury-test-paid' -and (& $module { $script:RecoveryMenus[0].Options.Count }) -eq 3) 'Inception Pick All offers the full chat catalogue'

    $inceptionTools = @{ echo = @{ Script = { param($a, $ctx) "echo:$($a.text)" } } }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall echo '{"text":"inception tool"}'))), (New-HarnessResponse 'inception complete'))
    $roundTrip = Invoke-AgentHarness 'Use echo' @inception -All -ModelFilter '*paid' -Tools $inceptionTools -PassThru
    $requests = @(Get-HarnessRequests)
    Assert-Harness ($roundTrip.Answer -eq 'inception complete' -and $roundTrip.Model -eq 'mercury-test-paid' -and $requests.Count -eq 2) 'Inception auto-selection completes a tool-calling round trip'
    Assert-Harness (@($requests | Where-Object { $_.Uri -ne $inceptionProvider.ChatUri -or $_.Headers.Authorization -ne 'Bearer fake-inception-test-key' }).Count -eq 0) 'Inception chat uses the registered endpoint and environment key'
    Assert-Harness ($requests[0].Body.tools[0].function.name -eq 'echo' -and $requests[0].Body.tool_choice -eq 'auto') 'Inception sends standard tool definitions and automatic tool choice'
    Assert-Harness ($requests[1].Body.messages[-1].role -eq 'tool' -and $requests[1].Body.messages[-1].tool_call_id -eq 'call_test' -and $requests[1].Body.messages[-1].content -eq 'echo:inception tool') 'Inception tool results preserve call ids and content'

    [Environment]::SetEnvironmentVariable('INCEPTION_API_KEY', $null)
    $catalogCount = & $module { $script:CatalogRequests.Count }
    Set-HarnessResponses @((New-HarnessApiError 429), (New-HarnessResponse 'inception override'))
    $explicit = Invoke-AgentHarness 'Say hi' @inception -Model mercury-custom -ApiKey fake-override-key -ChatUri 'https://provider.invalid/inception/override'
    $requests = @(Get-HarnessRequests)
    Assert-Harness ($explicit -eq 'inception override' -and $requests[-1].Body.model -eq 'mercury-custom' -and (& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Explicit Inception models bypass discovery and use existing retries even without an environment key'
    Assert-Harness ($requests[-1].Uri -eq 'https://provider.invalid/inception/override' -and $requests[-1].Headers.Authorization -eq 'Bearer fake-override-key') 'Inception connection overrides take precedence'

    [Environment]::SetEnvironmentVariable('INCEPTION_API_KEY', 'fake-inception-test-key')
    & $module { $script:CatalogResponses[$script:FreeModelProviders['Inception'].Uri] = [Exception]::new('mock Inception catalogue failure') }
    foreach ($preference in 'Continue', 'Stop') {
        & {
            $ErrorActionPreference = $preference
            $warnings = @()
            $models = @(Get-FreeModels -Provider Inception -All -WarningVariable warnings 3>$null)
            Assert-Harness ($models.Count -eq 0 -and ($warnings -join ' ') -like '*mock Inception catalogue failure*') "Inception catalogue failures warn under $preference"
        }
    }
}
finally {
    [Environment]::SetEnvironmentVariable('INCEPTION_API_KEY', $previousInceptionKey)
    & $module { $script:FreeModelProviders.Remove('Inception') }
}
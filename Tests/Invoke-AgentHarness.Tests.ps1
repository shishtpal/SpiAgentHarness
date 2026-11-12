#requires -Version 7.0
# Run with: pwsh -NoProfile -File ./Tests/Invoke-AgentHarness.Tests.ps1
# Import the real standalone manifest and loader from a fixture without user configuration or skills.
param(
    [switch]$DecisionToolsOnly,
    [switch]$SearchFilesOnly,
    [switch]$PromptHistoryOnly,
    [switch]$ContextOnly,
    [switch]$ProfilesOnly,
    [switch]$AutoCompactOnly,
    [switch]$StreamingOnly,
    [switch]$ShellOnly,
    [switch]$PythonOnly
)

$ErrorActionPreference = 'Stop'
# Test dependencies must never auto-load a user-installed legacy module.
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('SpiHarnessTests-' + [guid]::NewGuid().ToString('N'))
$checks = 0
$module = $null

# Existing single-task tests opt out; completion tests below exercise the default.
$PSDefaultParameterValues['Invoke-AgentHarness:NoCompletionPrompt'] = $true
$PSDefaultParameterValues['Invoke-AgentHarness:NoSkills'] = $true # Never send real user skill metadata to mocked providers.

function Assert-Harness {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}

function Assert-HarnessThrows {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-Harness ($null -ne $caught -and $caught -like $Pattern) "Expected error '$Pattern'; got '$caught'"
}

function New-HarnessResponse {
    param([string]$Text = 'done', [object[]]$Calls = @())
    # Match Invoke-RestMethod's PSCustomObject shape, rather than mocking hashtables.
    @{
        model   = 'served-model'
        usage   = @{ prompt_tokens = 10; completion_tokens = 2 }
        choices = @(@{
                finish_reason = ($Calls.Count ? 'tool_calls' : 'stop')
                message       = @{ role = 'assistant'; content = $Text; tool_calls = $Calls }
            })
    } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function New-HarnessCall {
    param([string]$Name, [object]$Arguments = '{}', [string]$Id = 'call_test')
    @{ id = $Id; type = 'function'; function = @{ name = $Name; arguments = $Arguments } }
}

function New-HarnessApiError {
    param([int]$Status)
    $errorObject = [Exception]::new('mock API failure')
    $errorObject.Data['Status'] = $Status
    $errorObject
}

function Set-HarnessResponses {
    param([object[]]$Responses)
    & $script:module {
        param($items)
        $script:Requests.Clear()
        $script:Delays.Clear()
        $script:Responses.Clear()
        foreach ($item in $items) { $script:Responses.Enqueue($item) }
    } $Responses
}

function Get-HarnessRequests { & $script:module { $script:Requests.ToArray() } }

function Set-HarnessRecoveryChoices {
    param([object[]]$Choices, [string[]]$ModelIds = @())
    & $script:module {
        param($items, $ids)
        $script:RecoveryChoices.Clear()
        $script:RecoveryMenus.Clear()
        $script:RecoveryModelIds.Clear()
        foreach ($item in $items) { $script:RecoveryChoices.Enqueue($item) }
        foreach ($id in $ids) { $script:RecoveryModelIds.Enqueue($id) }
    } $Choices $ModelIds
}

try {
    $null = New-Item -ItemType Directory -Path $fixture
    foreach ($directory in 'Public', 'Private', 'Config') {
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture $directory)
    }
    foreach ($name in 'SpiAgentHarness.psm1', 'SpiAgentHarness.psd1', 'SpiAgentHarness.Format.ps1xml') {
        Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $fixture
    }
    foreach ($directory in 'Public', 'Private') {
        foreach ($entry in Get-ChildItem -LiteralPath (Join-Path $repo $directory)) {
            Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $fixture $directory) -Recurse
        }
    }
    foreach ($name in 'decision.json', 'decide_screen_target.json') {
        Copy-Item -LiteralPath (Join-Path $repo "Config/$name") -Destination (Join-Path $fixture 'Config')
    }
    $privateFiles = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'Private') -Filter '*.ps1' -Recurse)
    $manifestPath = Join-Path $fixture 'SpiAgentHarness.psd1'

    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $fixture 'Public') -Filter '*.ps1') + $privateFiles) {
        $tokens = $null; $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-Harness ($parseErrors.Count -eq 0) "Parse $($file.Name): $($parseErrors.Message -join '; ')"
    }
    $module = Import-Module $manifestPath -PassThru -Force
    Assert-Harness ($module.ExportedFunctions.ContainsKey('Invoke-AgentHarness')) 'Manifest exports the harness'
    Assert-Harness ($module.ExportedFunctions.ContainsKey('Get-McpServer')) 'Manifest exports configured MCP server listing'
    Assert-Harness (@($module.ExportedFunctions.Keys | Where-Object { $_ -like '*-AgentHarness*' -and $_ -ne 'Invoke-AgentHarness' }).Count -eq 0) 'Helpers remain private'
    $experientialProvider = & $module { $script:FreeModelProviders['ExperientialLabs'] }
    Assert-Harness ($null -ne $experientialProvider) 'Experiential Labs is registered on import'
    Assert-Harness ($experientialProvider.Uri -eq 'https://api.experientiallabs.ai/api/v1/models' -and $experientialProvider.RequireKey -and $experientialProvider.KeyEnvVar -eq 'EXPLABS_API_KEY') 'Experiential Labs catalogue and key configuration'
    Assert-Harness ($experientialProvider.ChatUri -eq 'https://api.experientiallabs.ai/v1/chat/completions') 'Registration preserves an explicit chat endpoint'
    $cohereProvider = & $module { $script:FreeModelProviders['Cohere'] }
    Assert-Harness ($null -ne $cohereProvider -and $cohereProvider.RequireKey -and $cohereProvider.KeyEnvVar -eq 'COHERE_API_KEY') 'Cohere is registered and requires its configured key'
    Assert-Harness ($cohereProvider.Uri -eq 'https://api.cohere.com/v1/models?endpoint=chat&page_size=1000' -and $cohereProvider.ChatUri -eq 'https://api.cohere.ai/compatibility/v1/chat/completions' -and $cohereProvider.OmitToolChoice) 'Cohere uses chat-only discovery and the compatible chat endpoint'
    Assert-Harness (-not $module.ExportedFunctions.ContainsKey('Get-CohereModels')) 'Cohere discovery helper remains private'
    $inceptionProvider = & $module { $script:FreeModelProviders['Inception'] }
    Assert-Harness ($null -ne $inceptionProvider -and $inceptionProvider.RequireKey -and $inceptionProvider.KeyEnvVar -eq 'INCEPTION_API_KEY') 'Inception is registered and requires its configured key'
    Assert-Harness ($inceptionProvider.Uri -eq 'https://api.inceptionlabs.ai/v1/chat/completions/models' -and $inceptionProvider.ChatUri -eq 'https://api.inceptionlabs.ai/v1/chat/completions' -and -not $inceptionProvider.OmitToolChoice) 'Inception uses chat-only discovery, an explicit chat endpoint and standard tool choice'
    $respanProvider = & $module { $script:FreeModelProviders['Respan'] }
    Assert-Harness ($null -ne $respanProvider -and -not $respanProvider.RequireKey -and $respanProvider.KeyEnvVar -eq 'RESPAN_API_KEY') 'Respan is registered with optional catalogue authentication'
    Assert-Harness ($respanProvider.Uri -eq 'https://api.respan.ai/api/v1/models' -and $respanProvider.ChatUri -eq 'https://gateway.respan.ai/chat/completions' -and -not $respanProvider.OmitToolChoice) 'Respan uses its documented catalogue, gateway and standard tool choice'
    foreach ($command in 'Get-FreeModels', 'Invoke-AgentHarness') {
        $providerCompletion = "$command -Provider Resp"
        $matches = TabExpansion2 $providerCompletion $providerCompletion.Length
        Assert-Harness ($matches.CompletionMatches.CompletionText -contains 'Respan') "$command completes Respan"
        $providerCompletion = "$command -Provider Exper"
        $matches = TabExpansion2 $providerCompletion $providerCompletion.Length
        Assert-Harness ($matches.CompletionMatches.CompletionText -contains 'ExperientialLabs') "$command completes ExperientialLabs"
        $providerCompletion = "$command -Provider Coh"
        $matches = TabExpansion2 $providerCompletion $providerCompletion.Length
        Assert-Harness ($matches.CompletionMatches.CompletionText -contains 'Cohere') "$command completes Cohere"
        $providerCompletion = "$command -Provider Ince"
        $matches = TabExpansion2 $providerCompletion $providerCompletion.Length
        Assert-Harness ($matches.CompletionMatches.CompletionText -contains 'Inception') "$command completes Inception"
    }
    $completionText = 'Invoke-AgentHarness -Provider Test'

    & $module {
        $script:FreeModelProviders = [ordered]@{}
        Register-FreeModelProvider -Name TestA -Uri https://provider.invalid/a/v1/models
        Register-FreeModelProvider -Name TestB -Uri https://provider.invalid/b/v1/models
        $script:Requests = [Collections.Generic.List[object]]::new()
        $script:CatalogRequests = [Collections.Generic.List[object]]::new()
        $script:Responses = [Collections.Generic.Queue[object]]::new()
        $script:Delays = [Collections.Generic.List[int]]::new()
        $script:CatalogResponses = @{}
        $script:Catalog = @{
            'https://provider.invalid/a/v1/models' = @(
                [pscustomobject]@{ id = 'first:free'; name = 'first' },
                [pscustomobject]@{ id = 'second:free'; name = 'second' }
            )
            'https://provider.invalid/b/v1/models' = @([pscustomobject]@{ id = 'third:free'; name = 'third' })
        }
        function script:Invoke-RestMethod {
            [CmdletBinding()]
            param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
            if ($Method -ne 'Post') {
                $script:CatalogRequests.Add([pscustomobject]@{ Uri = $Uri; Headers = $Headers })
                if ($script:CatalogResponses.ContainsKey($Uri)) {
                    $response = $script:CatalogResponses[$Uri]
                    if ($response -is [Exception]) { throw $response }
                    return $response
                }
                if (-not $script:Catalog.ContainsKey($Uri)) { throw "Unmocked model catalogue: $Uri" }
                return [pscustomobject]@{ data = $script:Catalog[$Uri] }
            }
            $script:Requests.Add([pscustomobject]@{
                    Uri = $Uri; Headers = $Headers; Body = ($Body | ConvertFrom-Json); Timeout = $TimeoutSec
                })
            if (-not $script:Responses.Count) { throw 'No mocked response remains; network access is disabled.' }
            $next = $script:Responses.Dequeue()
            if ($next -is [Exception]) { throw $next }
            $next
        }
        function script:Start-Sleep { param([int]$Seconds) $script:Delays.Add($Seconds) }
        function script:New-AgentHarnessChatClient { throw 'Unexpected live streaming request.' }
        function script:Invoke-AgentHarnessChatRequest {
            param($Uri, $Headers, $Json, $TimeoutSec, [switch]$Stream, $OnText)
            # Behavioral suites use completed provider responses; streaming has its own transport suite.
            Invoke-RestMethod -Method Post -Uri $Uri -Headers $Headers -ContentType 'application/json' -Body $Json -TimeoutSec $TimeoutSec
        }
    }
    if ($StreamingOnly -or -not ($DecisionToolsOnly -or $SearchFilesOnly -or $PromptHistoryOnly -or $ContextOnly -or $ProfilesOnly -or $AutoCompactOnly -or $ShellOnly -or $PythonOnly)) {
        . (Join-Path $PSScriptRoot 'AgentHarness.Streaming.Tests.ps1')
        if ($StreamingOnly) {
            Write-Host "Passed $checks streaming checks. Isolated fixture and synthetic HTTP handler; no live requests."
            return
        }
    }
    if ($ShellOnly) {
        . (Join-Path $PSScriptRoot 'AgentHarness.Shell.Tests.ps1')
        Write-Host "Passed $checks shell checks. Isolated fixture, synthetic processes and mocked providers."
        return
    }
    if ($PythonOnly) {
        . (Join-Path $PSScriptRoot 'AgentHarness.Python.Tests.ps1')
        Write-Host "Passed $checks Python checks. Isolated fixture and synthetic runtimes; no live downloads."
        return
    }
    if ($DecisionToolsOnly) {
        . (Join-Path $PSScriptRoot 'AgentHarness.Decisions.Tests.ps1')
        Write-Host "Passed $checks focused decision-tool checks. Isolated fixture and mocked providers."
        return
    }
    if ($SearchFilesOnly) {
        $searchRoot = Join-Path $fixture 'search-fixture'
        $null = New-Item -ItemType Directory -Path $searchRoot
        . (Join-Path $PSScriptRoot 'AgentHarness.SearchFiles.Tests.ps1')
        Write-Host "Passed $checks focused search-tool checks. Isolated fixture and mocked providers."
        return
    }
    $completion = TabExpansion2 $completionText $completionText.Length
    Assert-Harness (($completion.CompletionMatches.CompletionText -join ',') -eq 'TestA,TestB') 'Provider completion sees the module registry'

    # Test the real built-in registration with synthetic catalogues and no network.
    & $module {
        param($provider)
        $script:FreeModelProviders[$provider.Name] = $provider
        $script:Catalog[$provider.Uri] = @(
            [pscustomobject]@{ id = 'example/promotional:free'; name = 'Promotional'; context_length = 32000 },
            [pscustomobject]@{ id = 'example/zero-priced'; name = 'Zero priced'; pricing = [pscustomobject]@{ prompt = '0'; completion = '0' } },
            [pscustomobject]@{ id = 'example/paid'; pricing = [pscustomobject]@{ prompt = '0.001'; completion = '0.002' } },
            [pscustomobject]@{ id = 'example/unknown-price' }
        )
    } $experientialProvider
    $previousExperientialKey = [Environment]::GetEnvironmentVariable('EXPLABS_API_KEY')
    try {
        [Environment]::SetEnvironmentVariable('EXPLABS_API_KEY', $null)
        $catalogCount = & $module { $script:CatalogRequests.Count }
        $providerWarnings = @()
        $models = @(Get-FreeModels -Provider ExperientialLabs -WarningVariable providerWarnings 3>$null)
        Assert-Harness ($models.Count -eq 0 -and ($providerWarnings -join ' ') -like '*EXPLABS_API_KEY*') 'Missing Experiential Labs key skips discovery with a useful warning'
        Assert-Harness ((& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Missing required key does not send a catalogue request'

        [Environment]::SetEnvironmentVariable('EXPLABS_API_KEY', 'fake-experiential-test-key')
        $models = @(Get-FreeModels -Provider ExperientialLabs)
        $catalogRequest = & $module { $script:CatalogRequests[-1] }
        Assert-Harness (($models.Id -join ',') -eq 'example/promotional:free,example/zero-priced') 'Experiential discovery includes free lanes and zero pricing, excluding paid and unknown prices'
        Assert-Harness ($models[0].Provider -eq 'ExperientialLabs' -and $models[0].Name -eq 'Promotional' -and $models[0].Context -eq 32000) 'Experiential discovery preserves model metadata'
        Assert-Harness ($catalogRequest.Uri -eq $experientialProvider.Uri -and $catalogRequest.Headers.Authorization -eq 'Bearer fake-experiential-test-key') 'Experiential discovery uses the integration catalogue and Bearer key'
        Assert-Harness (@(Get-FreeModels -Provider ExperientialLabs -Name '*zero*').Count -eq 1) 'Experiential discovery supports wildcard filtering'

        $experiential = @{ Provider = 'ExperientialLabs'; Quiet = $true; NoBuiltinTools = $true; NoAgentsFile = $true; WorkingDirectory = $fixture; NoModelRecovery = $true }
        $providerTools = @{ echo = @{ Script = { param($a, $ctx) "echo:$($a.text)" } } }
        Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall echo '{"text":"provider tool"}'))), (New-HarnessResponse 'experiential complete'))
        $providerResult = Invoke-AgentHarness 'Use the echo tool' @experiential -ModelFilter '*promotional*' -Tools $providerTools -PassThru
        $providerRequests = @(Get-HarnessRequests)
        Assert-Harness ($providerResult.Answer -eq 'experiential complete' -and $providerResult.Provider -eq 'ExperientialLabs' -and $providerResult.Model -eq 'example/promotional:free') 'Harness auto-selects an Experiential free model'
        Assert-Harness ($providerRequests.Count -eq 2 -and @($providerRequests | Where-Object Uri -ne $experientialProvider.ChatUri).Count -eq 0) 'Experiential tool round trip uses the registered canonical chat endpoint'
        Assert-Harness (@($providerRequests | Where-Object { $_.Headers.Authorization -ne 'Bearer fake-experiential-test-key' }).Count -eq 0) 'Experiential harness reads the registered environment key'
        Assert-Harness ($providerRequests[0].Body.tools[0].function.name -eq 'echo' -and $providerRequests[1].Body.messages[-1].role -eq 'tool' -and $providerRequests[1].Body.messages[-1].content -eq 'echo:provider tool') 'Experiential requests carry tool definitions and tool results'

        $catalogCount = & $module { $script:CatalogRequests.Count }
        Set-HarnessResponses @((New-HarnessResponse 'explicit model'))
        $explicitResult = Invoke-AgentHarness 'Say hi' @experiential -Model 'example/custom-model' -ApiKey 'fake-override-key' -ChatUri 'https://provider.invalid/override'
        $explicitRequest = @(Get-HarnessRequests)[0]
        Assert-Harness ($explicitResult -eq 'explicit model' -and $explicitRequest.Body.model -eq 'example/custom-model' -and (& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Explicit Experiential model bypasses free discovery'
        Assert-Harness ($explicitRequest.Uri -eq 'https://provider.invalid/override' -and $explicitRequest.Headers.Authorization -eq 'Bearer fake-override-key') 'Connection overrides take precedence over Experiential registration'
    }
    finally {
        [Environment]::SetEnvironmentVariable('EXPLABS_API_KEY', $previousExperientialKey)
        & $module { $script:FreeModelProviders.Remove('ExperientialLabs') }
    }

    $basic = @{ Model = 'custom-model'; ChatUri = 'https://provider.invalid/chat'; Quiet = $true; NoBuiltinTools = $true; WorkingDirectory = $fixture; NoModelRecovery = $true }
    if ($AutoCompactOnly) {
        . (Join-Path $PSScriptRoot 'AgentHarness.AutoCompact.Tests.ps1')
        Write-Host "Passed $checks focused auto-compaction checks. Synthetic inputs and mocked providers only."
        return
    }
    if ($ProfilesOnly) {
        . (Join-Path $PSScriptRoot 'AgentHarness.Profiles.Tests.ps1')
        Write-Host "Passed $checks focused profile checks. Isolated fixture and mocked providers."
        return
    }
    if ($ContextOnly) {
        . (Join-Path $PSScriptRoot 'AgentHarness.Context.Tests.ps1')
        Write-Host "Passed $checks context fixture checks. Synthetic inputs and mocked providers only."
        return
    }
    if ($PromptHistoryOnly) {
        . (Join-Path $PSScriptRoot 'AgentHarness.PromptHistory.Tests.ps1')
        Write-Host "Passed $checks prompt-history fixture checks. Synthetic inputs and mocked providers only."
        return
    }
    Set-HarnessResponses @((New-HarnessResponse 'hello'))
    $info = @()
    $result = Invoke-AgentHarness 'hello' @basic -PassThru -ApiKey fake-test-key -Temperature 0.25 -TimeoutSec 12 -InformationVariable info
    $request = @(Get-HarnessRequests)[0]
    Assert-Harness ($result.Answer -eq 'hello' -and $result.Provider -eq 'custom' -and $result.Model -eq 'custom-model') 'Custom model answer and metadata'
    Assert-Harness ($result.Messages.Count -eq 3 -and $result.Iterations -eq 1) 'Initial transcript'
    Assert-Harness ($result.PromptTokens -eq 10 -and $result.CompletionTokens -eq 2) 'Token accounting'
    Assert-Harness ($request.Headers.Authorization -eq 'Bearer fake-test-key' -and $request.Body.temperature -eq 0.25 -and $request.Timeout -eq 12) 'Connection overrides'
    Assert-Harness ($null -eq $request.Body.tools -and $info.Count -eq 0) 'No tools and quiet trace'
    Assert-Harness ($request.Body.messages[1].content -is [string] -and $request.Body.messages[1].content -eq 'hello') 'Prompts without attachments remain plain strings'

    . (Join-Path $PSScriptRoot 'AgentHarness.Identity.Tests.ps1')
    . (Join-Path $PSScriptRoot 'AgentHarness.Profiles.Tests.ps1')

    # Simulate clipboard output without reading or changing the user's clipboard.
    $clipboardLines = @('First line', '', 'Unicode: café, नमस्ते', 'Last line')
    $clipboardText = $clipboardLines -join [Environment]::NewLine
    foreach ($preference in 'Continue', 'Stop') {
        $ErrorActionPreference = $preference
        Set-HarnessResponses @((New-HarnessResponse 'clipboard accepted'))
        $clipboardResult = Invoke-AgentHarness -Prompt $clipboardLines @basic -PassThru
        $clipboardContent = @(Get-HarnessRequests)[0].Body.messages[1].content
        Assert-Harness ($clipboardContent -is [string] -and $clipboardContent -ceq $clipboardText) 'Line arrays serialize as one prompt with blank lines and Unicode preserved'
        Assert-Harness ($clipboardResult.Messages[1].content -ceq $clipboardText) 'PassThru retains the normalized clipboard prompt'

        $multilineText = "First`n`nSecond`r`nThird`n"
        Set-HarnessResponses @((New-HarnessResponse))
        $null = Invoke-AgentHarness -Prompt $multilineText @basic
        Assert-Harness (@(Get-HarnessRequests)[0].Body.messages[1].content -ceq $multilineText) 'Scalar multiline prompts retain their original line endings'

        Set-HarnessResponses @()
        $catalogCount = & $module { $script:CatalogRequests.Count }
        Assert-HarnessThrows { Invoke-AgentHarness -Prompt '' @basic } '*Prompt cannot be empty*'
        Assert-HarnessThrows { Invoke-AgentHarness -Prompt @() @basic } '*empty array*'
        Assert-HarnessThrows { Invoke-AgentHarness -Prompt $null @basic } '*null*'
        Assert-Harness (@(Get-HarnessRequests).Count -eq 0 -and (& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Empty prompts fail before discovery or chat requests'
    }
    $ErrorActionPreference = 'Stop'

    # Synthetic attachments exercise the serialized request; no media is sent to a provider.
    $mediaDirectory = Join-Path $fixture 'media'
    $null = New-Item -ItemType Directory -Path $mediaDirectory
    $imagePath = Join-Path $mediaDirectory 'image [1].PNG'
    $imageBytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
    [IO.File]::WriteAllBytes($imagePath, $imageBytes)
    $pdfPath = Join-Path $fixture 'report.pdf'
    $pdfBytes = [Text.Encoding]::UTF8.GetBytes('%PDF-1.4 synthetic fixture')
    [IO.File]::WriteAllBytes($pdfPath, $pdfBytes)
    $videoPath = Join-Path $mediaDirectory 'clip.mp4'
    $videoBytes = [byte[]]@(0, 0, 0, 20, 102, 116, 121, 112, 109, 112, 52, 50)
    [IO.File]::WriteAllBytes($videoPath, $videoBytes)
    $textPath = Join-Path $mediaDirectory 'notes.txt'
    $attachmentText = "Unicode: café, नमस्ते`nsecond line"
    [IO.File]::WriteAllText($textPath, $attachmentText, [Text.UTF8Encoding]::new($false))
    $binaryPath = Join-Path $mediaDirectory 'unknown.bin'
    [IO.File]::WriteAllBytes($binaryPath, [byte[]]@(0, 1, 254, 255))
    $attachmentPaths = @('media/image [1].PNG', $pdfPath, 'media/clip.mp4', 'media/notes.txt', 'media/unknown.bin')
    Set-HarnessResponses @((New-HarnessResponse 'attachments received'))
    Push-Location -LiteralPath $mediaDirectory
    try {
        $attachmentResult = Invoke-AgentHarness 'Compare the attachments' @basic -Attachments $attachmentPaths -PassThru
    }
    finally { Pop-Location }
    $attachmentParts = @(Get-HarnessRequests)[0].Body.messages[1].content
    Assert-Harness ($attachmentParts -is [array] -and $attachmentParts.Count -eq 6) 'Attachments serialize as an ordered content array'
    Assert-Harness (($attachmentParts.type -join ',') -eq 'text,image_url,file,video_url,text,file' -and $attachmentParts[0].text -eq 'Compare the attachments') 'Prompt precedes attachments in caller order'
    Assert-Harness ($attachmentParts[1].image_url.url -eq ('data:image/png;base64,' + [Convert]::ToBase64String($imageBytes))) 'Image bytes, uppercase extension, spaces and literal brackets are preserved relative to WorkingDirectory'
    Assert-Harness ($attachmentParts[2].file.filename -eq 'report.pdf' -and $attachmentParts[2].file.file_data -eq ('data:application/pdf;base64,' + [Convert]::ToBase64String($pdfBytes))) 'PDF file part includes filename, MIME type and exact bytes'
    Assert-Harness ($attachmentParts[3].video_url.url -eq ('data:video/mp4;base64,' + [Convert]::ToBase64String($videoBytes))) 'Video is sent using video_url with exact base64 bytes'
    Assert-Harness ($attachmentParts[4].text -eq "Attachment: notes.txt`n$attachmentText") 'Text attachments retain filename, Unicode and line breaks'
    Assert-Harness ($attachmentParts[5].file.filename -eq 'unknown.bin' -and $attachmentParts[5].file.file_data -eq 'data:application/octet-stream;base64,AAH+/w==') 'Unknown binary files use the generic file content type'
    Assert-Harness ($attachmentResult.Messages[1].content -is [array] -and $attachmentResult.Messages[1].content[0].text -eq 'Compare the attachments' -and $attachmentResult.Messages[1].content[1].text -like '`[image: image*' -and $attachmentResult.Messages[1].content[2].text -like '`[file: report.pdf*' -and $attachmentResult.Messages[1].content[3].text -like '`[video: clip.mp4*' -and $attachmentResult.Messages[1].content[4].text -eq "Attachment: notes.txt`n$attachmentText" -and $attachmentResult.Messages[1].content[5].text -like '`[file: unknown.bin*') 'PassThru retains attachment placeholders, not base64 media'

    $attachmentHistoryBefore = $attachmentResult.Messages | ConvertTo-Json -Depth 20 -Compress
    Set-HarnessResponses @((New-HarnessResponse 'follow-up with media'))
    $null = Invoke-AgentHarness 'Compare again' @basic -History $attachmentResult.Messages -Attachment $imagePath
    $attachmentMessages = @(Get-HarnessRequests)[0].Body.messages
    Assert-Harness ($attachmentMessages[1].content.Count -eq 6 -and $attachmentMessages[1].content[1].text -like '`[image:*' -and $null -eq $attachmentMessages[1].content[1].image_url -and $attachmentMessages[3].content.Count -eq 2 -and $attachmentMessages[3].content[0].text -eq 'Compare again' -and $attachmentMessages[3].content[1].image_url.url -match '^data:image/png;base64,') 'History retains previous attachment placeholders and injects new attachment media for the provider'
    Assert-Harness (($attachmentResult.Messages | ConvertTo-Json -Depth 20 -Compress) -eq $attachmentHistoryBefore) 'Attachment history placeholders are not mutated by follow-ups'

    # JSON-loaded history uses PSCustomObject messages, including tool protocol metadata.
    $objectHistory = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject @(
            @{ role = 'user'; content = 'Previous question' },
            @{ role = 'assistant'; content = $null; tool_calls = @((New-HarnessCall inspect '{}' 'history_inspect')) },
            @{ role = 'tool'; tool_call_id = 'history_inspect'; name = 'inspect'; content = 'Previous evidence' },
            @{ role = 'assistant'; content = 'Previous answer' }
        ) -Depth 20)
    $objectHistoryBefore = ConvertTo-Json -InputObject $objectHistory -Depth 20 -Compress
    foreach ($preference in 'Continue', 'Stop') {
        $ErrorActionPreference = $preference
        Set-HarnessResponses @((New-HarnessResponse 'Object history accepted'))
        $null = Invoke-AgentHarness 'Inspect new media' @basic -History $objectHistory -Attachments $imagePath
        $objectMessages = @(Get-HarnessRequests)[0].Body.messages
        $objectHistoryPreserved = $true
        for ($historyIndex = 0; $historyIndex -lt $objectHistory.Count; $historyIndex++) {
            $expectedMessage = $objectHistory[$historyIndex]
            $actualMessage = $objectMessages[$historyIndex + 1]
            $expectedProperties = @($expectedMessage.PSObject.Properties.Name | Sort-Object)
            if (($actualMessage.PSObject.Properties.Name | Sort-Object) -join ',' -cne ($expectedProperties -join ',')) { $objectHistoryPreserved = $false }
            foreach ($propertyName in $expectedProperties) {
                if ((ConvertTo-Json -InputObject $actualMessage.$propertyName -Depth 20 -Compress) -cne
                    (ConvertTo-Json -InputObject $expectedMessage.$propertyName -Depth 20 -Compress)) { $objectHistoryPreserved = $false }
            }
        }
        Assert-Harness $objectHistoryPreserved 'Media injection preserves object history roles, contents and tool-call metadata under Continue and Stop'
        Assert-Harness ($objectMessages[-1].content[1].image_url.url -eq $attachmentParts[1].image_url.url) 'Object history does not prevent injecting new attachment bytes'
        Assert-Harness ((ConvertTo-Json -InputObject $objectHistory -Depth 20 -Compress) -ceq $objectHistoryBefore) 'Media injection leaves caller object history unchanged'
    }
    $ErrorActionPreference = 'Stop'

    $outsideRoot = $basic.Clone(); $outsideRoot.WorkingDirectory = $mediaDirectory

    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'Explicit external attachment' @outsideRoot -AttachmentPath $pdfPath
    Assert-Harness (@(Get-HarnessRequests)[0].Body.messages[1].content[1].file.filename -eq 'report.pdf') 'Explicit absolute attachments may live outside the tool working directory'

    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'No attachments' @basic -Attachments @()
    Assert-Harness (@(Get-HarnessRequests)[0].Body.messages[1].content -is [string]) 'An empty attachment array keeps the plain-text request format'

    # Invalid attachments terminate before discovery or chat, even with Continue.
    $invalidTextPath = Join-Path $mediaDirectory 'invalid.txt'
    [IO.File]::WriteAllBytes($invalidTextPath, [byte[]]@(255, 255, 0))
    foreach ($preference in 'Continue', 'Stop') {
        $ErrorActionPreference = $preference
        Set-HarnessResponses @()
        $catalogCount = & $module { $script:CatalogRequests.Count }
        Assert-HarnessThrows { Invoke-AgentHarness 'missing' -Provider TestA -WorkingDirectory $fixture -Attachments 'missing.png' -Quiet } '*Cannot find path*'
        Assert-HarnessThrows { Invoke-AgentHarness 'directory' @basic -Attachments $mediaDirectory } '*must be a local file*'
        Assert-HarnessThrows { Invoke-AgentHarness 'blank' @basic -Attachments @($imagePath, ' ') } '*cannot be blank*'
        Assert-HarnessThrows { Invoke-AgentHarness 'null entry' @basic -Attachments @($null) } '*cannot be blank*'
        Assert-HarnessThrows { Invoke-AgentHarness 'invalid encoding' @basic -Attachments $invalidTextPath } '*Unable to translate bytes*'
        Assert-Harness (@(Get-HarnessRequests).Count -eq 0 -and (& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Invalid attachments cause no discovery or chat requests'
    }
    $ErrorActionPreference = 'Stop'

    $attachmentTool = @{ inspect = @{ Script = { param($a, $ctx) 'synthetic tool result' } } }
    Set-HarnessResponses @((New-HarnessApiError 429), (New-HarnessResponse '' @((New-HarnessCall inspect))), (New-HarnessResponse 'media tool complete'))
    $null = Invoke-AgentHarness 'Inspect media' @basic -Attachments $imagePath, $pdfPath, $videoPath -Tools $attachmentTool
    $attachmentRequests = @(Get-HarnessRequests)
    $sentContent = @($attachmentRequests | ForEach-Object { ConvertTo-Json -InputObject $_.Body.messages[1].content -Depth 10 -Compress })
    Assert-Harness ($attachmentRequests.Count -eq 3 -and $sentContent[0] -ceq $sentContent[1] -and $attachmentRequests[0].Body.messages[1].content[1].image_url.url -eq $attachmentParts[1].image_url.url) 'Retries preserve identical attachments until the model accepts the turn'
    Assert-Harness (($attachmentRequests[-1].Body.messages[1].content.type -join ',') -eq 'text,text,text,text' -and $attachmentRequests[-1].Body.messages[1].content[1].text -like '`[image:*') 'Later tool turns retain attachment placeholders without resending media'
    Assert-Harness ($attachmentRequests[-1].Body.messages[-1].content -eq 'synthetic tool result') 'Attachment prompts remain compatible with tool execution'
    Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'media fallback'))
    $null = Invoke-AgentHarness 'Inspect with fallback' -Provider TestA -WorkingDirectory $fixture -Attachments $imagePath -Quiet -NoBuiltinTools -NoModelRecovery
    $attachmentRequests = @(Get-HarnessRequests)
    Assert-Harness (($attachmentRequests.Body.model -join ',') -eq 'first:free,second:free' -and $attachmentRequests[0].Body.messages[1].content[1].image_url.url -eq $attachmentRequests[1].Body.messages[1].content[1].image_url.url) 'Model fallback retains attached media'

    $inlinePrompt = @'
Compare @attach("media/image [1].PNG") @attach('report.pdf') @attach(media/clip.mp4)
'@
    Set-HarnessResponses @((New-HarnessResponse 'inline media received'))
    $inlineResult = Invoke-AgentHarness $inlinePrompt @basic -Attachments $textPath -PassThru
    $inlineParts = @(Get-HarnessRequests)[0].Body.messages[1].content
    Assert-Harness (($inlineParts.type -join ',') -eq 'text,text,image_url,file,video_url' -and $inlineParts[0].text -eq 'Compare') 'Inline markers combine with explicit attachments and are removed from prompt text'
    Assert-Harness ($inlineParts[2].image_url.url -eq $attachmentParts[1].image_url.url -and $inlineParts[3].file.filename -eq 'report.pdf') 'Double quoted, single quoted and unquoted inline paths use WorkingDirectory'
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness '@ATTACH("media/image [1].PNG")' @basic
    Assert-Harness (@(Get-HarnessRequests)[0].Body.messages[1].content[0].text -eq 'Review the attached files.') 'Attachment-only prompts receive a default instruction and markers are case insensitive'
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'Explain @@attach("missing.png") literally' @basic
    Assert-Harness (@(Get-HarnessRequests)[0].Body.messages[1].content -ceq 'Explain @attach("missing.png") literally') 'Escaped attachment syntax stays plain text without accessing the file'
    $parenthesizedImage = Join-Path $mediaDirectory 'image (2).png'
    [IO.File]::WriteAllBytes($parenthesizedImage, $imageBytes)
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'Review @attach("media/image (2).png")' @basic
    Assert-Harness (@(Get-HarnessRequests)[0].Body.messages[1].content[1].image_url.url -eq $attachmentParts[1].image_url.url) 'Quoted paths support parentheses'
    $literalImagePath = Join-Path $mediaDirectory '$(throw attachment-evaluated).png'
    [IO.File]::WriteAllBytes($literalImagePath, $imageBytes)
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'Review @attach("media/$(throw attachment-evaluated).png")' @basic
    Assert-Harness (@(Get-HarnessRequests)[0].Body.messages[1].content[1].image_url.url -eq $attachmentParts[1].image_url.url) 'Inline paths containing PowerShell expressions are handled literally without evaluation'
    foreach ($invalidPrompt in '@attach("missing.png"', '@attach()', '@attach(" ")', '@attach("a" "b")') {
        Set-HarnessResponses @()
        Assert-HarnessThrows { Invoke-AgentHarness $invalidPrompt @basic } '*attachment*'
        Assert-Harness (@(Get-HarnessRequests).Count -eq 0) 'Malformed inline markers cause no request'
    }

    # Never inspect the user's clipboard. Mock the native reader with a synthetic PNG.
    $savedClipboardReader = & $module { (Get-Command Get-AgentHarnessClipboardImage).ScriptBlock }
    $clipboardMock = & $module {
        param($dataUrl)
        $script:ClipboardDataUrl = $dataUrl
        $script:ClipboardReads = 0
        $script:ClipboardFailure = $null
        function script:Get-AgentHarnessClipboardImage {
            param([switch]$PlaceholderOnly)
            $script:ClipboardReads++
            if ($script:ClipboardFailure) { throw $script:ClipboardFailure }
            $part = @{ type = 'image_url'; image_url = @{ url = $script:ClipboardDataUrl } }
            if ($PlaceholderOnly) {
                $placeholder = '[image: clipboard — 0 MB, image/png]'
                return @{ PlaceholderPart = @{ type = 'text'; text = $placeholder }; ContentPart = $part; Placeholder = $placeholder }
            }
            $part
        }
        (Get-Command Get-AgentHarnessClipboardImage).ScriptBlock
    } $attachmentParts[1].image_url.url
    try {
        Set-HarnessResponses @((New-HarnessResponse 'clipboard received'))
        $clipboardResult = Invoke-AgentHarness 'Explain this screenshot @clipboard' @basic -PassThru
        $clipboardParts = @(Get-HarnessRequests)[0].Body.messages[1].content
        Assert-Harness (($clipboardParts.type -join ',') -eq 'text,image_url' -and $clipboardParts[0].text -eq 'Explain this screenshot') 'Clipboard markers produce a screenshot content part and are removed from prompt text'
        Assert-Harness ($clipboardParts[1].image_url.url -eq $attachmentParts[1].image_url.url -and (& $module { $script:ClipboardReads }) -eq 1) 'Clipboard image uses exact captured PNG data and is read once'
        Set-HarnessResponses @((New-HarnessResponse))
        $null = Invoke-AgentHarness 'Explain @@clipboard and @@clipboard() for user@clipboard.example and @clipboardOther' @basic
        Assert-Harness (@(Get-HarnessRequests)[0].Body.messages[1].content -ceq 'Explain @clipboard and @clipboard() for user@clipboard.example and @clipboardOther') 'Escaped clipboard markers, email addresses and longer words remain literal'
        Assert-Harness ((& $module { $script:ClipboardReads }) -eq 1) 'Literal clipboard text never accesses the clipboard'
        Set-HarnessResponses @((New-HarnessResponse))
        $null = Invoke-AgentHarness '@CLIPBOARD() @clipboard' @basic
        $clipboardParts = @(Get-HarnessRequests)[0].Body.messages[1].content
        Assert-Harness ($clipboardParts.Count -eq 3 -and $clipboardParts[0].text -eq 'Review the attached files.' -and (& $module { $script:ClipboardReads }) -eq 2) 'Repeated clipboard markers share one snapshot per prompt, accept empty parentheses and are case insensitive'
        Set-HarnessResponses @((New-HarnessResponse))
        $null = Invoke-AgentHarness 'Compare @attach("report.pdf") @clipboard @attach("media/clip.mp4")' @basic -Attachments $textPath
        Assert-Harness ((@(Get-HarnessRequests)[0].Body.messages[1].content.type -join ',') -eq 'text,text,file,image_url,video_url') 'Clipboard and file attachments retain explicit and inline ordering'
        $clipboardReads = & $module { $script:ClipboardReads }
        Set-HarnessResponses @((New-HarnessResponse))
        $null = Invoke-AgentHarness 'Explain again' @basic -History $clipboardResult.Messages
        Assert-Harness ((& $module { $script:ClipboardReads }) -eq $clipboardReads -and @(Get-HarnessRequests)[0].Body.messages[1].content[1].text -like '`[image: clipboard*') 'History retains clipboard placeholders without reading the clipboard again'
        Set-HarnessResponses @((New-HarnessApiError 429), (New-HarnessResponse 'clipboard retried'))
        $null = Invoke-AgentHarness 'Retry this @clipboard' @basic
        $clipboardRequests = @(Get-HarnessRequests)
        Assert-Harness ($clipboardRequests.Count -eq 2 -and (& $module { $script:ClipboardReads }) -eq ($clipboardReads + 1) -and $clipboardRequests[0].Body.messages[1].content[1].image_url.url -eq $clipboardRequests[1].Body.messages[1].content[1].image_url.url) 'HTTP retries reuse the clipboard snapshot'
        foreach ($preference in 'Continue', 'Stop') {
            $ErrorActionPreference = $preference
            & $module { $script:ClipboardFailure = 'No image found in the clipboard. Copy a screenshot first.' }
            Set-HarnessResponses @()
            Assert-HarnessThrows { Invoke-AgentHarness 'Explain @clipboard' @basic } '*No image found in the clipboard*'
            Assert-Harness (@(Get-HarnessRequests).Count -eq 0) 'Empty clipboard fails before any request under Continue and Stop'
        }
    }
    finally {
        $ErrorActionPreference = 'Stop'
        & $module {
            param($reader)
            $script:ClipboardFailure = $null
            Set-Item Function:script:Get-AgentHarnessClipboardImage -Value $reader
        } $savedClipboardReader
    }

    # Prompt composition uses only synthetic instructions, never the repo's AGENTS.md.
    $defaultPrompt = & $module { Get-AgentHarnessSystemPrompt -NoAgentsFile }
    Assert-Harness ($result.Messages[0].content -eq $defaultPrompt) 'Dedicated default system prompt with no AGENTS.md'
    $agentsPath = Join-Path $fixture 'AGENTS.md'
    Set-Content -LiteralPath $agentsPath -Value 'Synthetic repository rule: keep the blue widget.'
    Set-HarnessResponses @((New-HarnessResponse))
    $agentsRun = Invoke-AgentHarness 'instructions' @basic -Instructions 'Reply using bullet points.' -PassThru
    $systemText = $agentsRun.Messages[0].content
    Assert-Harness ($systemText.StartsWith($defaultPrompt)) 'User instructions retain the default prompt'
    Assert-Harness ($systemText.Contains('Synthetic repository rule: keep the blue widget.')) 'AGENTS.md loaded from WorkingDirectory'
    Assert-Harness ($systemText.EndsWith('Additional user instructions:' + "`n" + 'Reply using bullet points.')) 'Additional instructions appended last'
    Assert-Harness (@(Get-HarnessRequests)[0].Body.messages[0].content -eq $systemText) 'Composed system prompt sent to provider'
    Set-HarnessResponses @((New-HarnessResponse))
    $disabled = Invoke-AgentHarness 'disabled' @basic -NoAgentsFile -SystemPrompt 'Legacy additional instructions.' -PassThru
    Assert-Harness (-not $disabled.Messages[0].content.Contains('Synthetic repository rule')) 'NoAgentsFile disables automatic loading'
    Assert-Harness ($disabled.Messages[0].content.StartsWith($defaultPrompt) -and $disabled.Messages[0].content.EndsWith('Legacy additional instructions.')) 'SystemPrompt alias appends to the default'
    Set-Content -LiteralPath $agentsPath -Value 'Synthetic repository rule: changed on disk.'
    Set-HarnessResponses @((New-HarnessResponse))
    $refreshed = Invoke-AgentHarness 'refresh' @basic -History $agentsRun.Messages -AdditionalInstructions 'New user instructions.' -PassThru
    Assert-Harness (@($refreshed.Messages | Where-Object role -eq system).Count -eq 1) 'Exactly one refreshed system message with History'
    Assert-Harness ($refreshed.Messages[0].content.Contains('changed on disk') -and -not $refreshed.Messages[0].content.Contains('blue widget')) 'History reloads current AGENTS.md'
    Assert-Harness ($refreshed.Messages[0].content.EndsWith('New user instructions.') -and $refreshed.Messages.Count -eq 5) 'History supports appended instructions'
    Assert-Harness ($agentsRun.Messages[0].content.Contains('blue widget') -and $agentsRun.Messages.Count -eq 3) 'History prompt is not mutated'
    Set-HarnessResponses @((New-HarnessResponse))
    $disabledHistory = Invoke-AgentHarness 'disable history' @basic -History $agentsRun.Messages -NoAgentsFile -PassThru
    Assert-Harness ($disabledHistory.Messages[0].content -eq $defaultPrompt) 'NoAgentsFile removes earlier loaded system instructions'
    $childDirectory = Join-Path $fixture 'active-child'
    $null = New-Item -ItemType Directory -Path $childDirectory
    Set-Content -LiteralPath (Join-Path $childDirectory 'AGENTS.md') -Value 'Active directory instructions only.'
    $active = $basic.Clone(); $active.Remove('WorkingDirectory')
    Push-Location -LiteralPath $childDirectory
    try {
        Set-HarnessResponses @((New-HarnessResponse))
        $activeRun = Invoke-AgentHarness 'active directory' @active -PassThru
        Assert-Harness ($activeRun.Messages[0].content.Contains('Active directory instructions only.') -and -not $activeRun.Messages[0].content.Contains('changed on disk')) 'Defaults to active directory without reading parent AGENTS.md'
    }
    finally { Pop-Location }
    Set-Content -LiteralPath $agentsPath -Value '   '
    Set-HarnessResponses @((New-HarnessResponse))
    $blankRun = Invoke-AgentHarness 'blank' @basic -Instructions '   ' -PassThru
    Assert-Harness ($blankRun.Messages[0].content -eq $defaultPrompt) 'Empty instructions do not add empty prompt sections'
    Remove-Item -LiteralPath $agentsPath

    Set-HarnessResponses @((New-HarnessResponse 'follow-up'))
    $followUp = Invoke-AgentHarness 'again' @basic -History $result.Messages -PassThru
    Assert-Harness ($followUp.Messages.Count -eq 5 -and $result.Messages.Count -eq 3) 'History reused without mutating the original array'
    Set-HarnessResponses @((New-HarnessResponse 'visible'))
    $traced = $basic.Clone(); $traced.Quiet = $false
    $info = @()
    $answer = Invoke-AgentHarness 'trace' @traced -InformationVariable info 6>$null
    Assert-Harness ($answer -eq 'visible' -and $info.Count -gt 0) 'Existing logger writes only to information stream'

    $script:ReadableTable = (@(
            'Lines Bytes FullName',
            '----- ----- --------',
            ' 1762 70518 src/app/ui.rs'
        ) + @(for ($i = 0; $i -lt 20; $i++) { '   62 40960 examples/example-{0:D2}.rs' -f $i })) -join "`n"
    $tableTools = @{ table = @{ Script = { param($a, $ctx) $script:ReadableTable } } }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall table '{"path":"sample.txt","pattern":"first\nsecond"}'))), (New-HarnessResponse 'table complete'))
    $info = @()
    $tableResult = Invoke-AgentHarness 'readable table' @traced -Tools $tableTools -PassThru -InformationVariable info 6>$null
    $displayText = @($info | ForEach-Object { [string]$_.MessageData.Message })
    Assert-Harness ($tableResult.Answer -eq 'table complete' -and $tableResult.Messages[3].content -eq $script:ReadableTable) 'Readable display does not alter the tool transcript or pipeline result'
    Assert-Harness ($displayText -contains $script:ReadableTable) 'Table spacing and every output line displayed without whitespace flattening'
    Assert-Harness (($displayText -join "`n").Contains('examples/example-19.rs')) 'Results beyond the old 200-character preview remain visible'
    Assert-Harness (@($displayText | Where-Object { $_ -like 'Result: table*' }).Count -eq 1) 'Tool result has its own labeled block'
    Assert-Harness (($displayText -join "`n").Contains("pattern:`nfirst`nsecond") -and ($displayText -join "`n").Contains('path: sample.txt')) 'Tool arguments are decoded into readable fields'

    Set-HarnessResponses @((New-HarnessResponse 'derived'))
    $result = Invoke-AgentHarness 'endpoint' -Provider TestA -Model custom-model -Quiet -NoBuiltinTools -WorkingDirectory $fixture
    Assert-Harness ($result -eq 'derived' -and @(Get-HarnessRequests)[0].Uri -eq 'https://provider.invalid/a/v1/chat/completions') 'Provider endpoint derivation'

    Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'fallback'))
    $result = Invoke-AgentHarness 'fallback' -Provider TestA -Quiet -NoBuiltinTools -PassThru -WorkingDirectory $fixture
    Assert-Harness ($result.Model -eq 'second:free' -and @(Get-HarnessRequests).Count -eq 2) 'Fallback before first success'
    Set-HarnessResponses @((New-HarnessApiError 401), (New-HarnessResponse 'other provider'))
    $result = Invoke-AgentHarness 'auth' -Quiet -NoBuiltinTools -PassThru -WorkingDirectory $fixture
    Assert-Harness ($result.Provider -eq 'TestB' -and @(Get-HarnessRequests).Count -eq 2) 'Auth failure skips all models from that provider'
    Set-HarnessResponses @((New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'budget' -Provider TestA -Quiet -NoBuiltinTools -MaxModelAttempts 1 -WorkingDirectory $fixture -NoModelRecovery } '*after 1 attempt*'
    Set-HarnessResponses @((New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'custom failure' @basic } '*after 1 attempt*'

    Set-HarnessResponses @((New-HarnessApiError 429), (New-HarnessResponse 'retried'))
    Assert-Harness ((Invoke-AgentHarness 'retry' @basic) -eq 'retried') 'Transient HTTP error retried'
    Assert-Harness ((& $module { $script:Delays -join ',' }) -eq '2') 'Retry delay'
    Set-HarnessResponses @([pscustomobject]@{ error = [pscustomobject]@{ code = 403; message = 'rejected' } })
    Assert-HarnessThrows { Invoke-AgentHarness 'API error' @basic } '*API error: rejected*'
    Set-HarnessResponses @([pscustomobject]@{ choices = @([pscustomobject]@{ finish_reason = 'stop' }) })
    Assert-HarnessThrows { Invoke-AgentHarness 'bad response' @basic } '*no assistant message*'

    $tools = @{
        echo  = @{ Description = 'Echo text'; Script = { param($a, $ctx) "$($a.text)@$([IO.Path]::GetFileName($ctx.Root))" } }
        fail  = @{ Description = 'Fail'; Script = { param($a, $ctx) Write-Error 'ordinary tool failure' } }
        empty = @{ Description = 'Empty'; Script = { param($a, $ctx) } }
        long  = @{ Description = 'Long'; Script = { param($a, $ctx) 'abcdefghijklmnopqrstuvwxyz' } }
    }
    $calls = @(
        (New-HarnessCall echo @{ text = 'ok' } ''),
        (New-HarnessCall missing),
        (New-HarnessCall echo '{'),
        (New-HarnessCall echo '[]'),
        (New-HarnessCall fail),
        (New-HarnessCall empty),
        (New-HarnessCall long)
    )
    Set-HarnessResponses @((New-HarnessResponse '' $calls), (New-HarnessResponse 'tools complete'))
    # Exercise ordinary errors with a normal caller preference, rather than relying on the test's Stop setting.
    $ErrorActionPreference = 'Continue'
    try { $result = Invoke-AgentHarness 'tools' @basic -Tools $tools -PassThru }
    finally { $ErrorActionPreference = 'Stop' }
    $toolResults = @($result.Messages | Where-Object role -eq tool)
    Assert-Harness ($result.Answer -eq 'tools complete' -and $result.Iterations -eq 2 -and $result.PromptTokens -eq 20) 'Tool round trip'
    Assert-Harness ($toolResults[0].content -like 'ok@SpiHarnessTests-*') 'Object arguments and context'
    Assert-Harness ($toolResults[0].tool_call_id -like 'call_*') 'Missing tool id generated'
    Assert-Harness ($toolResults[1].content -like 'ERROR: unknown tool*') 'Unknown tool result'
    Assert-Harness ($toolResults[2].content -like 'ERROR:*' -and $toolResults[3].content -like 'ERROR:*JSON object*') 'Malformed and non-object arguments rejected'
    Assert-Harness ($toolResults[4].content -like 'ERROR: ordinary tool failure*') 'Ordinary tool errors are returned to the agent'
    Assert-Harness ($toolResults[5].content -eq '(no output)') 'Empty tool output'
    Assert-Harness (@(Get-HarnessRequests)[1].Body.messages[-1].role -eq 'tool') 'Tool results sent in the next request'
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall long))), (New-HarnessResponse))
    $result = Invoke-AgentHarness 'truncate' @basic -Tools $tools -PassThru -MaxToolOutputChars 10
    Assert-Harness ($result.Messages[3].content -eq "abcdefghij`n...[truncated 16 chars]") 'Tool result truncation'
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall long))), (New-HarnessResponse))
    $info = @()
    $displayLimited = Invoke-AgentHarness 'display truncation' @traced -Tools $tools -PassThru -MaxToolOutputChars 10 -InformationVariable info 6>$null
    Assert-Harness (@($info | ForEach-Object { [string]$_.MessageData.Message }) -contains $displayLimited.Messages[3].content) 'Readable result includes the existing output-limit truncation notice'

    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall empty))), (New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'locked' @basic -Tools $tools } '*mock API failure*'
    Assert-Harness (@(Get-HarnessRequests).Count -eq 2) 'No model fallback after a successful tool turn'
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall empty))))
    $warnings = @()
    $result = Invoke-AgentHarness 'limit' @basic -Tools $tools -PassThru -MaxIterations 1 -WarningVariable warnings 3>$null
    Assert-Harness ($result.Answer -eq '' -and $result.Iterations -eq 1 -and $warnings.Count -eq 1) 'Iteration limit preserves transcript and warns'

    $manyTurns = @(for ($i = 0; $i -lt 100; $i++) {
            New-HarnessResponse '' @((New-HarnessCall empty))
        })
    Set-HarnessResponses $manyTurns
    $warnings = @()
    $result = Invoke-AgentHarness 'default turn limit' @basic -Tools $tools -PassThru -WarningVariable warnings 3>$null
    Assert-Harness ($result.Iterations -eq 100 -and @(Get-HarnessRequests).Count -eq 100 -and $warnings.Count -eq 1) 'Default limit permits exactly 100 model turns'
    Set-HarnessResponses $manyTurns
    $warnings = @()
    $result = Invoke-AgentHarness 'custom turn limit' @basic -Tools $tools -PassThru -MaxIterations 3 -WarningVariable warnings 3>$null
    Assert-Harness ($result.Iterations -eq 3 -and @(Get-HarnessRequests).Count -eq 3 -and $warnings.Count -eq 1) 'MaxIterations overrides the default limit'

    foreach ($parameter in 'MaxIterations', 'MaxModelAttempts', 'TimeoutSec', 'MaxToolOutputChars') {
        $invalid = $basic.Clone(); $invalid[$parameter] = 0
        Assert-HarnessThrows { Invoke-AgentHarness 'invalid' @invalid } '*Cannot validate argument*'
    }
    $invalidDirectory = $basic.Clone(); $invalidDirectory.WorkingDirectory = Join-Path $fixture 'missing'
    Assert-HarnessThrows { Invoke-AgentHarness 'directory' @invalidDirectory } '*Working directory*'
    Assert-HarnessThrows { Invoke-AgentHarness 'tool definition' @basic -Tools @{ bad = @{ Script = 'not a script' } } } '*Script scriptblock*'

    & $module { function script:Show-InteractiveMenu { param($Options, $Title) $Options[1] } }
    Set-HarnessResponses @((New-HarnessResponse 'picked'))
    $result = Invoke-AgentHarness 'pick' -Provider TestA -Pick -Quiet -NoBuiltinTools -PassThru -WorkingDirectory $fixture
    Assert-Harness ($result.Model -eq 'second:free') 'Pick reuses interactive menu'
    & $module { function script:Show-InteractiveMenu { param($Options, $Title) $null } }
    Assert-HarnessThrows { Invoke-AgentHarness 'cancel' -Provider TestA -Pick -Quiet -WorkingDirectory $fixture } '*selection cancelled*'

    & $module {
        $script:RecoveryChoices = [Collections.Generic.Queue[object]]::new()
        $script:RecoveryMenus = [Collections.Generic.List[object]]::new()
        $script:RecoveryModelIds = [Collections.Generic.Queue[string]]::new()
        function script:Show-InteractiveMenu {
            param($Options, $Title)
            $script:RecoveryMenus.Add([pscustomobject]@{ Title = $Title; Options = @($Options) })
            if (-not $script:RecoveryChoices.Count) { throw 'Unexpected model recovery menu.' }
            $choice = $script:RecoveryChoices.Dequeue()
            if ($null -eq $choice) { return }
            if ($choice -is [int]) { return $Options[$choice] }
            if ($Options -notcontains $choice) { throw "Unexpected recovery choice: $choice" }
            $choice
        }
        function script:Read-Host {
            param([string]$Prompt)
            if ($Prompt -ne 'Model ID' -or -not $script:RecoveryModelIds.Count) { throw 'Unexpected model ID prompt.' }
            $script:RecoveryModelIds.Dequeue()
        }
    }
    . (Join-Path $PSScriptRoot 'AgentHarness.Inception.Tests.ps1')
    . (Join-Path $PSScriptRoot 'AgentHarness.Respan.Tests.ps1')

    # Cohere discovery uses the native paginated catalogue; chat uses compatibility v1.
    & $module {
        param($provider)
        $script:FreeModelProviders[$provider.Name] = $provider
        $script:CohereNextUri = $provider.Uri + '&page_token=page%2B2%2F%3D'
        $script:CatalogResponses[$provider.Uri] = [pscustomobject]@{
            models          = @(
                [pscustomobject]@{ name = 'command-test-one'; endpoints = @('chat'); context_length = 128000 },
                [pscustomobject]@{ name = 'embed-test'; endpoints = @('embed'); context_length = 512 }
            )
            next_page_token = 'page+2/='
        }
        $script:CatalogResponses[$script:CohereNextUri] = [pscustomobject]@{
            models = @([pscustomobject]@{ name = 'command-test-two'; endpoints = @('chat'); context_length = 256000 })
        }
    } $cohereProvider
    $previousCohereKey = [Environment]::GetEnvironmentVariable('COHERE_API_KEY')
    try {
        [Environment]::SetEnvironmentVariable('COHERE_API_KEY', $null)
        $catalogCount = & $module { $script:CatalogRequests.Count }
        $warnings = @()
        $models = @(Get-FreeModels -Provider Cohere -All -WarningVariable warnings 3>$null)
        Assert-Harness ($models.Count -eq 0 -and ($warnings -join ' ') -like '*COHERE_API_KEY*' -and (& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Cohere discovery skips missing keys without sending a request'

        [Environment]::SetEnvironmentVariable('COHERE_API_KEY', 'fake-cohere-test-key')
        $models = @(Get-FreeModels -Provider Cohere -All)
        $catalogRequests = & $module { $script:CatalogRequests.ToArray() | Select-Object -Last 2 }
        Assert-Harness (($models.Id -join ',') -eq 'command-test-one,command-test-two' -and $models[0].Name -eq $models[0].Id -and $models[1].Context -eq 256000) 'Cohere discovery maps names to ids, preserves context and follows pages while excluding non-chat models'
        Assert-Harness ($catalogRequests[1].Uri -like '*page_token=page%2B2%2F%3D' -and @($catalogRequests | Where-Object { $_.Headers.Authorization -ne 'Bearer fake-cohere-test-key' }).Count -eq 0) 'Cohere pagination encodes tokens and retains authentication'
        Assert-Harness (@(Get-FreeModels -Provider Cohere).Count -eq 0) 'Unknown Cohere pricing is not classified as free'
        Assert-Harness (@(Get-FreeModels -Provider Cohere -All -Name '*two').Count -eq 1) 'Cohere discovery supports name filtering across pages'

        $cohere = @{ Provider = 'Cohere'; Quiet = $true; NoBuiltinTools = $true; NoAgentsFile = $true; WorkingDirectory = $fixture; NoModelRecovery = $true }
        Set-HarnessRecoveryChoices @(1)
        Set-HarnessResponses @((New-HarnessResponse 'cohere picked'))
        $picked = Invoke-AgentHarness 'Pick a Cohere model' @cohere -All -Pick -PassThru
        Assert-Harness ($picked.Provider -eq 'Cohere' -and $picked.Model -eq 'command-test-two') 'Pick All offers Cohere chat models from every catalogue page'

        $cohereTools = @{ echo = @{ Script = { param($a, $ctx) "echo:$($a.text)" } } }
        Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall echo '{"text":"cohere tool"}'))), (New-HarnessResponse 'cohere complete'))
        $roundTrip = Invoke-AgentHarness 'Use echo' @cohere -All -ModelFilter '*one' -Tools $cohereTools -Temperature 0.2 -PassThru
        $requests = @(Get-HarnessRequests)
        Assert-Harness ($roundTrip.Answer -eq 'cohere complete' -and $roundTrip.Model -eq 'command-test-one' -and $requests.Count -eq 2) 'Cohere auto-selection completes a tool-calling round trip'
        Assert-Harness (@($requests | Where-Object { $_.Uri -ne $cohereProvider.ChatUri -or $_.Headers.Authorization -ne 'Bearer fake-cohere-test-key' }).Count -eq 0) 'Cohere chat uses its registered compatible endpoint and environment key'
        Assert-Harness ($requests[0].Body.tools[0].function.name -eq 'echo' -and -not $requests[0].Body.PSObject.Properties['tool_choice'] -and $requests[0].Body.temperature -eq 0.2) 'Cohere sends supported tool and sampling parameters without tool_choice'
        Assert-Harness ($requests[1].Body.messages[-1].role -eq 'tool' -and $requests[1].Body.messages[-1].tool_call_id -eq 'call_test' -and $requests[1].Body.messages[-1].content -eq 'echo:cohere tool') 'Cohere tool results retain content and call ids'

        $catalogCount = & $module { $script:CatalogRequests.Count }
        Set-HarnessResponses @((New-HarnessApiError 429), (New-HarnessResponse 'cohere override'))
        $explicit = Invoke-AgentHarness 'Say hi' @cohere -Model command-custom -ApiKey fake-override-key -ChatUri 'https://provider.invalid/cohere/override' -PassThru
        $requests = @(Get-HarnessRequests)
        Assert-Harness ($explicit.Answer -eq 'cohere override' -and $requests[-1].Uri -eq 'https://provider.invalid/cohere/override' -and $requests[-1].Headers.Authorization -eq 'Bearer fake-override-key' -and (& $module { $script:CatalogRequests.Count }) -eq $catalogCount) 'Cohere explicit models bypass discovery, retain overrides and use existing retry handling'

        $cohereRecovery = $cohere.Clone(); $cohereRecovery.Remove('NoModelRecovery')
        Set-HarnessRecoveryChoices @('Choose another model', 0)
        Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'recovered on OpenAI format'))
        $recovered = Invoke-AgentHarness 'recover from Cohere' @cohereRecovery -Model command-test-one -All -Tools $cohereTools -PassThru
        $requests = @(Get-HarnessRequests)
        Assert-Harness ($recovered.Provider -eq 'TestA' -and -not $requests[0].Body.PSObject.Properties['tool_choice'] -and $requests[-1].Body.tool_choice -eq 'auto') 'Recovery from Cohere restores the replacement provider tool-choice configuration'

        Set-HarnessRecoveryChoices @('Choose another model', 2)
        Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'recovered on Cohere'))
        $recovered = Invoke-AgentHarness 'recover to Cohere' -Provider TestA -Model first:free -All -Quiet -NoBuiltinTools -NoAgentsFile -WorkingDirectory $fixture -Tools $cohereTools -PassThru
        $requests = @(Get-HarnessRequests)
        Assert-Harness ($recovered.Provider -eq 'Cohere' -and $recovered.Model -eq 'command-test-one' -and $requests[-1].Uri -eq $cohereProvider.ChatUri -and -not $requests[-1].Body.PSObject.Properties['tool_choice']) 'Recovery to Cohere applies its compatible endpoint and tool-choice configuration'

        & $module {
            Register-FreeModelProvider -Name LegacyMapper -Uri 'https://provider.invalid/a/v1/models' -GetModels { [CmdletBinding()] param($r) $r.data }
        }
        Assert-Harness (@(Get-FreeModels -Provider LegacyMapper).Count -eq 2) 'Existing advanced single-argument catalogue mappers remain compatible'

        # A subsequent-page failure must not return an incomplete catalogue.
        & $module { $script:CatalogResponses[$script:CohereNextUri] = [Exception]::new('mock catalogue failure') }
        foreach ($preference in 'Continue', 'Stop') {
            & {
                $ErrorActionPreference = $preference
                $warnings = @()
                $models = @(Get-FreeModels -Provider Cohere -All -WarningVariable warnings 3>$null)
                Assert-Harness ($models.Count -eq 0 -and ($warnings -join ' ') -like '*mock catalogue failure*') "Cohere page failure warns and discards partial results under $preference"
            }
        }
        & $module { $script:CatalogResponses[$script:CohereNextUri] = $script:CatalogResponses[$script:FreeModelProviders['Cohere'].Uri] }
        $warnings = @()
        $models = @(Get-FreeModels -Provider Cohere -All -WarningVariable warnings 3>$null)
        Assert-Harness ($models.Count -eq 0 -and ($warnings -join ' ') -like '*repeated a page token*') 'Cohere pagination stops if the API repeats a token'
    }
    finally {
        [Environment]::SetEnvironmentVariable('COHERE_API_KEY', $previousCohereKey)
        & $module { $script:FreeModelProviders.Remove('Cohere'); $script:FreeModelProviders.Remove('LegacyMapper') }
    }

    # Exercise full-catalogue selection through the exported command and real helpers.
    & $module {
        $script:OriginalCatalogA = $script:Catalog['https://provider.invalid/a/v1/models']
        $script:Catalog['https://provider.invalid/a/v1/models'] += @(
            [pscustomobject]@{ id = 'paid-model'; name = 'Extra Premium'; pricing = [pscustomobject]@{ prompt = '0.001'; completion = '0.002' } },
            [pscustomobject]@{ id = 'unknown-model'; name = 'Extra Unknown' }
        )
    }
    $catalogSelection = @{ Quiet = $true; NoBuiltinTools = $true; NoAgentsFile = $true; WorkingDirectory = $fixture; PassThru = $true }
    try {
        Set-HarnessRecoveryChoices @(1)
        Set-HarnessResponses @((New-HarnessResponse 'free picked'))
        $freePick = Invoke-AgentHarness 'free picker' @catalogSelection -Provider TestA -Pick
        $pickOptions = & $module { $script:RecoveryMenus[0].Options }
        Assert-Harness ($freePick.Model -eq 'second:free' -and $pickOptions.Count -eq 2 -and ($pickOptions -join ',') -notlike '*paid-model*') 'Pick remains free-only when the catalogue also contains paid and unknown-price models'

        Set-HarnessRecoveryChoices @(2)
        Set-HarnessResponses @((New-HarnessResponse 'paid picked'))
        $paidPick = Invoke-AgentHarness 'full picker' @catalogSelection -Provider TestA -Pick -All
        $pickOptions = & $module { $script:RecoveryMenus[0].Options }
        Assert-Harness ($paidPick.Model -eq 'paid-model' -and $paidPick.Provider -eq 'TestA' -and $pickOptions.Count -eq 4) 'Pick All includes paid and unknown-price models from the selected provider'
        Assert-Harness (@(Get-HarnessRequests)[0].Body.model -eq 'paid-model') 'The selected paid model is sent to the provider'

        Set-HarnessRecoveryChoices @(0)
        Set-HarnessResponses @((New-HarnessResponse 'filtered paid picked'))
        $filteredPick = Invoke-AgentHarness 'filtered picker' @catalogSelection -Provider TestA -Pick -All -ModelFilter '*Premium*'
        Assert-Harness ($filteredPick.Model -eq 'paid-model' -and (& $module { $script:RecoveryMenus[0].Options.Count }) -eq 1) 'Pick All filters by display name without including other providers'

        Set-HarnessRecoveryChoices @(0)
        Set-HarnessResponses @((New-HarnessResponse 'unknown picked'))
        $unknownPick = Invoke-AgentHarness 'unknown picker' @catalogSelection -Pick -All -ModelFilter 'unknown-*'
        Assert-Harness ($unknownPick.Model -eq 'unknown-model' -and $unknownPick.Provider -eq 'TestA') 'Pick All filters by id across registered providers and includes unknown pricing'

        Set-HarnessRecoveryChoices @($null)
        Assert-HarnessThrows { Invoke-AgentHarness 'cancel full picker' @catalogSelection -Provider TestA -Pick -All } '*selection cancelled*'

        Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'full fallback'))
        $fullFallback = Invoke-AgentHarness 'full fallback' @catalogSelection -Provider TestA -All -ModelFilter 'Extra*' -NoModelRecovery
        Assert-Harness ($fullFallback.Model -eq 'unknown-model' -and (@(Get-HarnessRequests).Body.model -join ',') -eq 'paid-model,unknown-model') 'All also applies to automatic selection and its fallback candidates'

        Set-HarnessResponses @((New-HarnessResponse 'paid lookup'))
        $paidLookup = Invoke-AgentHarness 'full lookup' @catalogSelection -Model paid-model -All
        Assert-Harness ($paidLookup.Model -eq 'paid-model' -and $paidLookup.Provider -eq 'TestA') 'All supports exact model lookup without an explicit provider'

        Set-HarnessRecoveryChoices @('Choose another model', 1)
        Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'paid recovery'))
        $paidRecovery = Invoke-AgentHarness 'full recovery' @catalogSelection -Provider TestA -Model first:free -All -ApiKey fake-test-key
        $replacementOptions = & $module { $script:RecoveryMenus[1].Options }
        $replacementRequest = @(Get-HarnessRequests)[-1]
        Assert-Harness ($paidRecovery.Model -eq 'paid-model' -and ($replacementOptions -join ',') -like '*unknown-model*') 'Recovery retains All and allows paid and unknown-price replacements'
        Assert-Harness (($replacementOptions -join ',') -notlike '*TestB*' -and $replacementRequest.Uri -eq 'https://provider.invalid/a/v1/chat/completions' -and $replacementRequest.Headers.Authorization -eq 'Bearer fake-test-key') 'Full-catalogue recovery retains provider restrictions and connection overrides'

        Set-HarnessRecoveryChoices @('Choose another model', 0)
        Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'free recovery'))
        $freeRecovery = Invoke-AgentHarness 'default recovery' @catalogSelection -Provider TestA -Model first:free
        $replacementOptions = & $module { $script:RecoveryMenus[1].Options }
        Assert-Harness ($freeRecovery.Model -eq 'second:free' -and $replacementOptions.Count -eq 3 -and ($replacementOptions -join ',') -notmatch 'paid-model|unknown-model') 'Recovery defaults to free models even after an All invocation'
    }
    finally {
        & $module { $script:Catalog['https://provider.invalid/a/v1/models'] = $script:OriginalCatalogA }
    }

    $script:RecoveryToolExecutions = 0
    $recoveryTools = @{
        once = @{ Script = { param($a, $ctx) $script:RecoveryToolExecutions++; 'completed once' } }
    }
    Set-HarnessRecoveryChoices @('Choose another model', 0)
    Set-HarnessResponses @(
        (New-HarnessResponse '' @((New-HarnessCall once))),
        (New-HarnessApiError 429), (New-HarnessApiError 429), (New-HarnessApiError 429), (New-HarnessApiError 429),
        (New-HarnessResponse 'continued with replacement')
    )
    $recovered = Invoke-AgentHarness 'recover mid-run' -Provider TestA -Model first:free -Quiet -NoBuiltinTools `
        -Tools $recoveryTools -WorkingDirectory $fixture -PassThru
    $requests = @(Get-HarnessRequests)
    Assert-Harness ($recovered.Answer -eq 'continued with replacement' -and $recovered.Model -eq 'second:free') 'Exhausted 429 retries allow choosing another model mid-run'
    Assert-Harness ($recovered.Iterations -eq 2 -and $requests.Count -eq 6) 'Recovery retries the same turn without consuming an extra model turn'
    Assert-Harness ($script:RecoveryToolExecutions -eq 1 -and $recovered.Messages.Count -eq 5) 'Completed tool is not re-executed or duplicated during model recovery'
    Assert-Harness ($requests[-1].Body.messages[-1].content -eq 'completed once' -and $requests[-1].Body.messages[-1].tool_call_id -eq 'call_test') 'Replacement request preserves tool output and call id'
    Assert-Harness (($requests[1].Body.messages | ConvertTo-Json -Depth 20 -Compress) -eq ($requests[-1].Body.messages | ConvertTo-Json -Depth 20 -Compress)) 'Replacement receives the full unchanged conversation'
    Assert-Harness ($recovered.PromptTokens -eq 20 -and $recovered.CompletionTokens -eq 4) 'Token totals include successful turns across models'
    Assert-Harness ((& $module { $script:Delays -join ',' }) -eq '2,4,8') 'Rate-limit retry budget is exhausted before recovery prompt'
    Assert-Harness ((& $module { $script:RecoveryMenus.Count }) -eq 2) 'Quiet mode still presents recovery action and model menus'

    # Choosing another provider uses its endpoint rather than the failed provider's.
    Set-HarnessRecoveryChoices @('Choose another model', 1)
    Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'other provider recovered'))
    $crossProvider = Invoke-AgentHarness 'other provider' -Provider TestA -Model first:free -Quiet -NoBuiltinTools -WorkingDirectory $fixture -PassThru
    Assert-Harness ($crossProvider.Provider -eq 'TestB' -and $crossProvider.Model -eq 'third:free') 'Recovery can explicitly choose a different registered provider'
    Assert-Harness (@(Get-HarnessRequests)[-1].Uri -eq 'https://provider.invalid/b/v1/chat/completions') 'Chosen provider endpoint used after recovery'

    # Exhausting initial automatic candidates also opens recovery, with a fresh attempt budget.
    Set-HarnessRecoveryChoices @('Choose another model', 0)
    Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'recovered initial failure'))
    $initialRecovery = Invoke-AgentHarness 'initial recovery' -Provider TestA -MaxModelAttempts 1 -Quiet -NoBuiltinTools -WorkingDirectory $fixture -PassThru
    Assert-Harness ($initialRecovery.Model -eq 'second:free' -and $initialRecovery.Iterations -eq 1) 'Initial automatic attempt exhaustion can recover in the same turn'

    $interactive = $basic.Clone(); $interactive.Remove('NoModelRecovery')
    Set-HarnessRecoveryChoices @('Retry current model')
    Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'retry chosen'))
    $retried = Invoke-AgentHarness 'retry current' @interactive -PassThru
    Assert-Harness ($retried.Model -eq 'custom-model' -and $retried.Iterations -eq 1 -and @(Get-HarnessRequests).Count -eq 2) 'User can retry the current model without restarting'

    Set-HarnessRecoveryChoices @('Choose another model', 0) -ModelIds @('  new-custom-model  ')
    Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'manual chosen'))
    $manual = Invoke-AgentHarness 'manual replacement' @interactive -ApiKey fake-test-key -PassThru
    Assert-Harness ($manual.Model -eq 'new-custom-model' -and $manual.Provider -eq 'custom') 'Custom endpoint recovery accepts another model ID'
    Assert-Harness (@(Get-HarnessRequests)[-1].Uri -eq $interactive.ChatUri -and @(Get-HarnessRequests)[-1].Headers.Authorization -eq 'Bearer fake-test-key') 'Custom endpoint and API key retained for manual model replacement'

    Set-HarnessRecoveryChoices @('Choose another model', 0)
    Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'restricted chosen'))
    $restricted = Invoke-AgentHarness 'restricted provider' -Provider TestA -Model first:free -ApiKey fake-test-key -Quiet -NoBuiltinTools -WorkingDirectory $fixture -PassThru
    $replacementOptions = & $module { $script:RecoveryMenus[1].Options }
    Assert-Harness (($replacementOptions -join ',') -notlike '*TestB*' -and $restricted.Provider -eq 'TestA') 'Explicit key restricts recovery choices to its original provider'

    Set-HarnessRecoveryChoices @('Choose another model', 0)
    Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessResponse 'restricted endpoint chosen'))
    $restrictedUri = Invoke-AgentHarness 'restricted endpoint' -Provider TestA -Model first:free -ChatUri https://provider.invalid/override -Quiet -NoBuiltinTools -WorkingDirectory $fixture -PassThru
    Assert-Harness ($restrictedUri.Provider -eq 'TestA' -and @(Get-HarnessRequests)[-1].Uri -eq 'https://provider.invalid/override') 'Explicit endpoint retained when choosing another model'

    Set-HarnessRecoveryChoices @('Choose another model', 0, 'Choose another model', 0) -ModelIds @('replacement-one', 'replacement-two')
    Set-HarnessResponses @((New-HarnessApiError 400), (New-HarnessApiError 400), (New-HarnessResponse 'second recovery succeeded'))
    $repeated = Invoke-AgentHarness 'repeated recovery' @interactive -PassThru
    Assert-Harness ($repeated.Model -eq 'replacement-two' -and $repeated.Iterations -eq 1) 'A failed replacement offers another recovery choice'

    Set-HarnessRecoveryChoices @('Stop')
    Set-HarnessResponses @((New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'stop recovery' @interactive } '*mock API failure*'
    Set-HarnessRecoveryChoices @($null)
    Set-HarnessResponses @((New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'escape recovery' @interactive } '*mock API failure*'
    Set-HarnessRecoveryChoices @('Choose another model', $null)
    Set-HarnessResponses @((New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'cancel model menu' @interactive } '*mock API failure*'
    Set-HarnessRecoveryChoices @('Choose another model', 0) -ModelIds @('   ')
    Set-HarnessResponses @((New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'blank model' @interactive } '*mock API failure*'

    Set-HarnessRecoveryChoices @('Stop')
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall empty))), (New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'stop after tool' @interactive -Tools $tools } '*mock API failure*'
    Set-HarnessRecoveryChoices @()
    Set-HarnessResponses @((New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'no recovery' @basic } '*mock API failure*'
    Assert-Harness ((& $module { $script:RecoveryMenus.Count }) -eq 0) 'NoModelRecovery prevents interactive menus'

    # All built-in file reads target synthetic files in the fixture, never the repo.
    Set-Content -LiteralPath (Join-Path $fixture 'sample.txt') -Value @('first line', 'second line')
    $fileCalls = @(
        (New-HarnessCall read_file '{"path":"sample.txt","start_line":2,"max_lines":1}'),
        (New-HarnessCall list_directory),
        (New-HarnessCall search_files '{"pattern":"second line","glob":"*.txt"}'),
        (New-HarnessCall read_file '{"path":"../outside.txt"}'),
        (New-HarnessCall write_file '{"path":"created.txt","content":"created"}'),
        (New-HarnessCall run_powershell '{"command":"[Console]::Write(\"shell ok\")"}')
    )
    Set-HarnessResponses @((New-HarnessResponse '' $fileCalls), (New-HarnessResponse 'files done'))
    $withBuiltins = $basic.Clone(); $withBuiltins.NoBuiltinTools = $false
    $result = Invoke-AgentHarness 'files' @withBuiltins -YOLO -PassThru
    $toolResults = @($result.Messages | Where-Object role -eq tool)
    Assert-Harness ($toolResults[0].content -like '*2: second line*') 'Built-in numbered file read'
    Assert-Harness ($toolResults[1].content -like '*sample.txt*' -and $toolResults[2].content -like '*sample.txt:2: second line*') 'Built-in listing and search'
    Assert-Harness ($toolResults[3].content -like 'ERROR: Path escapes*') 'Parent traversal rejected'
    Assert-Harness ((Get-Content -LiteralPath (Join-Path $fixture 'created.txt') -Raw).Trim() -eq 'created') 'Approved built-in write'
    Assert-Harness ($toolResults[5].content -like 'exit code: 0*shell ok*') 'Shell subprocess output'

    # Search exclusions use synthetic trees and record enumeration to prove pruning.
    $searchRoot = Join-Path $fixture 'search-fixture'
    $searchDirectories = @('deep/keep', 'vendor', 'deep/coverage', 'node_modules_extra', 'binary')
    foreach ($name in '.git', 'node_modules', 'dist', 'bin') {
        $searchDirectories += $name, "deep/$name/nested"
    }
    $searchDirectories += 'deep/BIN'
    $null = New-Item -ItemType Directory -Path $searchRoot
    Set-Content -LiteralPath (Join-Path $searchRoot 'visible.txt') -Value @('  HARNESS_SEARCH_NEEDLE  ', 'another line')
    foreach ($directory in $searchDirectories) {
        $folder = Join-Path $searchRoot $directory
        $null = New-Item -ItemType Directory -Path $folder -Force
        Set-Content -LiteralPath (Join-Path $folder 'visible.txt') -Value 'HARNESS_SEARCH_NEEDLE'
    }
    Set-Content -LiteralPath (Join-Path $searchRoot 'deep/keep/bin') -Value 'HARNESS_SEARCH_NEEDLE'
    & $module {
        $script:SearchEnumerations = [Collections.Generic.List[string]]::new()
        function script:Get-ChildItem {
            [CmdletBinding()]
            param([string]$LiteralPath, [switch]$File, [switch]$Directory, [string]$Filter)
            $script:SearchEnumerations.Add($LiteralPath)
            Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
        }
    }
    try {
        $searchCalls = @(
            (New-HarnessCall search_files '{"pattern":"harness_search_needle","path":"search-fixture","glob":"*.txt"}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture","glob":"*.txt","ignore_dirs":["VENDOR","coverage"]}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture","glob":"*.txt","ignore_dirs":[]}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture/bin"}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture/deep/node_modules/nested"}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture/vendor","ignore_dirs":["vendor"]}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture"}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture","ignore_dirs":"vendor"}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture","ignore_dirs":["deep/coverage"]}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture","ignore_dirs":[null]}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture","ignore_dirs":["ven*"]}'),
            (New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"../outside"}')
        )
        Set-HarnessResponses @((New-HarnessResponse '' $searchCalls), (New-HarnessResponse 'search done'))
        $searched = Invoke-AgentHarness 'search exclusions' @withBuiltins -PassThru
        $searchResults = @($searched.Messages | Where-Object role -eq tool)
        Assert-Harness (@($searchResults[0].content -split '\r?\n').Count -eq 6) 'Default exclusions skip root and nested ignored directories'
        Assert-Harness ($searchResults[0].content -like '*visible.txt:1: HARNESS_SEARCH_NEEDLE*') 'Search remains case-insensitive and trims matched lines'
        Assert-Harness ($searchResults[0].content -match 'deep[\\/]keep[\\/]visible.txt') 'Filename filters do not prevent recursion through other directory names'
        Assert-Harness ($searchResults[0].content -match 'node_modules_extra' -and $searchResults[0].content -match 'binary') 'Directory exclusions match whole names'
        Assert-Harness (@($searchResults[1].content -split '\r?\n').Count -eq 4 -and $searchResults[1].content -notmatch 'vendor|coverage') 'Agent exclusions extend defaults and match names case-insensitively at any depth'
        Assert-Harness ($searchResults[2].content -eq $searchResults[0].content) 'An empty ignore_dirs array preserves default exclusions'
        foreach ($index in 3, 4, 5) {
            Assert-Harness ($searchResults[$index].content -eq '(no output)') 'Explicit searches within ignored directories return no matches'
        }
        Assert-Harness ($searchResults[6].content -match 'deep[\\/]keep[\\/]bin:1:') 'Directory exclusions do not exclude files with the same name'
        Assert-Harness ($searchResults[7].content -like 'ERROR: ignore_dirs must be an array*') 'A scalar ignore_dirs value is rejected'
        foreach ($index in 8, 9, 10) {
            Assert-Harness ($searchResults[$index].content -like 'ERROR: ignore_dirs entries must be*') 'Invalid ignore_dirs entries return tool errors'
        }
        Assert-Harness ($searchResults[11].content -like 'ERROR: Path escapes*') 'Search still rejects paths outside the working directory'
        $enumerations = & $module { $script:SearchEnumerations.ToArray() }
        Assert-Harness (@($enumerations | Where-Object { $_ -match '[\\/](\.git|node_modules|dist|bin)([\\/]|$)' }).Count -eq 0) 'Ignored directories are never enumerated'
    }
    finally {
        & $module { Remove-Item Function:Get-ChildItem }
    }

    $limitRoot = Join-Path $searchRoot 'limit'
    $null = New-Item -ItemType Directory -Path $limitRoot
    Set-Content -LiteralPath (Join-Path $limitRoot 'many.txt') -Value @(1..60 | ForEach-Object { 'HARNESS_SEARCH_NEEDLE' })
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall search_files '{"pattern":"HARNESS_SEARCH_NEEDLE","path":"search-fixture/limit"}'))), (New-HarnessResponse))
    $limited = Invoke-AgentHarness 'search limit' @withBuiltins -PassThru
    $limitResult = @($limited.Messages | Where-Object role -eq tool)[0].content
    Assert-Harness (@($limitResult -split '\r?\n').Count -eq 51 -and $limitResult -like '*many.txt:50:*' -and $limitResult -like '*stopped after 50 matches*') 'Search retains the global 50 matching line limit and reports it'

    $searchContext = @{ Root = (Join-Path $searchRoot 'bin'); Quiet = $true }
    $rootResult = & $module {
        param($context)
        Invoke-AgentHarnessToolCall -Call @{ id = 'search_root'; function = @{ name = 'search_files'; arguments = '{"pattern":"HARNESS_SEARCH_NEEDLE"}' } } `
            -ToolTable (Get-AgentHarnessBuiltinTools) -Context $context
    } $searchContext
    Assert-Harness ($rootResult.content -like 'visible.txt:1:*') 'The working directory itself is eligible even when named bin'

    . (Join-Path $PSScriptRoot 'AgentHarness.SearchFiles.Tests.ps1')

    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall get_datetime))), (New-HarnessResponse))
    $result = Invoke-AgentHarness 'override' @withBuiltins -Tools @{ get_datetime = @{ Script = { param($a, $ctx) 'overridden' } } } -PassThru
    Assert-Harness ($result.Messages[3].content -eq 'overridden') 'Custom tool overrides built-in'
    $defaultNames = & $module { (Get-AgentHarnessBuiltinTools).Keys }
    Assert-Harness ($defaultNames.Count -eq 22 -and $defaultNames -contains 'ask_user' -and $defaultNames -contains 'show_interactive_menu' -and $defaultNames -contains 'write_file' -and $defaultNames -contains 'edit_file' -and $defaultNames -contains 'run_powershell' -and $defaultNames -contains 'view_image' -and $defaultNames -contains 'spawn_agent' -and $defaultNames -contains 'agent_status' -and $defaultNames -contains 'wait_agent' -and $defaultNames -contains 'stop_agent' -and $defaultNames -contains 'load_skill' -and $defaultNames -contains 'read_skill_resource' -and $defaultNames -contains 'list_skills' -and $defaultNames -contains 'refresh_skills') 'Twenty-two default built-in tools, including Python, user questions, folder skills and process lifecycle tools'

    . (Join-Path $PSScriptRoot 'AgentHarness.UserQuestions.Tests.ps1')

    # Menu interactions use synthetic replies; no console input or provider network calls.
    $savedMenu = & $module { ${function:Show-InteractiveMenu} }
    $savedSound = & $module { ${function:Invoke-Sound} }
    try {
        & $module {
            $script:MenuReplies = [Collections.Generic.Queue[object]]::new()
            $script:MenuReplies.Enqueue('Beta')
            $script:MenuReplies.Enqueue(@('Gamma', 'Alpha'))
            $script:MenuReplies.Enqueue('Alpha')
            $script:MenuReplies.Enqueue($null)
            $script:MenuCalls = [Collections.Generic.List[object]]::new()
            $script:MenuSounds = 0
            $script:MenuError = ''
            function script:Invoke-Sound { $script:MenuSounds++ }
            function script:Show-InteractiveMenu {
                [CmdletBinding()]
                param($Options, $Title, [switch]$MultiSelect, [switch]$Filter)
                $script:MenuCalls.Add(@{ Options = @($Options); Title = $Title; MultiSelect = [bool]$MultiSelect; Filter = [bool]$Filter })
                if ($script:MenuError -eq 'throw') { throw 'Synthetic menu failure.' }
                if ($script:MenuError -eq 'continue') { Write-Error 'Synthetic menu failure.' -ErrorAction Continue; return }
                if (-not $script:MenuReplies.Count) { throw 'Unexpected interactive menu.' }
                $script:MenuReplies.Dequeue()
            }
        }
        $menuArguments = '{"title":"Choose a feature","options":["Alpha","Beta","Gamma"]}'
        $multiArguments = '{"title":"Choose features","options":["Alpha","Beta","Gamma"],"multi_select":true}'
        $menuCalls = @(
            (New-HarnessCall show_interactive_menu $menuArguments menu_single),
            (New-HarnessCall show_interactive_menu $multiArguments menu_multiple),
            (New-HarnessCall show_interactive_menu $multiArguments menu_one),
            (New-HarnessCall show_interactive_menu $menuArguments menu_cancel)
        )
        Set-HarnessResponses @((New-HarnessResponse '' $menuCalls), (New-HarnessResponse 'choices received'))
        $menuRun = Invoke-AgentHarness 'Ask for choices' @withBuiltins -YOLO -NoShellTool -AllowWrite:$false -PassThru
        $menuResults = @($menuRun.Messages | Where-Object role -eq tool)
        $choices = @($menuResults | ForEach-Object { ConvertFrom-Json -InputObject $_.content })
        Assert-Harness ($menuRun.Answer -eq 'choices received' -and $menuResults.Count -eq 4) 'Menu tool round trip completes in Quiet and YOLO modes without shell or write tools'
        Assert-Harness (-not $choices[0].cancelled -and $choices[0].selections -is [array] -and $choices[0].selections.Count -eq 1 -and $choices[0].selections[0] -eq 'Beta') 'Single menu result retains an array'
        Assert-Harness (-not $choices[1].cancelled -and ($choices[1].selections -join ',') -eq 'Gamma,Alpha') 'Multiple menu results preserve selection order'
        Assert-Harness (-not $choices[2].cancelled -and $choices[2].selections -is [array] -and $choices[2].selections[0] -eq 'Alpha') 'Multi-select with one choice retains an array'
        Assert-Harness ($choices[3].cancelled -and $choices[3].selections -is [array] -and $choices[3].selections.Count -eq 0) 'Cancellation is explicit with an empty selections array'
        $menuRequests = @(Get-HarnessRequests)
        $menuSpec = @($menuRequests[0].Body.tools | Where-Object { $_.function.name -eq 'show_interactive_menu' })[0].function.parameters
        Assert-Harness (($menuSpec.oneOf[0].required -join ',') -eq 'title,options' -and $menuSpec.properties.options.type -eq 'array' -and $menuSpec.properties.multi_select.type -eq 'boolean') 'Provider receives the legacy menu argument schema'
        Assert-Harness (($menuSpec.oneOf[1].required -join ',') -eq 'questions' -and $menuSpec.properties.questions.type -eq 'array' -and $menuSpec.properties.questions.minItems -eq 1 -and ($menuSpec.properties.questions.items.required -join ',') -eq 'id,title,options') 'Provider receives the batch question schema with required IDs'
        Assert-Harness ($menuRequests[1].Body.messages[-1].tool_call_id -eq 'menu_cancel' -and $menuRequests[1].Body.messages[-1].content -eq $menuResults[3].content) 'Menu results and call IDs are sent to the next provider turn'
        $shownMenus = & $module { $script:MenuCalls.ToArray() }
        Assert-Harness ($shownMenus[0].Title -eq 'Choose a feature' -and ($shownMenus[0].Options -join ',') -eq 'Alpha,Beta,Gamma' -and -not $shownMenus[0].MultiSelect -and $shownMenus[1].MultiSelect -and $shownMenus[0].Filter) 'Menu receives the title, labels, selection mode and filtering'
        Assert-Harness ((& $module { $script:MenuSounds }) -eq 4) 'Menu sounds play even with Quiet and YOLO'

        & $module { $script:MenuReplies.Enqueue($null) }
        Set-HarnessResponses @((New-HarnessResponse '' @($menuCalls[0])), (New-HarnessResponse))
        $null = Invoke-AgentHarness 'Muted menu' @withBuiltins -NoPromptSound
        Assert-Harness ((& $module { $script:MenuSounds }) -eq 4) 'NoPromptSound mutes menu sounds'

        $invalidMenus = @(
            '{}', '[]', 'null',
            '{"title":" ","options":["Alpha"]}',
            '{"title":5,"options":["Alpha"]}',
            '{"title":"Choose"}',
            '{"title":"Choose","options":null}',
            '{"title":"Choose","options":[]}',
            '{"title":"Choose","options":"Alpha"}',
            '{"title":"Choose","options":[null]}',
            '{"title":"Choose","options":[1]}',
            '{"title":"Choose","options":[{}]}',
            '{"title":"Choose","options":[" "]}',
            '{"title":"Choose","options":["Alpha","Alpha"]}',
            '{"title":"Choose","options":["Alpha"],"multi_select":"false"}',
            '{"title":"Choose","options":["Alpha"],"multi_select":null}'
        )
        foreach ($preference in 'Continue', 'Stop') {
            foreach ($arguments in $invalidMenus) {
                $invalidMenu = & $module {
                    param($json, $preference)
                    $ErrorActionPreference = $preference
                    Invoke-AgentHarnessToolCall -Call @{ id = 'invalid_menu'; function = @{ name = 'show_interactive_menu'; arguments = $json } } `
                        -ToolTable (Get-AgentHarnessBuiltinTools) -Context @{ Quiet = $true; NoPromptSound = $true }
                } $arguments $preference
                Assert-Harness ($invalidMenu.content -like 'ERROR:*') "Malformed menu arguments return a tool error under $preference"
            }
        }
        Assert-Harness ((& $module { $script:MenuCalls.Count }) -eq 5) 'Malformed menu arguments never open a menu'
        foreach ($mode in 'throw', 'continue') {
            $failedMenu = & $module {
                param($json, $mode)
                $ErrorActionPreference = 'Continue'
                $script:MenuError = $mode
                Invoke-AgentHarnessToolCall -Call @{ id = 'failed_menu'; function = @{ name = 'show_interactive_menu'; arguments = $json } } `
                    -ToolTable (Get-AgentHarnessBuiltinTools) -Context @{ Quiet = $true; NoPromptSound = $true }
            } $menuArguments $mode
            Assert-Harness ($failedMenu.content -like 'ERROR:*Synthetic menu failure*') "Menu $mode errors return a tool error under Continue"
        }

        & $module {
            $script:MenuError = ''
            $script:MenuReplies.Enqueue('Beta')
            $script:MenuReplies.Enqueue(@('Gamma', 'Alpha'))
            $script:MenuReplies.Enqueue('Alpha')
            $script:MenuReplies.Enqueue('Beta')
            $script:MenuReplies.Enqueue($null)
            $script:MenuReplies.Enqueue($null)
        }
        $batchArguments = '{"questions":[{"id":"feature","title":"Choose a feature","options":["Alpha","Beta"]},{"id":"extras","title":"Choose extras","options":["Alpha","Beta","Gamma"],"multi_select":true}]}'
        $oneQuestionArguments = '{"questions":[{"id":"only","title":"Choose one","options":["Alpha"]}]}'
        $cancelBatchArguments = '{"questions":[{"id":"first","title":"First question","options":["Alpha","Beta"]},{"id":"second","title":"Second question","options":["Alpha","Beta"]},{"id":"unasked","title":"Do not show","options":["Alpha"]}]}'
        $batchCalls = @(
            (New-HarnessCall show_interactive_menu $batchArguments batch_complete),
            (New-HarnessCall show_interactive_menu $oneQuestionArguments batch_one),
            (New-HarnessCall show_interactive_menu $cancelBatchArguments batch_partial),
            (New-HarnessCall show_interactive_menu $batchArguments batch_cancel)
        )
        $beforeBatch = & $module { $script:MenuCalls.Count }
        Set-HarnessResponses @((New-HarnessResponse '' $batchCalls), (New-HarnessResponse 'batch choices received'))
        $batchRun = Invoke-AgentHarness 'Ask several questions' @withBuiltins -YOLO -NoShellTool -AllowWrite:$false -PassThru
        $batchResults = @($batchRun.Messages | Where-Object role -eq tool)
        $batches = @($batchResults | ForEach-Object { ConvertFrom-Json -InputObject $_.content })
        Assert-Harness ($batchRun.Answer -eq 'batch choices received' -and $batchResults.Count -eq 4) 'Batched questions round trip through one tool result per call in Quiet and YOLO'
        Assert-Harness (-not $batches[0].cancelled -and $batches[0].answers -is [array] -and $batches[0].answers.Count -eq 2 -and ($batches[0].answers.id -join ',') -eq 'feature,extras') 'Batch answers preserve question order and IDs'
        Assert-Harness (-not $batches[0].answers[0].cancelled -and $batches[0].answers[0].selections -is [array] -and $batches[0].answers[0].selections[0] -eq 'Beta' -and ($batches[0].answers[1].selections -join ',') -eq 'Gamma,Alpha') 'Batch supports independent single and multiple selections'
        Assert-Harness (-not $batches[1].cancelled -and $batches[1].answers -is [array] -and $batches[1].answers.Count -eq 1 -and $batches[1].answers[0].selections -is [array]) 'One-question batches preserve both JSON arrays'
        Assert-Harness ($batches[2].cancelled -and $batches[2].answers.Count -eq 2 -and $batches[2].answers[0].selections[0] -eq 'Beta' -and $batches[2].answers[1].id -eq 'second' -and $batches[2].answers[1].cancelled -and $batches[2].answers[1].selections -is [array] -and $batches[2].answers[1].selections.Count -eq 0) 'Batch cancellation preserves earlier answers and identifies the cancelled question'
        Assert-Harness ($batches[3].cancelled -and $batches[3].answers -is [array] -and $batches[3].answers.Count -eq 1 -and $batches[3].answers[0].id -eq 'feature') 'Cancellation on the first question returns one answer'
        $batchMenus = @((& $module { $script:MenuCalls.ToArray() }) | Select-Object -Skip $beforeBatch)
        Assert-Harness ($batchMenus.Count -eq 6 -and $batchMenus[0].Title -eq 'Choose a feature' -and ($batchMenus[0].Options -join ',') -eq 'Alpha,Beta' -and -not $batchMenus[0].MultiSelect -and $batchMenus[1].Title -eq 'Choose extras' -and $batchMenus[1].MultiSelect -and $batchMenus[1].Filter -and $batchMenus.Title -notcontains 'Do not show') 'Each batch question uses its own settings and remaining questions are skipped after cancellation'
        Assert-Harness ((& $module { $script:MenuSounds }) -eq 10) 'Each displayed batch question sounds once'
        $batchRequests = @(Get-HarnessRequests)
        Assert-Harness ($batchRequests[1].Body.messages[-1].tool_call_id -eq 'batch_cancel' -and $batchRequests[1].Body.messages[-1].content -eq $batchResults[3].content) 'Provider receives the batch JSON and tool call ID'

        $invalidBatches = @(
            '{"questions":null}', '{"questions":[]}', '{"questions":{}}', '{"questions":"invalid"}',
            '{"questions":[null]}', '{"questions":[[]]}', '{"questions":["invalid"]}',
            '{"questions":[{"title":"Choose","options":["Alpha"]}]}',
            '{"questions":[{"id":" ","title":"Choose","options":["Alpha"]}]}',
            '{"questions":[{"id":1,"title":"Choose","options":["Alpha"]}]}',
            '{"questions":[{"id":"same","title":"Choose","options":["Alpha"]},{"id":"same","title":"Choose","options":["Beta"]}]}',
            '{"title":"Choose","questions":[{"id":"one","title":"Choose","options":["Alpha"]}]}',
            '{"options":["Alpha"],"questions":[{"id":"one","title":"Choose","options":["Alpha"]}]}',
            '{"multi_select":false,"questions":[{"id":"one","title":"Choose","options":["Alpha"]}]}'
        )
        # Reuse invalid single-question fields in a later question to ensure whole-batch validation.
        foreach ($json in $invalidMenus | Select-Object -Skip 3) {
            $badQuestion = ConvertFrom-Json -InputObject $json -AsHashtable
            $badQuestion.id = 'bad'
            $invalidBatches += (@{ questions = @(@{ id = 'valid'; title = 'Valid'; options = @('Alpha') }, $badQuestion) } | ConvertTo-Json -Depth 10 -Compress)
        }
        $beforeInvalidBatches = & $module { $script:MenuCalls.Count }
        foreach ($preference in 'Continue', 'Stop') {
            foreach ($arguments in $invalidBatches) {
                $invalidBatch = & $module {
                    param($json, $preference)
                    $ErrorActionPreference = $preference
                    Invoke-AgentHarnessToolCall -Call @{ id = 'invalid_batch'; function = @{ name = 'show_interactive_menu'; arguments = $json } } `
                        -ToolTable (Get-AgentHarnessBuiltinTools) -Context @{ Quiet = $true; NoPromptSound = $true }
                } $arguments $preference
                Assert-Harness ($invalidBatch.content -like 'ERROR:*') "Malformed batch returns a tool error under $preference"
            }
        }
        Assert-Harness ((& $module { $script:MenuCalls.Count }) -eq $beforeInvalidBatches -and (& $module { $script:MenuSounds }) -eq 10) 'Invalid batches never open a menu or play a sound, including invalid later questions'
        foreach ($preference in 'Continue', 'Stop') {
            foreach ($mode in 'throw', 'continue') {
                $failedBatch = & $module {
                    param($json, $mode, $preference)
                    $ErrorActionPreference = $preference
                    $script:MenuError = $mode
                    Invoke-AgentHarnessToolCall -Call @{ id = 'failed_batch'; function = @{ name = 'show_interactive_menu'; arguments = $json } } `
                        -ToolTable (Get-AgentHarnessBuiltinTools) -Context @{ Quiet = $true; NoPromptSound = $true }
                } $batchArguments $mode $preference
                Assert-Harness ($failedBatch.content -like 'ERROR:*Synthetic menu failure*') "Batch $mode errors return a tool error under $preference"
            }
        }
        Assert-Harness ((& $module { $script:MenuCalls.Count }) -eq ($beforeInvalidBatches + 4)) 'Menu errors stop the batch before displaying the next question'
    }
    finally {
        & $module {
            param($menu, $sound)
            Set-Item Function:script:Show-InteractiveMenu -Value $menu
            Set-Item Function:script:Invoke-Sound -Value $sound
        } $savedMenu $savedSound
    }

    # Confirmation tests use the real child process, with synthetic commands confined to this fixture.
    & $module {
        $script:ConfirmationReplies = [Collections.Generic.Queue[string]]::new()
        $script:ConfirmationPrompts = [Collections.Generic.List[string]]::new()
        $script:ApprovalSounds = [Collections.Generic.List[object]]::new()
        $script:ApprovalEvents = [Collections.Generic.List[string]]::new()
        function script:Invoke-Sound {
            param([int]$Duration, [int]$Frequency)
            $script:ApprovalSounds.Add([pscustomobject]@{ Duration = $Duration; Frequency = $Frequency })
            $script:ApprovalEvents.Add('sound')
        }
        function script:Read-Host {
            param([string]$Prompt)
            $script:ConfirmationPrompts.Add($Prompt)
            $script:ApprovalEvents.Add('prompt')
            if (-not $script:ConfirmationReplies.Count) { throw 'Unexpected confirmation prompt.' }
            $script:ConfirmationReplies.Dequeue()
        }
    }
    $rawCommand = @'
$words = @('raw', 'command')
[IO.File]::WriteAllText((Join-Path (Get-Location).Path 'approved-shell.txt'), ($words -join ' '))
[Console]::Write(('quotes: ' + '"yes"') + "`n" + (Get-Location).Path)
[Console]::Error.Write('stderr text')
exit 7
'@
    $rawCall = New-HarnessCall run_powershell (@{ command = $rawCommand } | ConvertTo-Json -Compress)
    & $module { $script:ConfirmationReplies.Enqueue('n') }
    Set-HarnessResponses @((New-HarnessResponse '' @($rawCall)), (New-HarnessResponse))
    $confirmationInfo = @()
    $visibleApproval = $withBuiltins.Clone(); $visibleApproval.Quiet = $false
    $denied = Invoke-AgentHarness 'denied shell' @visibleApproval -PassThru -InformationVariable confirmationInfo 6>$null
    Assert-Harness ($denied.Messages[3].content -like 'ERROR: the user denied this command*') 'Denied shell call returns an error'
    Assert-Harness (-not (Test-Path -LiteralPath (Join-Path $fixture 'approved-shell.txt'))) 'Denied command does not execute'
    Assert-Harness (($confirmationInfo.MessageData.Message -join "`n").Contains($rawCommand)) 'Approval block displays the entire raw command'
    Assert-Harness (@($confirmationInfo | Where-Object { [string]$_.MessageData.Message -eq 'Tool: run_powershell' }).Count -eq 0) 'Command requiring approval is not duplicated in a tool-call block'
    Assert-Harness (@($confirmationInfo | Where-Object { [string]$_.MessageData.Message -like 'Result: run_powershell*' -and $_.MessageData.ForegroundColor -eq [ConsoleColor]::Red }).Count -eq 1) 'Denied tool result has a red result heading'
    & $module { $script:ConfirmationReplies.Enqueue('yes') }
    Set-HarnessResponses @((New-HarnessResponse '' @($rawCall)), (New-HarnessResponse))
    $approved = Invoke-AgentHarness 'approved shell' @withBuiltins -PassThru 6>$null
    Assert-Harness ((Get-Content -LiteralPath (Join-Path $fixture 'approved-shell.txt') -Raw) -eq 'raw command') 'Approved raw multiline command executes'
    Assert-Harness ($approved.Messages[3].content.Contains('exit code: 7') -and $approved.Messages[3].content.Contains('quotes: "yes"')) 'Shell preserves quotes and exit code'
    Assert-Harness ($approved.Messages[3].content.Contains($fixture, [StringComparison]::OrdinalIgnoreCase) -and $approved.Messages[3].content.Contains('stderr text')) 'Shell uses working directory and captures stderr (Windows paths ignore case)'
    Assert-Harness ($approved.Messages[3].content.Contains("`n`nOutput:`n") -and $approved.Messages[3].content.Contains("`n`nErrors:`nstderr text")) 'Shell stdout and stderr are separated into readable sections'
    Assert-Harness ((& $module { $script:ConfirmationPrompts.Count }) -eq 2) 'Each non-YOLO command requires confirmation'
    Assert-Harness ((& $module { $script:ApprovalSounds.Count }) -eq 2) 'Each shell approval plays a notification sound'
    Assert-Harness ((& $module { $script:ApprovalEvents -join ',' }) -eq 'sound,prompt,sound,prompt') 'Sound plays immediately before waiting for permission'
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall run_powershell '{"command":"[Console]::Write(\"yolo\")"}'))), (New-HarnessResponse))
    $info = @()
    $yolo = Invoke-AgentHarness 'yolo shell' @visibleApproval -YOLO -PassThru -InformationVariable info 6>$null
    Assert-Harness ($yolo.Messages[3].content -like 'exit code: 0*yolo*' -and (& $module { $script:ConfirmationPrompts.Count }) -eq 2) 'YOLO runs shell without a confirmation prompt'
    Assert-Harness (@($info | ForEach-Object { [string]$_.MessageData.Message }) -contains ("command:`n" + '[Console]::Write("yolo")')) 'YOLO tool-call block displays raw PowerShell instead of escaped JSON'
    Assert-Harness ((& $module { $script:ApprovalSounds.Count }) -eq 2) 'YOLO shell execution skips notification sounds'
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall run_powershell '{"command":"[Console]::Write(\"legacy\")"}'))), (New-HarnessResponse))
    $legacy = Invoke-AgentHarness 'legacy approval' @withBuiltins -AutoApprove -PassThru
    Assert-Harness ($legacy.Messages[3].content -like 'exit code: 0*legacy*' -and (& $module { $script:ConfirmationPrompts.Count }) -eq 2) 'AutoApprove alias enables YOLO'
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'disable shell' @withBuiltins -NoShellTool
    Assert-Harness (@(Get-HarnessRequests)[0].Body.tools.function.name -notcontains 'run_powershell') 'NoShellTool disables advertised shell tool'
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'legacy disable shell' @withBuiltins -AllowShell:$false
    Assert-Harness (@(Get-HarnessRequests)[0].Body.tools.function.name -notcontains 'run_powershell') 'AllowShell false remains supported'

    # Every file write must be approved unless YOLO is active.
    $writePath = Join-Path $fixture 'confirmation-target/original.txt'
    $writeCall = New-HarnessCall write_file '{"path":"confirmation-target/original.txt","content":"replacement text"}'
    & $module { $script:ConfirmationReplies.Enqueue('n') }
    Set-HarnessResponses @((New-HarnessResponse '' @($writeCall)), (New-HarnessResponse))
    $confirmationInfo = @()
    $denied = Invoke-AgentHarness 'denied write' @withBuiltins -PassThru -InformationVariable confirmationInfo 6>$null
    Assert-Harness ($denied.Messages[3].content -like 'ERROR: the user denied this write*') 'Denied write returns an error'
    Assert-Harness (-not (Test-Path -LiteralPath (Split-Path $writePath -Parent))) 'Denied write creates neither file nor parent directory'
    Assert-Harness (($confirmationInfo.MessageData.Message -join "`n").Contains("write confirmation-target/original.txt:`nreplacement text")) 'Quiet mode still shows proposed write path and contents'
    $null = New-Item -ItemType Directory -Path (Split-Path $writePath -Parent)
    Set-Content -LiteralPath $writePath -Value 'original text' -NoNewline
    & $module { $script:ConfirmationReplies.Enqueue('') }
    Set-HarnessResponses @((New-HarnessResponse '' @($writeCall)), (New-HarnessResponse))
    $denied = Invoke-AgentHarness 'deny overwrite' @withBuiltins -PassThru 6>$null
    Assert-Harness ((Get-Content -LiteralPath $writePath -Raw) -eq 'original text') 'Empty confirmation preserves existing file'
    & $module { $script:ConfirmationReplies.Enqueue('y') }
    Set-HarnessResponses @((New-HarnessResponse '' @($writeCall)), (New-HarnessResponse))
    $approved = Invoke-AgentHarness 'approve write' @withBuiltins -PassThru 6>$null
    Assert-Harness ((Get-Content -LiteralPath $writePath -Raw).Trim() -eq 'replacement text' -and $approved.Messages[3].content -like 'Wrote*') 'Approved write updates the file'
    $promptCount = & $module { $script:ConfirmationPrompts.Count }
    Assert-Harness ($promptCount -eq 5) 'Every non-YOLO shell command and write asks for approval'
    Assert-Harness ((& $module { $script:ApprovalSounds.Count }) -eq $promptCount) 'Each file approval also plays a sound, including Quiet mode'
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall write_file '{"path":"yolo-write.txt","content":"no prompt"}'))), (New-HarnessResponse))
    $yoloWrite = Invoke-AgentHarness 'yolo write' @withBuiltins -YOLO -PassThru
    Assert-Harness ((Get-Content -LiteralPath (Join-Path $fixture 'yolo-write.txt') -Raw).Trim() -eq 'no prompt' -and (& $module { $script:ConfirmationPrompts.Count }) -eq $promptCount) 'YOLO writes without asking for confirmation'
    Assert-Harness ((& $module { $script:ApprovalSounds.Count }) -eq $promptCount) 'YOLO file writing skips notification sounds'
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'disable writing' @withBuiltins -AllowWrite:$false
    Assert-Harness (@(Get-HarnessRequests)[0].Body.tools.function.name -notcontains 'write_file') 'AllowWrite false disables the write tool'

    & $module { $script:ConfirmationReplies.Enqueue('n') }
    Set-HarnessResponses @((New-HarnessResponse '' @($writeCall)), (New-HarnessResponse))
    $muted = Invoke-AgentHarness 'mute approval sound' @withBuiltins -NoPromptSound -PassThru 6>$null
    Assert-Harness ($muted.Messages[3].content -like 'ERROR: the user denied this write*' -and (& $module { $script:ConfirmationPrompts.Count }) -eq ($promptCount + 1)) 'NoPromptSound retains permission confirmation'
    Assert-Harness ((& $module { $script:ApprovalSounds.Count }) -eq $promptCount) 'NoPromptSound mutes permission notification'

    # An unavailable audio device or player must not prevent confirmation.
    & $module { function script:Invoke-Sound { param($Duration, $Frequency) throw 'mock audio device unavailable' } }
    & $module { $script:ConfirmationReplies.Enqueue('n') }
    Set-HarnessResponses @((New-HarnessResponse '' @($writeCall)), (New-HarnessResponse))
    $noAudio = Invoke-AgentHarness 'audio unavailable' @withBuiltins -PassThru 6>$null
    Assert-Harness ($noAudio.Messages[3].content -like 'ERROR: the user denied this write*' -and (& $module { $script:ConfirmationPrompts.Count }) -eq ($promptCount + 2)) 'Audio failure still permits approval or denial'

    # Approval guidance becomes a user message, interrupting the old batch before replanning.
    $guidancePath = Join-Path $fixture 'guidance-target/original.txt'
    $guidanceCommandPath = Join-Path $fixture 'guidance-shell.txt'
    $guidanceShell = New-HarnessCall run_powershell (@{
            command = "[IO.File]::WriteAllText((Join-Path (Get-Location).Path 'guidance-shell.txt'), 'should not run')"
        } | ConvertTo-Json -Compress) 'guidance_shell'
    $guidanceWrite = New-HarnessCall write_file '{"path":"guidance-target/original.txt","content":"should not write"}' 'guidance_write'
    $pendingWrite = New-HarnessCall write_file '{"path":"guidance-target/pending.txt","content":"stale plan"}' 'pending_write'
    $pendingRead = New-HarnessCall get_datetime '{}' 'pending_read'
    $priorRead = New-HarnessCall get_datetime '{}' 'prior_read'
    foreach ($preference in 'Continue', 'Stop') {
        foreach ($proposed in $guidanceShell, $guidanceWrite) {
            $guidance = '  Yes, but first use the existing browser. Keep @clipboard literal. ' + ('More guidance. ' * 30)
            & $module { param($reply) $script:ConfirmationReplies.Enqueue($reply) } $guidance
            $beforePrompts = & $module { $script:ConfirmationPrompts.Count }
            Set-HarnessResponses @(
                (New-HarnessResponse '' @($priorRead, $proposed, $pendingWrite, $pendingRead)),
                (New-HarnessResponse '' @((New-HarnessCall write_file '{"path":"guidance-revised.txt","content":"revised plan"}' 'revised_write'))),
                (New-HarnessResponse 'followed guidance')
            )
            & $module { $script:ConfirmationReplies.Enqueue(' YES ') }
            $savedPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = $preference
                $guided = Invoke-AgentHarness 'approval guidance' @withBuiltins -NoPromptSound -MaxToolOutputChars 40 -PassThru 6>$null
            }
            finally { $ErrorActionPreference = $savedPreference }
            $requests = @(Get-HarnessRequests)
            $replan = @($requests[1].Body.messages)
            Assert-Harness ($guided.Answer -eq 'followed guidance' -and $requests.Count -eq 3) "Guidance resumes the agent under $preference"
            Assert-Harness (-not (Test-Path -LiteralPath $guidanceCommandPath) -and -not (Test-Path -LiteralPath (Split-Path $guidancePath -Parent))) 'Guidance executes neither the proposed action nor pending writes'
            Assert-Harness ((& $module { $script:ConfirmationPrompts.Count }) -eq ($beforePrompts + 2)) 'Guidance skips pending approval prompts and revised action still needs approval'
            Assert-Harness ($replan.Count -eq 8 -and $replan[7].role -eq 'user' -and $replan[7].content -ceq $guidance) 'Full guidance is a separate user message after all tool results, without truncation or marker expansion'
            Assert-Harness ($replan[3].content -notlike '*Skipped*' -and $replan[4].content -like 'ERROR: the user denied*') 'Completed tools stay completed and the proposed action is denied'
            Assert-Harness ($replan[5].content -like 'Skipped:*' -and $replan[6].content -like 'Skipped:*') 'All remaining tools, including read-only tools, are skipped for replanning'
            Assert-Harness (($replan[3..6].tool_call_id -join ',') -eq "prior_read,$($proposed.id),pending_write,pending_read") 'Every tool-call ID has a response before the guidance user message'
            Assert-Harness ((Get-Content -LiteralPath (Join-Path $fixture 'guidance-revised.txt') -Raw).Trim() -eq 'revised plan' -and $guided.Messages[9].content -like 'Wrote*') 'Approval feedback clears before the revised batch executes'
            Assert-Harness ((& $module { $script:ConfirmationPrompts[$script:ConfirmationPrompts.Count - 2] }) -like '*type guidance*') 'Approval prompt advertises custom guidance'
            $compacted = & $module {
                param($history)
                New-AgentHarnessMessages -SystemPrompt 'test' -Prompt 'continue' -History $history -KeepLatestAnswer
            } $guided.Messages
            Assert-Harness (@($compacted | Where-Object { $_.role -eq 'user' -and $_.content -ceq $guidance }).Count -eq 1) 'Guidance survives conversation compaction'
        }
    }

    # Plain denials do not interrupt unrelated pending tools or inject user messages.
    foreach ($reply in 'n', ' NO ', '', '   ') {
        & $module { param($reply) $script:ConfirmationReplies.Enqueue($reply) } $reply
        Set-HarnessResponses @((New-HarnessResponse '' @($guidanceWrite, $pendingRead)), (New-HarnessResponse))
        $denied = Invoke-AgentHarness 'plain denial' @withBuiltins -NoPromptSound -PassThru 6>$null
        Assert-Harness ($denied.Messages[3].content -like 'ERROR: the user denied this write*' -and $denied.Messages[4].content -notlike 'Skipped:*') 'Plain denial preserves normal processing of remaining calls'
        Assert-Harness (@($denied.Messages | Where-Object { $_.role -eq 'user' }).Count -eq 1) 'Plain denial adds no guidance message'
    }
    Assert-Harness (-not (Test-Path -LiteralPath (Split-Path $guidancePath -Parent))) 'Denials leave proposed parent directories absent'

    # Folder skills use synthetic roots and the same mocked provider.
    . (Join-Path $PSScriptRoot 'AgentHarness.Skills.Tests.ps1')

    # Sub-agent tests use synthetic task files and mocked child provider responses.
    . (Join-Path $PSScriptRoot 'AgentHarness.SubAgents.Tests.ps1')

    # Reuse this isolated module and mocked provider for targeted file-edit tests.
    . (Join-Path $PSScriptRoot 'AgentHarness.EditFile.Tests.ps1')

    # Completion prompts are deterministic harness behavior, including without tools.
    & $module {
        $script:CompletionReplies = [Collections.Generic.Queue[object]]::new()
        $script:CompletionPrompts = [Collections.Generic.List[string]]::new()
        $script:CompletionSounds = 0
        function script:Read-Host {
            param([string]$Prompt)
            $script:CompletionPrompts.Add($Prompt)
            if (-not $script:CompletionReplies.Count) { throw 'Unexpected completion prompt.' }
            $reply = $script:CompletionReplies.Dequeue()
            if ($reply -is [scriptblock]) { return (& $reply) }
            $reply
        }
        function script:Invoke-Sound { $script:CompletionSounds++ }
    }
    $completionOptions = $basic.Clone()
    $completionOptions.NoCompletionPrompt = $false
    $completionOptions.NoPromptSound = $true
    & $module { $script:CompletionReplies.Enqueue('exit') }
    Set-HarnessResponses @((New-HarnessResponse 'finished'))
    $completionInfo = @()
    $stopped = Invoke-AgentHarness 'finish' @completionOptions -PassThru -InformationVariable completionInfo 6>$null
    Assert-Harness ($stopped.Answer -eq 'finished' -and @(Get-HarnessRequests).Count -eq 1) 'Stop returns the completed answer without another API request'
    Assert-Harness (($completionInfo.MessageData.Message -join "`n").Contains('finished')) 'Quiet mode displays the final answer before asking what next'
    Assert-Harness ((& $module { $script:CompletionPrompts.Count }) -eq 1 -and (& $module { $script:CompletionSounds }) -eq 0) 'NoPromptSound mutes completion sound without skipping the checkpoint'
    Assert-Harness ((& $module { $script:CompletionPrompts[0] }) -eq 'Continue with another task or stop? [exit]') 'Completion accepts the next task at a single prompt with exit as the stop command'

    $continuationHistory = @(
        @{ role = 'system'; content = 'stale system' },
        @{ role = 'user'; content = 'oldest user request' },
        @{ role = 'assistant'; content = 'older final answer' },
        @{ role = 'user'; content = 'previous user request' },
        @{ role = 'assistant'; content = 'old tool commentary'; tool_calls = @((New-HarnessCall echo '{"text":"old"}')) },
        @{ role = 'tool'; content = 'old tool output'; tool_call_id = 'call_test' },
        @{ role = 'assistant'; content = 'previous final answer' }
    )
    $historyBefore = $continuationHistory | ConvertTo-Json -Depth 20 -Compress
    Set-Content -LiteralPath $agentsPath -Value 'Completion instructions before refresh.'
    & $module {
        param($path)
        $script:CompletionAgentsPath = $path
        $script:CompletionPrompts.Clear()
        $script:CompletionReplies.Enqueue({
                Set-Content -LiteralPath $script:CompletionAgentsPath -Value 'Completion instructions refreshed.'
                'second task'
            })
        $script:CompletionReplies.Enqueue('third task')
        $script:CompletionReplies.Enqueue('exit')
    } $agentsPath
    Set-HarnessResponses @(
        (New-HarnessResponse 'first commentary' @((New-HarnessCall echo '{"text":"first"}'))),
        (New-HarnessResponse 'first final answer'),
        (New-HarnessResponse 'second commentary' @((New-HarnessCall echo '{"text":"second"}'))),
        (New-HarnessResponse 'second final answer'),
        (New-HarnessResponse 'third final answer')
    )
    $continued = Invoke-AgentHarness 'first task' @completionOptions -Tools $tools -History $continuationHistory `
        -Instructions 'Keep these extra instructions.' -MaxIterations 2 -PassThru -YOLO 6>$null
    $continuedRequests = @(Get-HarnessRequests)
    $secondHistory = @($continuedRequests[2].Body.messages)
    $thirdHistory = @($continuedRequests[4].Body.messages)
    Assert-Harness ($continued.Answer -eq 'third final answer' -and $continued.Iterations -eq 5) 'Repeated continuation resets each task budget and reports total iterations'
    Assert-Harness ($continued.PromptTokens -eq 50 -and $continued.CompletionTokens -eq 10) 'Token accounting covers all continued tasks'
    Assert-Harness (($secondHistory.role -join ',') -eq 'system,user,user,user,assistant,user') 'Continuation retains only system, user requests, latest final answer and next prompt'
    Assert-Harness (($secondHistory.content | Select-Object -Skip 1) -join '|' -eq 'oldest user request|previous user request|first task|first final answer|second task') 'Retained user requests and final answer stay in chronological order'
    Assert-Harness (($thirdHistory.role -join ',') -eq 'system,user,user,user,user,assistant,user' -and $thirdHistory[-2].content -eq 'second final answer') 'Next continuation replaces the previously retained final answer'
    Assert-Harness (@($secondHistory + $thirdHistory | Where-Object { $_.role -eq 'tool' -or $_.tool_calls -or $_.tool_call_id }).Count -eq 0) 'No previous tool calls, results or metadata reach continued tasks'
    Assert-Harness ($secondHistory[0].content.Contains('Completion instructions refreshed.') -and $secondHistory[0].content.EndsWith('Keep these extra instructions.')) 'Continuation reloads AGENTS.md and preserves additional instructions'
    Assert-Harness (($continuationHistory | ConvertTo-Json -Depth 20 -Compress) -eq $historyBefore) 'Compaction does not mutate caller history'
    Assert-Harness (@($continuedRequests | Where-Object { $_.Uri -ne $basic.ChatUri -or $_.Body.model -ne $basic.Model }).Count -eq 0) 'Continuation retains the current endpoint and model'
    Assert-Harness ((& $module { $script:CompletionPrompts.Count }) -eq 3) 'YOLO asks once at every completion without a separate next-task prompt'
    Remove-Item -LiteralPath $agentsPath

    # Completion compaction keeps attachment arrays on their original user messages.
    & $module {
        $script:CompletionReplies.Enqueue('Follow up on those attachments')
        $script:CompletionReplies.Enqueue('exit')
    }
    Set-HarnessResponses @(
        (New-HarnessResponse '' @((New-HarnessCall inspect))),
        (New-HarnessResponse 'first media answer'),
        (New-HarnessResponse 'continued media answer')
    )
    $mediaContinued = Invoke-AgentHarness 'Another image' @completionOptions -History $attachmentResult.Messages `
        -Attachments $imagePath -Tools $attachmentTool -PassThru 6>$null
    $mediaContinuation = @(Get-HarnessRequests)[2].Body.messages
    Assert-Harness (($mediaContinuation.role -join ',') -eq 'system,user,user,assistant,user') 'Attachment continuation compacts previous assistant and tool messages'
    Assert-Harness ($mediaContinuation[1].content.Count -eq 6 -and $mediaContinuation[2].content.Count -eq 2) 'Completion compaction retains both historic and current attachment arrays'
    Assert-Harness ($mediaContinuation[1].content[3].text -like '`[video:*' -and $mediaContinuation[2].content[1].text -like '`[image:*') 'Continuation preserves image and video placeholders after their first accepted turn'
    Assert-Harness ($mediaContinuation[-1].content -is [string] -and $mediaContinuation[-1].content -eq 'Follow up on those attachments' -and $mediaContinued.Answer -eq 'continued media answer') 'Attachments stay on their original prompts without duplication on the next task'
    Assert-Harness (($attachmentResult.Messages | ConvertTo-Json -Depth 20 -Compress) -eq $attachmentHistoryBefore) 'Continuation does not mutate caller attachment history'

    # Add new media from the conversation prompt without restarting the invocation.
    & $module {
        $script:CompletionReplies.Enqueue('Review these @attach("media/image [1].PNG") @attach("report.pdf") @attach("media/clip.mp4")')
        $script:CompletionReplies.Enqueue('What else is visible?')
        $script:CompletionReplies.Enqueue('exit')
    }
    Set-HarnessResponses @((New-HarnessResponse 'ready'), (New-HarnessResponse 'media reviewed'), (New-HarnessResponse 'follow-up complete'))
    $inlineContinued = Invoke-AgentHarness 'Start a conversation' @completionOptions -PassThru 6>$null
    $inlineRequests = @(Get-HarnessRequests)
    Assert-Harness ($inlineContinued.Iterations -eq 3 -and $inlineContinued.Answer -eq 'follow-up complete') 'Attachments can be added during an active conversation'
    Assert-Harness (($inlineRequests[1].Body.messages[-1].content.type -join ',') -eq 'text,image_url,file,video_url' -and $inlineRequests[1].Body.messages[-1].content[0].text -eq 'Review these') 'Continuation attaches images, files and videos from typed markers'
    Assert-Harness ($inlineRequests[1].Body.messages[-1].content[1].image_url.url -eq $attachmentParts[1].image_url.url -and $inlineRequests[1].Body.messages[-1].content[2].file.file_data -eq $attachmentParts[2].file.file_data -and $inlineRequests[1].Body.messages[-1].content[3].video_url.url -eq $attachmentParts[3].video_url.url) 'Continuation injects the exact image, file and video bytes'
    Assert-Harness ($inlineRequests[2].Body.messages[2].content[1].text -like '`[image:*' -and $inlineRequests[2].Body.messages[-1].content -eq 'What else is visible?') 'Later continuation retains inline attachment placeholders'

    foreach ($preference in 'Continue', 'Stop') {
        $ErrorActionPreference = $preference
        & $module {
            $script:CompletionReplies.Enqueue('Bad syntax @attach("unterminated.png"')
            $script:CompletionReplies.Enqueue('Missing @attach("missing.png")')
            $script:CompletionReplies.Enqueue('Directory @attach("media")')
            $script:CompletionReplies.Enqueue('Invalid text @attach("media/invalid.txt")')
            $script:CompletionReplies.Enqueue('Try again @attach("media/image [1].PNG")')
            $script:CompletionReplies.Enqueue('exit')
        }
        Set-HarnessResponses @((New-HarnessResponse 'ready for media'), (New-HarnessResponse 'valid media received'))
        $invalidPromptInfo = @()
        $recoveredPrompt = Invoke-AgentHarness 'Keep this conversation' @completionOptions -MaxIterations 1 -PassThru -InformationVariable invalidPromptInfo 6>$null
        $recoveredRequests = @(Get-HarnessRequests)
        Assert-Harness ($recoveredPrompt.Answer -eq 'valid media received' -and $recoveredRequests.Count -eq 2 -and $recoveredPrompt.Iterations -eq 2) 'Invalid continuation syntax, files and encoding reprompt without a request or iteration charge under Continue and Stop'
        Assert-Harness ($recoveredRequests[1].Body.messages[1].content -eq 'Keep this conversation' -and $recoveredRequests[1].Body.messages[-2].content -eq 'ready for media' -and $recoveredRequests[1].Body.messages[-1].content[0].text -eq 'Try again') 'A corrected attachment prompt retains conversation and excludes failed prompts'
        Assert-Harness (@($invalidPromptInfo | Where-Object { [string]$_.MessageData -eq 'Invalid prompt' }).Count -eq 4) 'Each invalid attachment has a visible error, including Quiet mode'
        Assert-Harness (@($invalidPromptInfo | Where-Object { [string]$_.MessageData -eq 'Task complete' }).Count -eq 2) 'Reprompting does not repeat the completed answer'
        & $module {
            $script:CompletionReplies.Enqueue('Missing @attach("missing.png")')
            $script:CompletionReplies.Enqueue('exit')
        }
        Set-HarnessResponses @((New-HarnessResponse 'preserved answer'))
        $cancelledAttachment = Invoke-AgentHarness 'Finish after invalid attachment' @completionOptions -PassThru 6>$null
        Assert-Harness ($cancelledAttachment.Answer -eq 'preserved answer' -and $cancelledAttachment.Iterations -eq 1 -and @(Get-HarnessRequests).Count -eq 1) 'Exit after an invalid attachment returns the existing answer and conversation'
    }
    $ErrorActionPreference = 'Stop'

    # Clipboard errors can be corrected while the conversation stays active.
    & $module {
        param($reader, $dataUrl)
        Set-Item Function:script:Get-AgentHarnessClipboardImage -Value $reader
        $script:ClipboardReads = 0
        $script:ClipboardDataUrl = $dataUrl
        $script:CompletionReplies.Enqueue({
                $script:ClipboardFailure = 'No image found in the clipboard. Copy a screenshot first.'
                'Explain this @clipboard'
            })
        $script:CompletionReplies.Enqueue({
                $script:ClipboardFailure = $null
                'Explain this screenshot @clipboard'
            })
        $script:CompletionReplies.Enqueue({
                $script:ClipboardDataUrl = 'data:image/png;base64,AA=='
                'What else can you see?'
            })
        $script:CompletionReplies.Enqueue('exit')
    } $clipboardMock $attachmentParts[1].image_url.url
    try {
        Set-HarnessResponses @((New-HarnessResponse 'ready for screenshot'), (New-HarnessResponse 'screenshot reviewed'), (New-HarnessResponse 'screenshot follow-up'))
        $clipboardInfo = @()
        $clipboardContinued = Invoke-AgentHarness 'Start screenshot review' @completionOptions -PassThru -InformationVariable clipboardInfo 6>$null
        $clipboardRequests = @(Get-HarnessRequests)
        Assert-Harness ($clipboardContinued.Answer -eq 'screenshot follow-up' -and $clipboardRequests.Count -eq 3 -and $clipboardContinued.Iterations -eq 3) 'An empty clipboard reprompts before successfully attaching a screenshot in the running conversation'
        Assert-Harness ($clipboardRequests[1].Body.messages[-1].content[1].image_url.url -eq $attachmentParts[1].image_url.url -and $clipboardRequests[1].Body.messages[-2].content -eq 'ready for screenshot') 'Clipboard retry preserves the previous final answer and includes the PNG screenshot'
        Assert-Harness ((& $module { $script:ClipboardReads }) -eq 2 -and $clipboardRequests[2].Body.messages[2].content[1].text -like '`[image: clipboard*') 'Later turns retain the screenshot placeholder without recapturing the changed clipboard'
        Assert-Harness (($clipboardInfo.MessageData -join "`n").Contains('No image found in the clipboard.')) 'Missing screenshot error is visible during the conversation'
    }
    finally {
        & $module {
            param($reader)
            $script:ClipboardFailure = $null
            Set-Item Function:script:Get-AgentHarnessClipboardImage -Value $reader
        } $savedClipboardReader
    }

    # Enter, EOF/null and an exact exit command stop without another request.
    foreach ($replies in @(@(''), @($null), @('exit'), @('  ExIt  '))) {
        & $module {
            param($items)
            foreach ($item in $items) { $script:CompletionReplies.Enqueue($item) }
        } $replies
        Set-HarnessResponses @((New-HarnessResponse 'stopped safely'))
        $answer = Invoke-AgentHarness 'stop variants' @completionOptions 6>$null
        Assert-Harness ($answer -eq 'stopped safely' -and @(Get-HarnessRequests).Count -eq 1) 'Blank/cancelled input and exit stop without forwarding the command to the provider'
    }
    foreach ($nextTask in 'c', 'continue', 's', 'stop', 'Explain the exit command') {
        $nextPrompt = & $module {
            param($task)
            $script:CompletionReplies.Enqueue($task)
            Read-AgentHarnessNextPrompt -Answer 'done' -NoPromptSound
        } $nextTask 6>$null
        Assert-Harness ($nextPrompt -ceq $nextTask) 'Every non-exit task is accepted directly without interpreting old menu commands'
    }
    $sounded = $completionOptions.Clone(); $sounded.NoPromptSound = $false
    & $module { $script:CompletionReplies.Enqueue('exit') }
    Set-HarnessResponses @((New-HarnessResponse 'sound'))
    $null = Invoke-AgentHarness 'sound' @sounded 6>$null
    Assert-Harness ((& $module { $script:CompletionSounds }) -eq 1) 'Completion plays a notification sound by default'
    & $module {
        function script:Invoke-Sound { throw 'mock audio unavailable' }
        $script:CompletionReplies.Enqueue('exit')
    }
    Set-HarnessResponses @((New-HarnessResponse 'no audio'))
    Assert-Harness ((Invoke-AgentHarness 'no audio' @sounded 6>$null) -eq 'no audio') 'Audio failure does not prevent stopping'

    $promptCount = & $module { $script:CompletionPrompts.Count }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall empty))))
    $limited = Invoke-AgentHarness 'unfinished' @completionOptions -Tools $tools -MaxIterations 1 -PassThru 3>$null
    Assert-Harness ($limited.Answer -eq '' -and (& $module { $script:CompletionPrompts.Count }) -eq $promptCount) 'Iteration exhaustion does not claim completion or prompt'
    Set-HarnessResponses @((New-HarnessResponse 'one task'))
    $null = Invoke-AgentHarness 'unattended' @basic
    Assert-Harness ((& $module { $script:CompletionPrompts.Count }) -eq $promptCount) 'NoCompletionPrompt returns immediately without asking'

    # ---- view_image tool ---------------------------------------------------
    $viewImageOptions = @{ Model = 'custom-model'; ChatUri = 'https://provider.invalid/chat'; Quiet = $true; WorkingDirectory = $fixture; NoModelRecovery = $true; NoAgentsFile = $true }
    # Reuse the 1x1 PNG already created in the media fixture.
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall view_image '{"path":"media/image [1].PNG"}'))), (New-HarnessResponse 'image seen'))
    $viewResult = Invoke-AgentHarness 'Describe the image' @viewImageOptions -PassThru
    $viewToolMsg = @($viewResult.Messages | Where-Object role -eq tool)[0]
    $expectedImageUrl = 'data:image/png;base64,' + [Convert]::ToBase64String($imageBytes)
    Assert-Harness ($viewResult.Answer -eq 'image seen') 'view_image tool round trip completes'
    Assert-Harness ($viewToolMsg.content -is [string] -and $viewToolMsg.content -like '`[image: image*') 'view_image retains a descriptive placeholder in history'
    $viewRequest = @(Get-HarnessRequests)[-1]
    Assert-Harness ($viewRequest.Body.messages[-1].role -eq 'tool' -and $viewRequest.Body.messages[-1].content -is [array]) 'view_image multimodal content sent in subsequent request'
    Assert-Harness ($viewRequest.Body.messages[-1].content[0].text -like 'Image: image*' -and $viewRequest.Body.messages[-1].content[1].image_url.url -eq $expectedImageUrl) 'view_image injects the description and exact image bytes'

    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall view_image '{"path":"../outside.png"}'))), (New-HarnessResponse 'done'))
    $viewEscape = Invoke-AgentHarness 'Escape' @viewImageOptions -PassThru
    Assert-Harness (@($viewEscape.Messages | Where-Object role -eq tool)[0].content -like 'ERROR: Path escapes*') 'view_image rejects paths outside working directory'

    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall view_image '{"path":"report.pdf"}'))), (New-HarnessResponse 'done'))
    $viewBad = Invoke-AgentHarness 'Bad format' @viewImageOptions -PassThru
    Assert-Harness (@($viewBad.Messages | Where-Object role -eq tool)[0].content -like 'ERROR: Unsupported image format*') 'view_image rejects non-image extensions'

    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall view_image '{"path":"missing_file.png"}'))), (New-HarnessResponse 'done'))
    $viewMissing = Invoke-AgentHarness 'Missing' @viewImageOptions -PassThru
    Assert-Harness (@($viewMissing.Messages | Where-Object role -eq tool)[0].content -like 'ERROR: File not found*') 'view_image rejects missing files'

    # Custom tool returning ContentParts: verify the convention also works for user-defined tools.
    $customMultiTool = @{
        multi_out = @{
            Script = {
                param($a, $ctx)
                @{ ContentParts = @(@{ type = 'text'; text = 'custom text part' }, @{ type = 'image_url'; image_url = @{ url = 'data:image/png;base64,abc=' } }) }
            }
        }
    }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall multi_out '{}'))), (New-HarnessResponse 'custom multimodal done'))
    $customMultiResult = Invoke-AgentHarness 'Multi' @viewImageOptions -Tools $customMultiTool -NoBuiltinTools -PassThru
    $customToolMsg = @($customMultiResult.Messages | Where-Object role -eq tool)[0]
    $customReq = @(Get-HarnessRequests)[-1]
    Assert-Harness ($customToolMsg.content -is [string] -and $customToolMsg.content -like '`[image: custom text part*') 'Custom multimodal tool results keep placeholder in history/PassThru'
    Assert-Harness ($customReq.Body.messages[-1].role -eq 'tool' -and $customReq.Body.messages[-1].content -is [array] -and $customReq.Body.messages[-1].content[0].text -eq 'custom text part') 'Custom multimodal tool ContentParts are injected into request'

    Set-HarnessResponses @(
        (New-HarnessResponse '' @((New-HarnessCall multi_out '{}'))),
        (New-HarnessApiError 429),
        (New-HarnessResponse '' @((New-HarnessCall inspect '{}'))),
        (New-HarnessResponse 'media consumed')
    )
    $null = Invoke-AgentHarness 'Inspect custom media once' @viewImageOptions -Tools ($customMultiTool + $attachmentTool) -NoBuiltinTools
    $customRequests = @(Get-HarnessRequests)
    Assert-Harness ($customRequests.Count -eq 4 -and $customRequests[1].Body.messages[-1].content[1].image_url.url -ceq 'data:image/png;base64,abc=' -and (ConvertTo-Json -InputObject $customRequests[1].Body.messages -Depth 20 -Compress) -ceq (ConvertTo-Json -InputObject $customRequests[2].Body.messages -Depth 20 -Compress)) 'Tool media bytes survive retries of the receiving model turn'
    Assert-Harness ($customRequests[3].Body.messages[3].content -ceq '[image: custom text part]') 'Tool media becomes a placeholder after the receiving turn succeeds'

    . (Join-Path $PSScriptRoot 'AgentHarness.Shell.Tests.ps1')
    . (Join-Path $PSScriptRoot 'AgentHarness.Python.Tests.ps1')
    . (Join-Path $PSScriptRoot 'AgentHarness.Mcp.Tests.ps1')
    . (Join-Path $PSScriptRoot 'AgentHarness.Decisions.Tests.ps1')
    . (Join-Path $PSScriptRoot 'AgentHarness.PromptHistory.Tests.ps1')
    . (Join-Path $PSScriptRoot 'AgentHarness.Context.Tests.ps1')
    . (Join-Path $PSScriptRoot 'AgentHarness.AutoCompact.Tests.ps1')

    Write-Host "Passed $checks checks. No Initialize.ps1 access or live API requests."
}
finally {
    if ($module) { Remove-Module $module -Force }
    if (Test-Path -LiteralPath $fixture) {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixture).ProviderPath
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolvedFixture -Leaf) -notlike 'SpiHarnessTests-*') {
            throw "Refusing cleanup outside the test fixture: $resolvedFixture"
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
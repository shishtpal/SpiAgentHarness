# Runs inside the isolated harness fixture. No real model calls or screen actions.
$decisionKeyBefore = [Environment]::GetEnvironmentVariable('SPI_HARNESS_DECISION_TEST_KEY')
try {
    [IO.File]::WriteAllBytes((Join-Path $fixture 'decision-image.png'), [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))
    [Environment]::SetEnvironmentVariable('SPI_HARNESS_DECISION_TEST_KEY', 'synthetic-decision-key')
    $screenPackage = Get-Content -LiteralPath (Join-Path $fixture 'Config/decide_screen_target.json') -Raw | ConvertFrom-Json -AsHashtable
    $generalPackage = Get-Content -LiteralPath (Join-Path $fixture 'Config/decision.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($package in $screenPackage, $generalPackage) {
        foreach ($profile in $package.config.profiles.Values) { $profile.key_env_var = 'SPI_HARNESS_DECISION_TEST_KEY' }
    }
    & $module {
        $script:DecisionRequests = [Collections.Generic.List[object]]::new()
        $script:DecisionAnswerMode = 'selected'
        function script:Invoke-DecisionModelRequest {
            param($Uri, $ApiKey, $Json, $TimeoutSec, $MaxRetries, $Log)
            $body = ConvertFrom-Json -InputObject $Json -AsHashtable
            $script:DecisionRequests.Add(@{ Uri = $Uri; Body = $body; Timeout = $TimeoutSec; Retries = $MaxRetries })
            if ($script:DecisionAnswerMode -eq 'failure') { throw 'Synthetic decision transport failure.' }
            if ($Uri -like '*/systemone') {
                return @{ model = 'clef-test'; usage = @{}; answers = @{ target = @{ type = 'choice'; choice = 'settings'; probabilities = @{ settings = 0.95; profile = 0.03; none = 0.02 } } } }
            }
            $name = $body.questions[0].name
            $answer = @{ type = 'choice'; name = $name; choice = 'settings'; probabilities = @(@{ value = 'settings'; probability = 0.95 }, @{ value = 'profile'; probability = 0.03 }, @{ value = 'none'; probability = 0.02 }) }
            switch ($script:DecisionAnswerMode) {
                'refused' { $answer = @{ type = 'refusal'; name = $name } }
                'missing' { $answer.Remove('probabilities') }
                'low' { $answer.probabilities = @(@{ value = 'settings'; probability = 0.5 }, @{ value = 'profile'; probability = 0.4 }, @{ value = 'none'; probability = 0.1 }) }
                'none' { $answer.choice = 'none'; $answer.probabilities = @(@{ value = 'settings'; probability = 0.01 }, @{ value = 'profile'; probability = 0.01 }, @{ value = 'none'; probability = 0.98 }) }
                'unknown' { $answer.choice = 'made_up' }
            }
            @{ model = 'luna-test'; id = 'decision-test'; usage = @{ input_tokens = 3 }; answers = @($answer) }
        }
    }
    $decisionOptions = @{ Model = 'custom-model'; ChatUri = 'https://provider.invalid/chat'; Quiet = $true; WorkingDirectory = $fixture; NoModelRecovery = $true; NoAgentsFile = $true; NoSubAgents = $true }
    $screenArguments = @{
        goal       = 'Open settings'
        snapshot   = @{ id = 'screen-42'; source = 'synthetic-window'; captured_at = [DateTimeOffset]::UtcNow.ToString('o'); coordinate_space = 'browser_css_pixels'; width = 1000; height = 800 }
        candidates = @(
            @{ id = 'settings'; description = 'Settings button'; bounds = @{ x = 900; y = 20; width = 40; height = 40 } },
            @{ id = 'profile'; description = 'Profile button'; locator = 'observed-profile' }
        )
    }
    function Invoke-ScreenTest {
        param([object]$Arguments = $screenArguments, [object]$Package = $screenPackage, [int]$OutputLimit = 8000)
        Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall decide_screen_target (ConvertTo-Json -InputObject $Arguments -Depth 30 -Compress)))), (New-HarnessResponse 'decision used'))
        $run = Invoke-AgentHarness 'Select a target' @decisionOptions -DecisionConfig $Package -PassThru -MaxToolOutputChars $OutputLimit
        @($run.Messages | Where-Object role -eq tool)[0].content
    }
    $selectedText = Invoke-ScreenTest
    if ($selectedText -like 'ERROR:*') { throw $selectedText }
    $selected = $selectedText | ConvertFrom-Json
    Assert-Harness ($selected.status -ceq 'selected' -and $selected.target.id -ceq 'settings' -and $selected.target.bounds.x -eq 900) 'Screen decision maps the chosen ID back to observed bounds'
    Assert-Harness ($selected.requires_target_revalidation -and $selected.coordinate_space -ceq 'browser_css_pixels') 'Selection retains source and coordinate metadata for executor revalidation'
    $recorded = & $module { $script:DecisionRequests[0] }
    Assert-Harness ($recorded.Retries -eq 0 -and $recorded.Timeout -eq 30 -and $recorded.Body.questions[0].choices.Count -eq 3) 'Shared request service applies config and adds abstention choice'
    Assert-Harness ((Get-HarnessRequests)[0].Body.tools.function.name -contains 'decide_screen_target') 'Configured tool schema is advertised to the chat model'

    foreach ($mode in 'refused', 'missing', 'low', 'none', 'unknown', 'failure') {
        & $module { param($value) $script:DecisionAnswerMode = $value } $mode
        $output = Invoke-ScreenTest
        if ($mode -in 'unknown', 'failure') { Assert-Harness ($output -like 'ERROR:*') "Invalid/failed decisions return tool errors: $mode" }
        else {
            $decision = $output | ConvertFrom-Json
            $expectedStatus = if ($mode -eq 'refused') { 'refused' } else { 'abstained' }
            Assert-Harness ($decision.status -ceq $expectedStatus -and $null -eq $decision.target) "Non-selection preserves status without coordinates: $mode"
        }
    }
    & $module { $script:DecisionAnswerMode = 'selected' }
    $stale = $screenArguments | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    $stale.snapshot.captured_at = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
    $before = & $module { $script:DecisionRequests.Count }
    $staleResult = Invoke-ScreenTest $stale | ConvertFrom-Json
    Assert-Harness ($staleResult.status -ceq 'stale_snapshot' -and (& $module { $script:DecisionRequests.Count }) -eq $before) 'Expired observations abstain before inference'

    foreach ($invalidCase in 'duplicate', 'bounds', 'extra', 'array', 'empty', 'null') {
        $bad = $screenArguments | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        switch ($invalidCase) {
            duplicate { $bad.candidates[1].id = 'settings' }
            bounds { $bad.candidates[0].bounds.width = 500 }
            extra { $bad.endpoint = 'https://untrusted.invalid' }
            array { $bad = @($bad) }
            empty { $bad = @() }
            null { $bad = $null }
        }
        $before = & $module { $script:DecisionRequests.Count }
        Assert-Harness ((Invoke-ScreenTest -Arguments $bad) -like 'ERROR:*') "Invalid screen arguments are rejected: $invalidCase"
        Assert-Harness ((& $module { $script:DecisionRequests.Count }) -eq $before) 'Invalid screen arguments never invoke a model'
    }
    Assert-Harness ((Invoke-ScreenTest -OutputLimit 50) -like 'ERROR: Decision result exceeds*') 'Decision results cannot be silently truncated'

    $textPackage = $screenPackage | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $textPackage.config.active_profile = 'clef'
    $textResult = Invoke-ScreenTest -Package $textPackage | ConvertFrom-Json
    Assert-Harness ($textResult.status -ceq 'selected' -and $textResult.model -ceq 'clef-test') 'Same screen handler works through the text-only Clef adapter'
    $imageArgs = $screenArguments | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    $imageArgs.snapshot.screenshot_path = 'decision-image.png'
    Assert-Harness ((Invoke-ScreenTest -Arguments $imageArgs -Package $textPackage) -like 'ERROR:*does not accept image*') 'Clef screenshot input is rejected rather than discarded'
    $imageResult = Invoke-ScreenTest -Arguments $imageArgs | ConvertFrom-Json
    Assert-Harness ($imageResult.status -ceq 'selected') 'Luna accepts local image handoff'
    Assert-Harness ((& $module { $script:DecisionRequests[-1].Body.input[0].content[1].type }) -ceq 'input_image') 'Image handoff reaches the shared native adapter'

    # A new handler reuses the service without editing the tool registry or transport.
    $customPackage = $generalPackage | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $customPackage.handler = 'route_request'
    $customPackage.tool.function.name = 'route_request'
    $customHandlers = @{
        route_request = {
            param($a, $ctx, $definition)
            $response = & $ctx.DecisionState.Invoke $definition $a.state $a.questions @() $ctx.Root
            @{ chosen = $response.Answers.route.choice; model = $response.Model }
        }
    }
    $generalArgs = @{ state = @{ text = 'Evidence'; flags = @(); absent = $null }; questions = @{ route = @{ type = 'choice'; instructions = 'Route'; criteria = @{ settings = 'Settings'; profile = 'Profile'; none = 'Neither' } } } }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall route_request (ConvertTo-Json -InputObject $generalArgs -Depth 30 -Compress)))), (New-HarnessResponse 'routed'))
    $customRun = Invoke-AgentHarness 'Route' @decisionOptions -DecisionConfig $screenPackage, $generalPackage, $customPackage -DecisionToolHandlers $customHandlers -PassThru
    $customResult = @($customRun.Messages | Where-Object role -eq tool)[0].content | ConvertFrom-Json
    Assert-Harness ($customResult.chosen -ceq 'settings') 'Additional decision tools reuse the shared service through registered host handlers'
    $advertised = (Get-HarnessRequests)[0].Body.tools.function.name
    Assert-Harness ($advertised -contains 'decision' -and $advertised -contains 'decide_screen_target' -and $advertised -contains 'route_request') 'Multiple configured tools coexist'

    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall decision (ConvertTo-Json -InputObject $generalArgs -Depth 30 -Compress)))), (New-HarnessResponse 'answered'))
    $generalRun = Invoke-AgentHarness 'Evaluate' @decisionOptions -DecisionConfig $generalPackage -PassThru
    $generalResult = @($generalRun.Messages | Where-Object role -eq tool)[0].content | ConvertFrom-Json
    Assert-Harness ($generalResult.Answers.route.choice -ceq 'settings' -and -not $generalResult.PSObject.Properties['RawResponse']) 'General decision tool returns normalized answers without raw provider data'

    $jsonConfigPath = Join-Path $fixture 'Config/runtime-screen.json'
    [IO.File]::WriteAllText($jsonConfigPath, (ConvertTo-Json -InputObject $screenPackage -Depth 100))
    Set-HarnessResponses @((New-HarnessResponse 'configured'))
    $null = Invoke-AgentHarness 'Load JSON' @decisionOptions -DecisionConfigPath 'Config/runtime-screen.json'
    Assert-Harness ((Get-HarnessRequests)[0].Body.tools.function.name -contains 'decide_screen_target') 'JSON tool/config package loads relative to WorkingDirectory'
    Assert-HarnessThrows { Invoke-AgentHarness x @decisionOptions -DecisionConfig $screenPackage -DecisionConfigPath $jsonConfigPath } '*either DecisionConfig*'
    Assert-HarnessThrows { Invoke-AgentHarness x @decisionOptions -DecisionConfig $screenPackage -NoBuiltinTools } '*NoBuiltinTools*'
    Assert-HarnessThrows { Invoke-AgentHarness x @decisionOptions -DecisionConfig $screenPackage, $screenPackage } '*unique*'
    Assert-HarnessThrows { Invoke-AgentHarness x @decisionOptions -DecisionConfig $customPackage } '*Unknown decision tool handler*'
    $badConfig = $screenPackage | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $badConfig.config.profiles.luna.endpoint = 'http://invalid.example/decisions'
    Assert-HarnessThrows { Invoke-AgentHarness x @decisionOptions -DecisionConfig $badConfig } '*HTTPS*'
    foreach ($preference in 'Continue', 'Stop') {
        $ErrorActionPreference = $preference
        & $module { $script:DecisionAnswerMode = 'failure' }
        Assert-Harness ((Invoke-ScreenTest) -like 'ERROR:*') "Decision failures become tool errors under $preference"
    }
    $ErrorActionPreference = 'Stop'
}
finally {
    [Environment]::SetEnvironmentVariable('SPI_HARNESS_DECISION_TEST_KEY', $decisionKeyBefore)
}
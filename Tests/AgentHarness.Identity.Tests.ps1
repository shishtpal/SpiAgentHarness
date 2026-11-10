# Dot-sourced after HTTP mocks are installed in the isolated harness fixture.
$identityOptions = $basic.Clone()
$identityOptions.NoPromptHistory = $true
$identityOptions.NoAgentsFile = $true
$identityOptions.ApiKey = 'synthetic-identity-test-key'
$identityPreference = $ErrorActionPreference
try {
    foreach ($preference in 'Continue', 'Stop') {
        $ErrorActionPreference = $preference
        foreach ($preset in @(
            @{ Name = 'Codex'; Title = 'Codex'; Referer = 'https://openai.com/codex/' },
            @{ Name = 'ClaudeCode'; Title = 'Claude Code'; Referer = 'https://claude.ai/code' },
            @{ Name = 'OpenCode'; Title = 'opencode'; Referer = 'https://opencode.ai/' },
            @{ Name = 'Kilo'; Title = 'Kilo Code'; Referer = 'https://kilo.ai/' },
            @{ Name = 'Cline'; Title = 'Cline'; Referer = 'https://cline.bot' }
        )) {
            Set-HarnessResponses @((New-HarnessResponse 'identity accepted'))
            $answer = Invoke-AgentHarness 'Synthetic identity request' @identityOptions -PretendAgent $preset.Name
            $request = @(Get-HarnessRequests)[0]
            Assert-Harness ($answer -eq 'identity accepted' -and $request.Headers['HTTP-Referer'] -ceq $preset.Referer -and $request.Headers['X-Title'] -ceq $preset.Title -and $request.Headers['X-OpenRouter-Title'] -ceq $preset.Title) "$($preset.Name) attribution reaches chat under $preference"
            Assert-Harness ($request.Headers.Authorization -ceq 'Bearer synthetic-identity-test-key' -and $request.Body.model -ceq 'custom-model' -and $request.Body.messages[1].content -ceq 'Synthetic identity request' -and $null -eq $request.Body.PretendAgent) 'Attribution preserves authentication, model and prompt without adding body fields'
        }

        Set-HarnessResponses @((New-HarnessResponse))
        $null = Invoke-AgentHarness 'Default identity' @identityOptions
        $request = @(Get-HarnessRequests)[0]
        Assert-Harness ($request.Headers.Count -eq 1 -and $request.Headers.ContainsKey('Authorization')) "Default requests have no attribution and do not retain a previous choice under $preference"
        Set-HarnessResponses @()
        Assert-HarnessThrows { Invoke-AgentHarness 'Invalid identity' @identityOptions -PretendAgent Unknown } '*ValidateSet*'
        Assert-Harness (@(Get-HarnessRequests).Count -eq 0) 'Invalid identities fail before HTTP requests'
    }

    # Exercise request retries and a tool turn using the public parameter.
    $identityTools = @{ identity_context = @{ Script = { param($a, $ctx) $ctx.SubAgentOptions.PretendAgent } } }
    Set-HarnessResponses @(
        (New-HarnessApiError 500),
        (New-HarnessResponse '' @((New-HarnessCall identity_context))),
        (New-HarnessResponse 'identity round trip')
    )
    $roundTrip = Invoke-AgentHarness 'Synthetic tool request' @identityOptions -PretendAgent OpenCode -Tools $identityTools -PassThru
    $requests = @(Get-HarnessRequests)
    Assert-Harness ($requests.Count -eq 3 -and @($requests | Where-Object { $_.Headers['X-Title'] -cne 'opencode' -or $_.Headers['HTTP-Referer'] -cne 'https://opencode.ai/' }).Count -eq 0) 'Identity persists through retry and tool turns'
    Assert-Harness ($roundTrip.Messages[3].content -ceq 'OpenCode') 'Public choice is included in child invocation options'

    $summary = @{ goal = 'Synthetic task'; constraints = 'Fixture only'; decisions = 'None recorded'; completed_work = 'Answered'; verification = 'Mock only'; unfinished_work = 'None recorded'; next_steps = 'None recorded' } | ConvertTo-Json -Compress
    Set-HarnessResponses @((New-HarnessResponse 'identity final'), (New-HarnessResponse $summary))
    $null = Invoke-AgentHarness 'Synthetic summary' @identityOptions -PretendAgent ClaudeCode -SaveContextPath identity-summary.json -ContextMode Summary
    $requests = @(Get-HarnessRequests)
    Assert-Harness ($requests.Count -eq 2 -and $requests[1].Headers['X-Title'] -ceq 'Claude Code' -and $null -eq $requests[1].Body.tools) 'Tool-free context summaries inherit attribution'
    $savedIdentityContext = Get-Content -LiteralPath (Join-Path $fixture 'identity-summary.json') -Raw | ConvertFrom-Json
    Assert-Harness ($null -eq $savedIdentityContext.PretendAgent -and $null -eq $savedIdentityContext.ChatHeaders) 'Saved context does not persist identity overrides'
    Set-HarnessResponses @((New-HarnessResponse 'fresh identity'))
    $null = Invoke-AgentHarness 'Resume' @identityOptions -ContextPath identity-summary.json
    Assert-Harness (@(Get-HarnessRequests)[0].Headers.Count -eq 1) 'Resumed context requires explicit identity opt-in again'

    $line = 'Invoke-AgentHarness -PretendAgent '
    $completions = (TabExpansion2 $line $line.Length).CompletionMatches.CompletionText
    Assert-Harness ($completions -contains 'Codex' -and $completions -contains 'ClaudeCode' -and $completions -contains 'OpenCode' -and $completions -contains 'Kilo' -and $completions -contains 'Cline') 'Identity presets tab-complete'
}
finally { $ErrorActionPreference = $identityPreference }
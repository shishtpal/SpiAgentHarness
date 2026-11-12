# Synthetic instructions, offline bundled profiles and mocked requests only.
$profileRoot = Join-Path $fixture 'profile-fixture'
$null = New-Item -ItemType Directory -Path $profileRoot
[IO.File]::WriteAllText((Join-Path $profileRoot 'AGENTS.md'), 'Synthetic profile repository rule.')
$profileOptions = $basic.Clone()
$profileOptions.WorkingDirectory = $profileRoot
$profileOptions.NoPromptHistory = $true
$profileOptions.NoPromptSound = $true
$profileBaseline = & $module { Get-AgentHarnessSystemPrompt -NoAgentsFile }
$profileNames = @('Codex', 'ClaudeCode', 'OpenCode', 'Kilo', 'Cline')
$profilePreference = $ErrorActionPreference
$profileReader = & $module { ${function:Read-AgentHarnessNextPrompt} }
try {
    foreach ($preference in 'Continue', 'Stop') {
        $ErrorActionPreference = $preference
        foreach ($profileName in $profileNames) {
            Set-HarnessResponses @((New-HarnessResponse 'profile answer'))
            $profileResult = Invoke-AgentHarness 'Synthetic profile task' @profileOptions -AgentProfile $profileName -Instructions 'Synthetic user rule.' -PassThru
            $profileRequest = @(Get-HarnessRequests)[0]
            $profileText = $profileRequest.Body.messages[0].content
            $marker = "Adapted agent behavior profile: $profileName"
            $expectedPersona = if ($profileName -eq 'ClaudeCode') { 'Claude Code' } else { $profileName }
            Assert-Harness ($profileResult.Answer -eq 'profile answer' -and $profileText.StartsWith("You are $expectedPersona,") -and $profileText.Contains($marker) -and $profileResult.PersonaName -ceq $expectedPersona) "$profileName reaches the request and names the persona under $preference"
            Assert-Harness ($profileText.IndexOf($marker) -lt $profileText.IndexOf('Synthetic profile repository rule.') -and $profileText.EndsWith('Synthetic user rule.')) 'Profile precedes repository and additional user instructions'
            Assert-Harness ($profileText.Contains('Each launch starts a separate -NoProfile, -NonInteractive process') -and $profileText.Contains('start_powershell') -and $profileText.Contains('not assume upstream tools') -and $profileText.Contains('take precedence over profile guidance')) 'Profile keeps actual execution semantics and instruction priority'
            Assert-Harness (-not $profileRequest.Headers.ContainsKey('HTTP-Referer') -and $profileRequest.Body.model -eq 'custom-model') 'Behavior selection does not change attribution or model routing'
        }
        Set-HarnessResponses @((New-HarnessResponse))
        $null = Invoke-AgentHarness 'Default profile' @profileOptions -NoAgentsFile -AgentProfile Default
        Assert-Harness (@(Get-HarnessRequests)[0].Body.messages[0].content -ceq $profileBaseline) 'Explicit Default preserves the original system prompt exactly'
        foreach ($invalidProfile in 'Unknown', '../Codex') {
            Set-HarnessResponses @()
            Assert-HarnessThrows { Invoke-AgentHarness 'Invalid profile' @profileOptions -AgentProfile $invalidProfile } '*ValidateSet*'
            Assert-Harness (@(Get-HarnessRequests).Count -eq 0) 'Invalid profile names fail before HTTP requests'
        }
    }

    Set-HarnessResponses @((New-HarnessResponse))
    $profileHistory = Invoke-AgentHarness 'Separate selections' @profileOptions -AgentProfile Codex -PretendAgent Kilo -PassThru
    $profileRequest = @(Get-HarnessRequests)[0]
    Assert-Harness ($profileRequest.Headers['X-Title'] -ceq 'Kilo Code' -and $profileRequest.Body.messages[0].content.Contains('Adapted agent behavior profile: Codex')) 'Attribution and behavior can be selected independently'
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'Attribution only' @profileOptions -NoAgentsFile -PretendAgent Cline
    $profileAttributionText = @(Get-HarnessRequests)[0].Body.messages[0].content
    Assert-Harness ($profileAttributionText.StartsWith('You are Cline,') -and -not $profileAttributionText.Contains('Adapted agent behavior profile:')) 'Attribution supplies the fallback persona without silently activating a behavior profile'
    Assert-Harness ($profileHistory.PersonaName -ceq 'Codex') 'Behavior profile takes precedence over a different attribution name'
    Set-HarnessResponses @((New-HarnessResponse))
    $profileLowercase = Invoke-AgentHarness 'Case insensitive profile' @profileOptions -AgentProfile cline -PassThru
    Assert-Harness ($profileLowercase.PersonaName -ceq 'Cline' -and $profileLowercase.Messages[0].content.Contains('Adapted agent behavior profile: Cline')) 'Case-insensitive selection resolves canonical asset and persona names'

    foreach ($personaCase in @(
        @{ Profile = 'Default'; Pretend = $null; Name = 'SpiAgentHarness' },
        @{ Profile = 'Default'; Pretend = 'Kilo'; Name = 'Kilo' },
        @{ Profile = 'OpenCode'; Pretend = 'Cline'; Name = 'OpenCode' }
    )) {
        $personaOptions = $profileOptions.Clone(); $personaOptions.Quiet = $false
        if ($personaCase.Pretend) { $personaOptions.PretendAgent = $personaCase.Pretend }
        Set-HarnessResponses @((New-HarnessResponse 'named answer'))
        $personaTrace = @()
        $personaResult = Invoke-AgentHarness 'Persona trace' @personaOptions -AgentProfile $personaCase.Profile -PassThru -InformationVariable personaTrace 6>$null
        Assert-Harness ($personaResult.PersonaName -ceq $personaCase.Name -and $personaResult.Messages[0].content.StartsWith("You are $($personaCase.Name),")) 'Persona name follows the selected precedence in prompt and metadata'
        Assert-Harness (($personaTrace.MessageData -join "`n").Contains("== $($personaCase.Name) ==")) 'Session banner uses the effective persona name'
    }

    # Exercise the refresh path used after tools update skill instructions.
    $profileTools = @{ profile_refresh = @{ Script = {
        param($a, $ctx)
        $ctx.SkillPromptDirty = $true
        $ctx.SubAgentOptions.AgentProfile
    } } }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall profile_refresh))), (New-HarnessResponse 'refreshed'))
    $profileRoundTrip = Invoke-AgentHarness 'Refresh profile prompt' @profileOptions -AgentProfile OpenCode -Tools $profileTools -PassThru
    $profileRequests = @(Get-HarnessRequests)
    Assert-Harness ($profileRequests.Count -eq 2 -and $profileRequests[1].Body.messages[0].content.Contains('Adapted agent behavior profile: OpenCode')) 'Tool-triggered prompt refresh retains the profile'
    Assert-Harness ($profileRoundTrip.Messages[3].content -ceq 'OpenCode') 'Public profile is included in child invocation options'

    & $module {
        $script:ProfileReplies = [Collections.Generic.Queue[string]]::new()
        $script:ProfileReplies.Enqueue('Synthetic next task')
        $script:ProfileReplies.Enqueue('')
        function script:Read-AgentHarnessNextPrompt {
            param($Answer, $NoPromptSound, $SkipAnswer, $Context)
            $script:ProfileReplies.Dequeue()
        }
    }
    $profileContinuedOptions = $profileOptions.Clone(); $profileContinuedOptions.NoCompletionPrompt = $false
    Set-HarnessResponses @((New-HarnessResponse 'first answer'), (New-HarnessResponse 'second answer'))
    $profileContinued = Invoke-AgentHarness 'First task' @profileContinuedOptions -AgentProfile Kilo -PassThru
    $profileRequests = @(Get-HarnessRequests)
    Assert-Harness ($profileContinued.Answer -eq 'second answer' -and $profileRequests.Count -eq 2 -and $profileRequests[1].Body.messages[0].content.Contains('Adapted agent behavior profile: Kilo')) 'Continuations retain the selected profile'

    Set-HarnessResponses @((New-HarnessResponse))
    $profileReplaced = Invoke-AgentHarness 'Switch working style' @profileOptions -History $profileHistory.Messages -AgentProfile Cline -PassThru
    Assert-Harness ($profileReplaced.Messages[0].content.Contains('Adapted agent behavior profile: Cline') -and -not $profileReplaced.Messages[0].content.Contains('Adapted agent behavior profile: Codex') -and @($profileReplaced.Messages | Where-Object role -eq system).Count -eq 1) 'History rebuilds exactly one system prompt with the current profile'
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'Save profile conversation' @profileOptions -AgentProfile ClaudeCode -SaveContextPath profile.json
    Set-HarnessResponses @((New-HarnessResponse))
    $profileResumed = Invoke-AgentHarness 'Resume default' @profileOptions -ContextPath profile.json -NoAgentsFile -PassThru
    Assert-Harness ($profileResumed.Messages[0].content -ceq $profileBaseline) 'Saved context does not reactivate the old behavior profile'

    $profilePath = Join-Path $fixture 'Private/AgentHarness/Profiles/Codex.md'
    $profileBytes = [IO.File]::ReadAllBytes($profilePath)
    try {
        [IO.File]::Delete($profilePath)
        Set-HarnessResponses @()
        Assert-HarnessThrows { Invoke-AgentHarness 'Missing asset' @profileOptions -AgentProfile Codex } '*'
        Assert-Harness (@(Get-HarnessRequests).Count -eq 0) 'A missing bundled profile fails before any provider request'
        [IO.File]::WriteAllText($profilePath, ' ')
        Assert-HarnessThrows { Invoke-AgentHarness 'Empty asset' @profileOptions -AgentProfile Codex } '*Agent profile is empty*'
    }
    finally { [IO.File]::WriteAllBytes($profilePath, $profileBytes) }

    $profileCompletionLine = 'Invoke-AgentHarness -AgentProfile '
    $profileCompletions = (TabExpansion2 $profileCompletionLine $profileCompletionLine.Length).CompletionMatches.CompletionText
    foreach ($profileName in @('Default') + $profileNames) {
        Assert-Harness ($profileCompletions -contains $profileName) "$profileName behavior profile tab-completes"
    }
}
finally {
    $ErrorActionPreference = $profilePreference
    & $module { param($reader) Set-Item Function:script:Read-AgentHarnessNextPrompt -Value $reader } $profileReader
}
# Included by Invoke-AgentHarness.Tests.ps1; synthetic files and mocked providers only.
$contextRoot = Join-Path $fixture 'context-fixture'
$null = New-Item -ItemType Directory -Path $contextRoot
$contextOptions = $basic.Clone()
$contextOptions.WorkingDirectory = $contextRoot
$contextOptions.NoPromptHistory = $true
$contextOptions.NoPromptSound = $true
$contextOptions.NoCompletionPrompt = $true
$contextOptions.NoAgentsFile = $true
$contextOptions.NoSubAgents = $true
$contextTools = @{
    context_echo = @{ Script = { param($a, $ctx) 'synthetic tool evidence' } }
}
$savedContextHost = & $module { ${function:Read-Host} }
function Read-ContextFixture {
    param([string]$Name)
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $contextRoot $Name))) -AsHashtable -NoEnumerate
}
function Write-ContextFixture {
    param([string]$Name, $Value)
    [IO.File]::WriteAllText((Join-Path $contextRoot $Name), (ConvertTo-Json -InputObject $Value -Depth 30), [Text.UTF8Encoding]::new($false))
}
try {
    & $module {
        $script:ContextReplies = [Collections.Generic.Queue[object]]::new()
        function script:Read-Host {
            param($Prompt)
            if (-not $script:ContextReplies.Count) { throw 'Unexpected context prompt.' }
            $script:ContextReplies.Dequeue()
        }
    }
    # No context checkpoint is written without an explicit save request.
    Set-HarnessResponses @((New-HarnessResponse 'unsaved answer'))
    $unsaved = Invoke-AgentHarness 'unsaved task' @contextOptions -PassThru
    Assert-Harness ($null -eq $unsaved.ContextPath -and @(Get-ChildItem -LiteralPath $contextRoot -Force).Count -eq 0) 'Context persistence is explicit only'
    $directPath = & $module {
        param($root)
        Write-AgentHarnessContext -Path direct.json -Mode Raw -Messages @(@{ role = 'user'; content = 'Synthetic task' }, @{ role = 'assistant'; content = 'Synthetic answer' }) `
            -Context @{ Root = $root; ContextSessionId = 'synthetic-session' } -Provider custom -Model synthetic
    } $contextRoot
    Assert-Harness ((Read-ContextFixture direct.json).messages.Count -eq 2 -and $directPath -eq (Join-Path $contextRoot 'direct.json')) 'Context writer supports a minimal completed transcript'
    $dateRoundTrip = & $module {
        param($root)
        $null = Write-AgentHarnessContext -Path date.json -Mode Raw -Messages @(@{ role = 'user'; content = @(@{ type = 'text'; text = '2026-11-09T00:00:00Z' }) }, @{ role = 'assistant'; content = '2026-11-09T01:00:00Z' }) `
            -Context @{ Root = $root; ContextSessionId = 'synthetic-session' } -Provider custom -Model synthetic
        Read-AgentHarnessContext -Root $root -Path date.json
    } $contextRoot
    Assert-Harness ($dateRoundTrip.messages[0].content -is [array] -and $dateRoundTrip.messages[0].content[0].text -is [string] -and $dateRoundTrip.messages[0].content[0].text -ceq '2026-11-09T00:00:00Z' -and $dateRoundTrip.messages[1].content -is [string] -and $dateRoundTrip.createdAt -is [string]) 'Context JSON preserves ISO-looking text and singleton content arrays without date coercion'

    # Raw captures completed tool interactions and inline media without configuration.
    [IO.File]::WriteAllText((Join-Path $contextRoot 'attachment.txt'), 'Synthetic attachment नमस्ते')
    $contentHistory = @(@{ role = 'user'; content = @(@{ type = 'text'; text = 'Historic media' }, @{ type = 'image_url'; image_url = @{ url = 'data:image/png;base64,AA==' } }, @{ type = 'file'; file = @{ filename = 'synthetic.pdf'; file_data = 'data:application/pdf;base64,AA==' } }) })
    Set-HarnessResponses @(
        (New-HarnessResponse '' @((New-HarnessCall context_echo '{"items":[]}' 'context_call'))),
        (New-HarnessResponse 'first answer')
    )
    $raw = Invoke-AgentHarness 'Read @attach("attachment.txt")' @contextOptions -History $contentHistory -Tools $contextTools `
        -ApiKey 'synthetic-context-connection-key' -Instructions 'Old additional instructions.' -SaveContextPath 'raw.json' -PassThru
    $rawFile = Read-ContextFixture raw.json
    Assert-Harness ($rawFile.version -eq 1 -and $rawFile.mode -ceq 'raw' -and $rawFile.messages.Count -eq 6 -and $raw.ContextPath -eq (Join-Path $contextRoot 'raw.json')) 'Explicit raw save records a versioned completed transcript'
    Assert-Harness ($rawFile.messages[1].content -is [array] -and $rawFile.messages[1].content[1].image_url.url -ceq 'data:image/png;base64,AA==' -and $rawFile.messages[1].content[2].file.filename -ceq 'synthetic.pdf') 'Raw file retains original media parts'
    Assert-Harness ($rawFile.messages[3].tool_calls -is [array] -and $null -eq $rawFile.messages[3].content -and $rawFile.messages[3].tool_calls[0].function.arguments -ceq '{"items":[]}' -and $rawFile.messages[4].tool_call_id -ceq 'context_call') 'Raw file preserves null content, singleton tool arrays, JSON argument strings and paired IDs'
    Assert-Harness (-not ([IO.File]::ReadAllText($raw.ContextPath)).Contains('synthetic-context-connection-key') -and -not $rawFile.Contains('ApiKey') -and -not $rawFile.Contains('YOLO')) 'Context excludes connection credentials and runtime authority'
    Assert-Harness ([IO.File]::ReadAllBytes($raw.ContextPath)[0] -eq 123 -and @(Get-ChildItem -LiteralPath $contextRoot -Filter '.context-*.tmp').Count -eq 0) 'Context writes UTF-8 without BOM and leaves no temporary file'

    # A load rebuilds system instructions and does not execute historical tools.
    $resumeOptions = $contextOptions.Clone(); $resumeOptions.Remove('Model')
    [IO.File]::WriteAllText((Join-Path $contextRoot 'AGENTS.md'), 'Current synthetic repository instructions.')
    $resumeOptions.NoAgentsFile = $false
    Set-HarnessResponses @((New-HarnessResponse 'resumed answer'))
    $resumed = Invoke-AgentHarness 'Continue the unfinished work' @resumeOptions -ContextPath raw.json -Instructions 'New additional instructions.' -PassThru
    $resumeRequest = @(Get-HarnessRequests)[0]
    Assert-Harness ($resumeRequest.Body.model -ceq 'custom-model' -and $resumed.Provider -ceq 'custom' -and @(Get-HarnessRequests).Count -eq 1) 'Saved provider/model hints support a fresh invocation with no tool replay'
    Assert-Harness ($resumed.Messages[0].content.Contains('Current synthetic repository instructions.') -and $resumed.Messages[0].content.EndsWith('New additional instructions.') -and -not $resumed.Messages[0].content.Contains('Old additional instructions.')) 'Loaded system instructions are rebuilt from current options and files'
    Assert-Harness ($resumeRequest.Body.messages[3].tool_calls[0].id -ceq 'context_call' -and $resumeRequest.Body.messages[4].content -ceq 'synthetic tool evidence') 'Loaded completed tool history reaches the provider as data'
    [IO.File]::Delete((Join-Path $contextRoot 'attachment.txt'))
    $relocatedRoot = Join-Path $contextRoot 'new-working-directory'
    $null = New-Item -ItemType Directory -Path $relocatedRoot
    $relocatedOptions = $contextOptions.Clone(); $relocatedOptions.WorkingDirectory = $relocatedRoot
    Set-HarnessResponses @((New-HarnessResponse 'relocated answer'))
    $relocated = Invoke-AgentHarness 'Continue elsewhere' @relocatedOptions -ContextPath $raw.ContextPath -PassThru
    Assert-Harness ($relocated.Messages[2].content[1].text.Contains('Synthetic attachment नमस्ते') -and -not (Test-Path -LiteralPath (Join-Path $relocatedRoot 'attachment.txt')) -and -not (Test-Path -LiteralPath (Join-Path $relocatedRoot '.agents'))) 'Context loads from another working directory without rereading original attachments or restoring saved journal settings'
    Set-HarnessResponses @((New-HarnessResponse 'override answer'))
    $override = Invoke-AgentHarness 'Override selection' @contextOptions -Provider TestB -ContextPath raw.json -PassThru
    Assert-Harness ($override.Provider -ceq 'TestB' -and $override.Model -ceq 'custom-model') 'Explicit provider/model selections override saved hints'
    Set-HarnessResponses @((New-HarnessResponse 'fresh provider model'))
    $freshProvider = Invoke-AgentHarness 'New provider only' @resumeOptions -Provider TestB -ContextPath raw.json -PassThru
    Assert-Harness ($freshProvider.Provider -ceq 'TestB' -and $freshProvider.Model -ceq 'third:free') 'Changing only the provider discovers a compatible model instead of reusing the saved hint'

    # Live commands save repeatedly without reaching the model or modifying active history.
    $interactiveOptions = $contextOptions.Clone(); $interactiveOptions.NoCompletionPrompt = $false
    & $module {
        $script:ContextReplies.Enqueue('second task')
        $script:ContextReplies.Enqueue('/save-context raw "continued raw.json"')
        $script:ContextReplies.Enqueue('/save-context pruned continued.pruned.json')
        $script:ContextReplies.Enqueue('/save-context raw')
        $script:ContextReplies.Enqueue('exit')
    }
    Set-HarnessResponses @(
        (New-HarnessResponse 'first commentary' @((New-HarnessCall context_echo '{}' 'batch_call'))),
        (New-HarnessResponse 'first completed'),
        (New-HarnessResponse 'second completed')
    )
    $continued = Invoke-AgentHarness 'first task' @interactiveOptions -Tools $contextTools -PassThru 6>$null
    $continuedRaw = Read-ContextFixture 'continued raw.json'
    $continuedPruned = Read-ContextFixture continued.pruned.json
    Assert-Harness ($continued.Answer -ceq 'second completed' -and @(Get-HarnessRequests).Count -eq 3 -and $continued.Iterations -eq 3) 'Save and invalid save commands reprompt without sending a task to the model'
    Assert-Harness (($continuedRaw.messages.role -join ',') -ceq 'system,user,assistant,tool,assistant,user,assistant' -and $continuedRaw.messages[4].content -ceq 'first completed') 'Raw archive retains earlier answers and tools after active history pruning'
    Assert-Harness (($continuedPruned.messages.role -join ',') -ceq 'system,user,user,assistant' -and $continuedPruned.messages[-1].content -ceq 'second completed') 'Pruned export retains all user messages and only the latest answer'
    Assert-Harness (($continued.Messages.role -join ',') -ceq 'system,user,assistant,user,assistant' -and $continued.RawMessages.Count -eq 7 -and $continued.Messages[-3].content -ceq 'first completed') 'Saving does not compact or mutate the running conversation'
    $journalContextOptions = $interactiveOptions.Clone(); $journalContextOptions.NoPromptHistory = $false
    & $module { $script:ContextReplies.Enqueue('/save-context raw journal-context.json'); $script:ContextReplies.Enqueue('exit') }
    Set-HarnessResponses @((New-HarnessResponse 'journaled context answer'))
    $journaledContext = Invoke-AgentHarness 'journaled context task' @journalContextOptions -PassThru 6>$null
    $contextJournal = @([IO.File]::ReadAllLines($journaledContext.PromptHistoryPath) | ForEach-Object { ConvertFrom-Json -InputObject $_ })
    Assert-Harness (($contextJournal.type -join ',') -ceq 'initial_prompt,context_save_command,stop_reply' -and $contextJournal[1].text -ceq '/save-context raw journal-context.json' -and @(Get-HarnessRequests).Count -eq 1) 'Prompt journal distinguishes save commands from continuation tasks'

    # Summary is a separate, tool-free call; resume carries the handoff as user data.
    $summaryObject = @{ goal = 'Synthetic goal'; constraints = 'Keep synthetic data'; decisions = 'Use the local fixture'; completed_work = 'First task completed'; verification = 'Mocked tool result only'; unfinished_work = 'Inspect current files'; next_steps = 'Recheck and continue' }
    $summaryJson = ConvertTo-Json -InputObject $summaryObject -Compress
    & $module { $script:ContextReplies.Enqueue('/save-context summary summary.json'); $script:ContextReplies.Enqueue('exit') }
    Set-HarnessResponses @((New-HarnessResponse 'final before summary'), (New-HarnessResponse $summaryJson))
    $summarized = Invoke-AgentHarness 'latest media task' @interactiveOptions -History $contentHistory -PassThru 6>$null
    $summaryFile = Read-ContextFixture summary.json
    $summaryRequest = @(Get-HarnessRequests)[1]
    Assert-Harness ($summaryFile.mode -ceq 'summary' -and $summaryFile.summary.decisions -ceq 'Use the local fixture' -and $summaryFile.summarySource.messageCount -eq 4) 'Summary stores structured handoff and source metadata'
    Assert-Harness (-not $summaryRequest.Body.tools -and -not $summaryRequest.Body.tool_choice -and $summaryRequest.Body.messages[1].content[1].image_url.url -ceq 'data:image/png;base64,AA==') 'Summary request has no tools and retains historical multimodal input'
    Assert-Harness ($summaryFile.messages.Count -eq 3 -and $summaryFile.messages[0].role -ceq 'user' -and $summaryFile.messages[1].content -ceq 'latest media task' -and $summarized.PromptTokens -eq 20 -and $summarized.CompletionTokens -eq 4) 'Summary retains latest user/answer and includes request usage in invocation totals'
    Assert-Harness ($summarized.Messages.Count -eq 4 -and $summarized.Answer -ceq 'final before summary') 'Summary export does not replace the active conversation or answer'
    Set-HarnessResponses @((New-HarnessResponse 'summary resumed'))
    $summaryResumed = Invoke-AgentHarness 'Continue' @resumeOptions -ContextPath summary.json -PassThru
    Assert-Harness ($summaryResumed.Messages[1].role -ceq 'user' -and $summaryResumed.Messages[1].content.Contains('Inspect current files') -and $summaryResumed.Messages[0].content.Contains('Current synthetic repository instructions.')) 'Summary loads below fresh system instructions'

    # Save failures are recoverable at the prompt and leave an existing file intact.
    Write-ContextFixture protected.json @{ sentinel = 'previous file' }
    $protectedBefore = [IO.File]::ReadAllText((Join-Path $contextRoot 'protected.json'))
    foreach ($preference in 'Continue', 'Stop') {
        & $module { $script:ContextReplies.Enqueue('/save-context summary protected.json'); $script:ContextReplies.Enqueue('/save-context raw retry.json'); $script:ContextReplies.Enqueue('exit') }
        Set-HarnessResponses @((New-HarnessResponse 'recoverable answer'), (New-HarnessResponse 'not JSON'))
        $retried = Invoke-AgentHarness 'failed summary' @interactiveOptions -ErrorAction $preference -PassThru 6>$null
        Assert-Harness ($retried.Answer -ceq 'recoverable answer' -and $retried.ContextPath -eq (Join-Path $contextRoot 'retry.json') -and [IO.File]::ReadAllText((Join-Path $contextRoot 'protected.json')) -ceq $protectedBefore) "Summary failure preserves previous file and allows retry under $preference"
    }
    Set-HarnessResponses @((New-HarnessResponse 'before refusal'), (New-HarnessResponse '' @((New-HarnessCall context_echo '{}'))))
    Assert-HarnessThrows { Invoke-AgentHarness 'invalid summary call' @contextOptions -SaveContextPath protected.json -ContextMode Summary } '*Context save failed*'
    Assert-Harness ([IO.File]::ReadAllText((Join-Path $contextRoot 'protected.json')) -ceq $protectedBefore) 'Summary tool calls are never executed or saved'

    # Invalid imports fail before any provider request under both error preferences.
    foreach ($preference in 'Continue', 'Stop') {
        foreach ($kind in 'version', 'messages', 'orphan', 'unresolved', 'arguments', 'duplicate', 'role', 'role-array', 'content', 'part-type', 'mode-array', 'summary') {
            $invalid = Read-ContextFixture raw.json
            switch ($kind) {
                version { $invalid.version = 2 }
                messages { $invalid.messages = $invalid.messages[0] }
                orphan { $invalid.messages[4].tool_call_id = 'missing' }
                unresolved { $invalid.messages = @($invalid.messages[0..3]) + @($invalid.messages[-1]) }
                arguments { $invalid.messages[3].tool_calls[0].function.arguments = '[{}]' }
                duplicate { $invalid.messages[3].tool_calls += $invalid.messages[3].tool_calls[0] }
                role { $invalid.messages[0].role = 'developer' }
                role-array { $invalid.messages[0].role = @('system') }
                content { $invalid.messages[1].content[0].text = @('invalid') }
                part-type { $invalid.messages[1].content[0].type = @() }
                mode-array { $invalid.mode = @('raw') }
                summary { $invalid.mode = 'summary'; $invalid.summary = @{ goal = 'Incomplete' } }
            }
            Write-ContextFixture invalid.json $invalid
            Set-HarnessResponses @()
            Assert-HarnessThrows { Invoke-AgentHarness 'Do not send' @contextOptions -ContextPath invalid.json -ErrorAction $preference } '*'
            Assert-Harness (@(Get-HarnessRequests).Count -eq 0) "Malformed $kind import never reaches a provider under $preference"
        }
    }
    [IO.File]::WriteAllText((Join-Path $contextRoot 'invalid.json'), '{ broken JSON')
    Assert-HarnessThrows { Invoke-AgentHarness 'Do not send' @contextOptions -ContextPath invalid.json } '*valid UTF-8 JSON*'
    [IO.File]::WriteAllText((Join-Path $contextRoot 'invalid.json'), '{"format":"SpiAgentHarness.Context","format":"ambiguous"}')
    Assert-HarnessThrows { Invoke-AgentHarness 'Do not send' @contextOptions -ContextPath invalid.json } '*valid UTF-8 JSON*'
    Assert-HarnessThrows { Invoke-AgentHarness 'Do not send' @contextOptions -ContextPath raw.json -History @() } '*either ContextPath or History*'
    Assert-HarnessThrows { Invoke-AgentHarness 'Do not send' @contextOptions -ContextMode Pruned } '*ContextMode requires*'
    Assert-HarnessThrows { Invoke-AgentHarness 'Do not send' @contextOptions -ContextPath missing.json } '*'

    # Explicit one-shot modes and failures have no partial checkpoint writes.
    Set-HarnessResponses @((New-HarnessResponse 'pruned final'))
    $null = Invoke-AgentHarness 'pruned task' @contextOptions -History $raw.Messages -SaveContextPath oneshot.json -ContextMode Pruned
    Assert-Harness ((Read-ContextFixture oneshot.json).mode -ceq 'pruned') 'One-shot invocation supports pruned mode'
    Set-HarnessResponses @((New-HarnessResponse 'summary final'), (New-HarnessResponse $summaryJson))
    $null = Invoke-AgentHarness 'summary task' @contextOptions -SaveContextPath oneshot.json -ContextMode Summary
    Assert-Harness ((Read-ContextFixture oneshot.json).mode -ceq 'summary') 'Explicit saves atomically replace an existing checkpoint'
    Set-HarnessResponses @((New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'provider failure' @contextOptions -SaveContextPath never.json } '*'
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall context_echo '{}'))))
    $null = Invoke-AgentHarness 'iteration limit' @contextOptions -Tools $contextTools -MaxIterations 1 -SaveContextPath never.json 3>$null
    Assert-Harness (-not (Test-Path -LiteralPath (Join-Path $contextRoot 'never.json'))) 'Provider failure and iteration exhaustion never save incomplete tool history'

    . (Join-Path $PSScriptRoot 'AgentHarness.Recovery.Tests.ps1')

    # Bounded reads reject oversized snapshots before parsing.
    $largePath = Join-Path $contextRoot 'large.json'
    $largeStream = [IO.File]::Create($largePath)
    try { $largeStream.SetLength(64MB + 1) } finally { $largeStream.Dispose() }
    Assert-HarnessThrows { Invoke-AgentHarness 'Do not send' @contextOptions -ContextPath large.json } '*64 MiB*'
    if ($IsWindows) {
        $link = Join-Path $contextRoot 'linked'
        $target = Join-Path $contextRoot 'target'
        $null = New-Item -ItemType Directory -Path $target
        $null = New-Item -ItemType Junction -Path $link -Target $target
        try {
            Assert-HarnessThrows { Invoke-AgentHarness 'Do not send' @contextOptions -SaveContextPath 'linked/checkpoint.json' } '*reparse points*'
            Assert-HarnessThrows { Invoke-AgentHarness 'Do not send' @contextOptions -ContextPath 'linked/checkpoint.json' } '*reparse points*'
            Assert-Harness (@(Get-ChildItem -LiteralPath $target).Count -eq 0) 'Context paths refuse directory links without writing to their target'
        }
        finally { [IO.Directory]::Delete($link) }
    }
}
finally {
    & $module {
        param($saved)
        if ($saved) { Set-Item Function:script:Read-Host -Value $saved }
        else { Remove-Item Function:script:Read-Host -ErrorAction SilentlyContinue }
    } $savedContextHost
}
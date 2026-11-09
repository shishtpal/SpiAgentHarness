# Included by Invoke-AgentHarness.Tests.ps1; synthetic inputs and mocked providers only.
$journalRoot = Join-Path $fixture 'prompt-journal'
$null = New-Item -ItemType Directory -Path $journalRoot
$journalOptions = $basic.Clone()
$journalOptions.WorkingDirectory = $journalRoot
$journalOptions.NoAgentsFile = $true
$journalOptions.NoPromptSound = $true
$journalOptions.NoCompletionPrompt = $true
$savedJournalFunctions = & $module {
    @{
        HostInput = ${function:Read-Host}; Menu = ${function:Show-InteractiveMenu}
        Text = ${function:Read-InteractiveText}; Console = ${function:Test-InteractiveConsole}
    }
}
function Get-JournalEntries {
    param([string]$Path)
    foreach ($line in [IO.File]::ReadAllLines($Path)) { ConvertFrom-Json -InputObject $line }
}
try {
    & $module {
        $script:JournalHostReplies = [Collections.Generic.Queue[object]]::new()
        $script:JournalMenuReplies = [Collections.Generic.Queue[object]]::new()
        $script:JournalTextReplies = [Collections.Generic.Queue[object]]::new()
        function script:Read-Host {
            param($Prompt)
            if (-not $script:JournalHostReplies.Count) { throw 'Unexpected journal input request.' }
            $script:JournalHostReplies.Dequeue()
        }
        function script:Show-InteractiveMenu {
            [CmdletBinding()]
            param($Options, $Title, $Description, $OptionDescriptions, [switch]$MultiSelect, [switch]$Filter)
            if (-not $script:JournalMenuReplies.Count) { throw 'Unexpected journal menu request.' }
            $script:JournalMenuReplies.Dequeue()
        }
        function script:Read-InteractiveText {
            [CmdletBinding()]
            param($Title, $Description)
            if (-not $script:JournalTextReplies.Count) { throw 'Unexpected journal text request.' }
            $script:JournalTextReplies.Dequeue()
        }
        function script:Test-InteractiveConsole { $true }
    }

    # Intake preserves exact input, without copying attachments or old History.
    [IO.File]::WriteAllText((Join-Path $journalRoot 'sample.txt'), 'UNIQUE_SYNTHETIC_ATTACHMENT_BODY')
    $inputLines = @('Unicode नमस्ते "quoted"', '', 'Inspect @attach("sample.txt")')
    $originalPrompt = $inputLines -join [Environment]::NewLine
    Set-HarnessResponses @((New-HarnessResponse 'journal ready'))
    $firstJournal = Invoke-AgentHarness $inputLines @journalOptions -Attachments sample.txt -History @(@{ role = 'user'; content = 'OLD_SYNTHETIC_HISTORY' }) -PassThru
    $entries = @(Get-JournalEntries $firstJournal.PromptHistoryPath)
    Assert-Harness ((Split-Path (Split-Path $firstJournal.PromptHistoryPath -Parent) -Leaf) -eq 'prompts' -and $firstJournal.PromptHistoryPath.StartsWith((Join-Path $journalRoot '.agents'))) 'Journal uses WorkingDirectory/.agents/prompts'
    Assert-Harness ($entries.Count -eq 1 -and $entries[0].type -eq 'initial_prompt' -and $entries[0].text -ceq $originalPrompt) 'Journal preserves multiline Unicode input and raw attachment markers'
    Assert-Harness ($entries[0].data.attachments -is [array] -and $entries[0].data.attachments[0] -eq 'sample.txt') 'Explicit attachments remain a reference array'
    $rawJournal = [IO.File]::ReadAllText($firstJournal.PromptHistoryPath)
    Assert-Harness (-not $rawJournal.Contains('UNIQUE_SYNTHETIC_ATTACHMENT_BODY') -and -not $rawJournal.Contains('OLD_SYNTHETIC_HISTORY')) 'Journal excludes attachment bodies and historical messages'
    Assert-Harness ($entries[0].version -eq 1 -and $entries[0].sequence -eq 1 -and $entries[0].sessionId -match '^[a-f0-9]{32}$' -and $rawJournal -match '"timestamp":"[^"]+\+00:00"') 'Journal contains version, sequence, unique session and UTC timestamp'
    $journalBytes = [IO.File]::ReadAllBytes($firstJournal.PromptHistoryPath)
    Assert-Harness ($journalBytes[0] -eq 123 -and [IO.File]::ReadAllLines($firstJournal.PromptHistoryPath).Count -eq 1) 'UTF-8 journal has no BOM and multiline text occupies one JSON line'

    # One invocation records guidance, structured answers, invalid follow-ups and stop.
    $interactiveJournalOptions = $journalOptions.Clone()
    $interactiveJournalOptions.NoBuiltinTools = $false
    $interactiveJournalOptions.NoCompletionPrompt = $false
    & $module {
        $script:JournalHostReplies.Enqueue("  Please inspect first.`nKeep this spacing.  ")
        $script:JournalHostReplies.Enqueue('Invalid @attach("missing.txt")')
        $script:JournalHostReplies.Enqueue('next task')
        $script:JournalHostReplies.Enqueue('exit')
        $script:JournalTextReplies.Enqueue("answer`r`nsecond line")
        $script:JournalMenuReplies.Enqueue('1. Alpha')
        $script:JournalMenuReplies.Enqueue($null)
        $script:JournalMenuReplies.Enqueue(@('One', 'Two'))
        $script:JournalMenuReplies.Enqueue($null)
    }
    $questionArgs = @{ questions = @(
            @{ id = 'text'; type = 'text'; title = 'Text'; description = 'Synthetic text answer' },
            @{ id = 'choice'; type = 'multi_choice'; title = 'Choice'; description = 'Synthetic choice'; options = @(@{ id = 'a'; title = 'Alpha' }) },
            @{ id = 'cancel'; type = 'single_choice'; title = 'Cancel'; description = 'Synthetic cancellation'; options = @(@{ id = 'b'; title = 'Beta' }) },
            @{ id = 'unasked'; type = 'text'; title = 'Unasked'; description = 'Must not be recorded' }
        ) } | ConvertTo-Json -Depth 10 -Compress
    $menuArgs = @{ questions = @(
            @{ id = 'menu'; title = 'Menu'; options = @('One', 'Two'); multi_select = $true },
            @{ id = 'cancel-menu'; title = 'Cancel menu'; options = @('One') }
        ) } | ConvertTo-Json -Depth 10 -Compress
    Set-HarnessResponses @(
        (New-HarnessResponse '' @((New-HarnessCall write_file '{"path":"denied.txt","content":"Synthetic denied write"}'))),
        (New-HarnessResponse '' @((New-HarnessCall ask_user $questionArgs))),
        (New-HarnessResponse '' @((New-HarnessCall show_interactive_menu $menuArgs))),
        (New-HarnessResponse 'first complete'), (New-HarnessResponse 'second complete')
    )
    $interactiveJournal = Invoke-AgentHarness 'initial interactive task' @interactiveJournalOptions -PassThru 6>$null
    $entries = @(Get-JournalEntries $interactiveJournal.PromptHistoryPath)
    Assert-Harness (($entries.type -join ',') -eq 'initial_prompt,approval_reply,question_answer,question_answer,question_answer,menu_answer,menu_answer,continuation_prompt,continuation_prompt,stop_reply') 'All input paths append once in intake order, including invalid continuations and stop'
    Assert-Harness ($entries[1].text -ceq "  Please inspect first.`nKeep this spacing.  " -and $entries[2].text -ceq "answer`r`nsecond line") 'Approval guidance and text answers preserve original whitespace'
    Assert-Harness ($entries[3].data.answer -is [array] -and $entries[3].data.answer[0] -eq 'a' -and $entries[4].data.cancelled -and $entries[4].data.answer -is [array] -and $entries[4].data.answer.Count -eq 0) 'Question choice IDs and cancellation retain JSON arrays'
    Assert-Harness ($entries[5].data.selections.Count -eq 2 -and $entries[6].data.selections -is [array] -and $entries[6].data.selections.Count -eq 0) 'Menu selections and cancellation retain JSON arrays'
    Assert-Harness ((@($entries.sessionId | Select-Object -Unique).Count -eq 1) -and ($entries.sequence -join ',') -eq '1,2,3,4,5,6,7,8,9,10') 'One invocation has one session ID and increasing sequence numbers'
    Assert-Harness ($interactiveJournal.PromptHistoryPath -ne $firstJournal.PromptHistoryPath -and [IO.File]::ReadAllLines($firstJournal.PromptHistoryPath).Count -eq 1) 'Separate invocations do not overwrite or append to earlier sessions'

    # Record before provider failures or attachment validation; never replay History.
    $beforeFailure = @(Get-ChildItem -LiteralPath (Join-Path $journalRoot '.agents/prompts') -File).Count
    Set-HarnessResponses @((New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'provider failure retained' @journalOptions } '*'
    $afterFailure = @(Get-ChildItem -LiteralPath (Join-Path $journalRoot '.agents/prompts') -File)
    Assert-Harness ($afterFailure.Count -eq $beforeFailure + 1 -and @($afterFailure | Where-Object { [IO.File]::ReadAllText($_.FullName).Contains('provider failure retained') }).Count -eq 1) 'Provider failure leaves the input journal on disk'

    # Opt-out has no filesystem side effects, including no prompts directory.
    $disabledRoot = Join-Path $journalRoot 'disabled'
    $null = New-Item -ItemType Directory -Path $disabledRoot
    $disabledOptions = $journalOptions.Clone(); $disabledOptions.WorkingDirectory = $disabledRoot
    Set-HarnessResponses @((New-HarnessResponse 'disabled'))
    $disabled = Invoke-AgentHarness 'not recorded' @disabledOptions -NoPromptHistory -PassThru
    Assert-Harness ($null -eq $disabled.PromptHistoryPath -and -not (Test-Path -LiteralPath (Join-Path $disabledRoot '.agents'))) 'NoPromptHistory creates no journal directory or file'

    # Failures stay nonfatal under Continue and Stop, with one sanitized warning.
    foreach ($preference in 'Continue', 'Stop') {
        $blockedRoot = Join-Path $journalRoot "blocked-$preference"
        $null = New-Item -ItemType Directory -Path $blockedRoot
        [IO.File]::WriteAllText((Join-Path $blockedRoot '.agents'), 'Synthetic path blocker')
        $blockedOptions = $journalOptions.Clone(); $blockedOptions.WorkingDirectory = $blockedRoot
        Set-HarnessResponses @((New-HarnessResponse 'still completes'))
        $journalWarnings = @()
        $blocked = Invoke-AgentHarness 'blocked input' @blockedOptions -PassThru -ErrorAction $preference -WarningAction Stop -WarningVariable journalWarnings 3>$null
        Assert-Harness ($blocked.Answer -eq 'still completes' -and $null -eq $blocked.PromptHistoryPath -and $journalWarnings.Count -eq 1) "Journal write failure is nonfatal under $preference"
        Assert-Harness (-not ([string]$journalWarnings[0]).Contains($blockedRoot) -and -not ([string]$journalWarnings[0]).Contains('blocked input')) 'Journal warning excludes filesystem and input details'
    }

    # Existing path protections reject directory links instead of writing elsewhere.
    if ($IsWindows) {
        $linkRoot = Join-Path $journalRoot 'linked'
        $linkTarget = Join-Path $journalRoot 'link-target'
        $null = New-Item -ItemType Directory -Path (Join-Path $linkRoot '.agents') -Force
        $null = New-Item -ItemType Directory -Path $linkTarget
        $linkPath = Join-Path $linkRoot '.agents/prompts'
        $null = New-Item -ItemType Junction -Path $linkPath -Target $linkTarget
        try {
            $linkOptions = $journalOptions.Clone(); $linkOptions.WorkingDirectory = $linkRoot
            Set-HarnessResponses @((New-HarnessResponse 'link rejected'))
            $linked = Invoke-AgentHarness 'linked input' @linkOptions -PassThru 3>$null
            Assert-Harness ($null -eq $linked.PromptHistoryPath -and @(Get-ChildItem -LiteralPath $linkTarget -Force).Count -eq 0) 'Prompt journal refuses reparse-point destinations'
        }
        finally { [IO.Directory]::Delete($linkPath) }
    }
}
finally {
    & $module {
        param($saved)
        if ($saved.HostInput) { Set-Item Function:script:Read-Host -Value $saved.HostInput }
        else { Remove-Item Function:script:Read-Host -ErrorAction SilentlyContinue }
        Set-Item Function:script:Show-InteractiveMenu -Value $saved.Menu
        Set-Item Function:script:Read-InteractiveText -Value $saved.Text
        Set-Item Function:script:Test-InteractiveConsole -Value $saved.Console
    } $savedJournalFunctions
}
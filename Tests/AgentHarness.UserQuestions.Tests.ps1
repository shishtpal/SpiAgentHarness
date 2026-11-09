# Included by Invoke-AgentHarness.Tests.ps1; uses only synthetic answers and mocked transport.
$savedQuestionFunctions = & $module {
    @{
        Menu = ${function:Show-InteractiveMenu}; Text = ${function:Read-InteractiveText}
        Console = ${function:Test-InteractiveConsole}; Sound = ${function:Invoke-Sound}
    }
}
function Invoke-QuestionTestCall {
    param([string]$Json, [string]$Preference = 'Stop', [int]$MaxOutputChars = 8000)
    & $module {
        param($json, $preference, $limit)
        $ErrorActionPreference = $preference
        Invoke-AgentHarnessToolCall -Call @{ id = 'question_test'; function = @{ name = 'ask_user'; arguments = $json } } `
            -ToolTable (Get-AgentHarnessBuiltinTools) -Context @{ Quiet = $true; YOLO = $true; NoPromptSound = $true } -MaxOutputChars $limit
    } $Json $Preference $MaxOutputChars
}
try {
    & $module {
        $script:QuestionReplies = [Collections.Generic.Queue[object]]::new()
        $script:QuestionCalls = [Collections.Generic.List[object]]::new()
        $script:QuestionSounds = 0
        $script:QuestionAvailable = $true
        $script:QuestionError = ''
        $script:QuestionSoundError = $false
        function script:Test-InteractiveConsole { $script:QuestionAvailable }
        function script:Invoke-Sound {
            $script:QuestionSounds++
            if ($script:QuestionSoundError) { throw 'Synthetic sound failure.' }
        }
        function script:Read-InteractiveText {
            [CmdletBinding()]
            param($Title, $Description)
            $script:QuestionCalls.Add(@{ Type = 'text'; Title = $Title; Description = $Description })
            if ($script:QuestionError -eq 'throw') { throw 'Synthetic question input failure.' }
            if ($script:QuestionError -eq 'continue') { Write-Error 'Synthetic question input failure.' -ErrorAction Continue; return }
            if (-not $script:QuestionReplies.Count) { throw 'Unexpected text prompt.' }
            $script:QuestionReplies.Dequeue()
        }
        function script:Show-InteractiveMenu {
            [CmdletBinding()]
            param($Title, $Description, $Options, $OptionDescriptions, [switch]$MultiSelect, [switch]$Filter)
            $script:QuestionCalls.Add(@{ Type = 'choice'; Title = $Title; Description = $Description; Options = @($Options); Descriptions = @($OptionDescriptions); MultiSelect = [bool]$MultiSelect; Filter = [bool]$Filter })
            if ($script:QuestionError -eq 'throw') { throw 'Synthetic question input failure.' }
            if ($script:QuestionError -eq 'continue') { Write-Error 'Synthetic question input failure.' -ErrorAction Continue; return }
            if (-not $script:QuestionReplies.Count) { throw 'Unexpected choice prompt.' }
            $script:QuestionReplies.Dequeue()
        }
    }
    $textQuestion = @{ id = 'name'; title = 'Project name?'; description = 'Shown in the header.'; type = 'text' }
    $singleQuestion = @{ id = 'storage'; title = 'Storage?'; description = 'Choose storage.'; type = 'single_choice'; options = @(
            @{ id = 'local'; title = 'Files'; description = 'On this computer.' }, @{ id = 'remote'; title = 'Files'; description = 'On the server.' }) }
    $multiQuestion = @{ id = 'features'; title = 'Features?'; description = 'Choose features.'; type = 'multi_choice'; options = @(
            @{ id = 'a'; title = 'Alpha' }, @{ id = 'b'; title = 'Beta' }) }
    $textJson = @{ questions = @($textQuestion) } | ConvertTo-Json -Depth 10 -Compress
    $singleJson = @{ questions = @($singleQuestion) } | ConvertTo-Json -Depth 10 -Compress
    $multiJson = @{ questions = @($multiQuestion) } | ConvertTo-Json -Depth 10 -Compress
    $mixedJson = @{ questions = @($textQuestion, $singleQuestion, $multiQuestion) } | ConvertTo-Json -Depth 10 -Compress
    & $module {
        $script:QuestionReplies.Enqueue('School "Portal"')
        $script:QuestionReplies.Enqueue('2. Files')
        $script:QuestionReplies.Enqueue(@('2. Beta', '1. Alpha'))
    }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall ask_user $mixedJson user_answers))), (New-HarnessResponse 'answers received'))
    $questionRun = Invoke-AgentHarness 'Ask for requirements' @withBuiltins -YOLO -NoShellTool -AllowWrite:$false -PassThru
    $questionResult = @($questionRun.Messages | Where-Object role -eq tool)[0]
    $questionAnswers = $questionResult.content | ConvertFrom-Json
    Assert-Harness ($questionRun.Answer -eq 'answers received' -and -not $questionAnswers.cancelled) 'ask_user completes through the real harness in Quiet/YOLO without write/shell tools'
    Assert-Harness ($questionAnswers.answers -is [array] -and ($questionAnswers.answers.id -join ',') -ceq 'name,storage,features') 'Mixed question answers retain order and IDs'
    Assert-Harness ($questionAnswers.answers[0].answer -ceq 'School "Portal"' -and $questionAnswers.answers[0].answer -is [string]) 'Text answer survives JSON encoding'
    Assert-Harness ($questionAnswers.answers[1].answer -is [array] -and $questionAnswers.answers[1].answer.Count -eq 1 -and $questionAnswers.answers[1].answer[0] -ceq 'remote') 'Duplicate titles map unambiguously to a singleton option-ID array'
    Assert-Harness (($questionAnswers.answers[2].answer -join ',') -ceq 'b,a') 'Multiple selections return stable option IDs in selection order'
    $questionCalls = & $module { $script:QuestionCalls.ToArray() }
    Assert-Harness ($questionCalls[0].Description -eq 'Shown in the header.' -and $questionCalls[1].Descriptions[1] -eq 'On the server.' -and -not $questionCalls[1].MultiSelect -and $questionCalls[2].MultiSelect -and $questionCalls[2].Filter) 'Question context and option descriptions reach the proper renderer'
    Assert-Harness ((& $module { $script:QuestionSounds }) -eq 3) 'Each displayed question sounds even in Quiet/YOLO'
    $questionRequests = @(Get-HarnessRequests)
    Assert-Harness ($questionRequests[1].Body.messages[-1].tool_call_id -eq 'user_answers' -and $questionRequests[1].Body.messages[-1].content -eq $questionResult.content) 'Answers and tool call ID reach the next mocked provider turn'
    $questionSchema = @($questionRequests[0].Body.tools | Where-Object { $_.function.name -eq 'ask_user' })[0].function.parameters | ConvertTo-Json -Depth 30
    Assert-Harness (Test-Json -Json $mixedJson -Schema $questionSchema) 'Advertised schema accepts all three question types'
    Assert-Harness ($questionRequests[0].Body.messages[0].content -like '*Prefer ask_user*') 'System prompt guides the agent to ask_user'

    foreach ($json in @($textJson, $singleJson, $multiJson)) {
        & $module { $script:QuestionReplies.Enqueue($null) }
        $cancel = (Invoke-QuestionTestCall $json).content | ConvertFrom-Json
        Assert-Harness ($cancel.cancelled -and $cancel.answers -is [array] -and $cancel.answers.Count -eq 1 -and $cancel.answers[0].cancelled) 'First-question cancellation is explicit and preserves answers array'
        if ($json -eq $textJson) {
            Assert-Harness ($null -eq $cancel.answers[0].answer) 'Cancelled text returns null'
        }
        else {
            Assert-Harness ($cancel.answers[0].answer -is [array] -and $cancel.answers[0].answer.Count -eq 0) 'Cancelled choices return an empty array'
        }
    }
    & $module { $script:QuestionReplies.Enqueue('Kept'); $script:QuestionReplies.Enqueue($null) }
    $beforePartial = & $module { $script:QuestionCalls.Count }
    $partial = (Invoke-QuestionTestCall $mixedJson).content | ConvertFrom-Json
    Assert-Harness ($partial.cancelled -and $partial.answers.Count -eq 2 -and $partial.answers[0].answer -ceq 'Kept' -and $partial.answers[1].id -eq 'storage') 'Cancellation retains earlier answers and omits unasked questions'
    Assert-Harness ((& $module { $script:QuestionCalls.Count }) -eq ($beforePartial + 2)) 'Cancellation stops the remaining prompts'
    & $module { $script:QuestionReplies.Enqueue('one') }
    $oneText = (Invoke-QuestionTestCall $textJson).content | ConvertFrom-Json
    Assert-Harness ($oneText.answers -is [array] -and $oneText.answers.Count -eq 1 -and $oneText.answers[0].answer -ceq 'one') 'One text question retains answers array'
    & $module { $script:QuestionReplies.Enqueue('1. Alpha') }
    $oneMulti = (Invoke-QuestionTestCall $multiJson).content | ConvertFrom-Json
    Assert-Harness ($oneMulti.answers[0].answer -is [array] -and $oneMulti.answers[0].answer.Count -eq 1) 'One multi-choice selection retains its array'
    Assert-Harness ((& $module { $script:QuestionSounds }) -eq 3) 'NoPromptSound mutes question sounds'

    & $module { $script:QuestionAvailable = $false }
    $beforeUnavailable = & $module { $script:QuestionCalls.Count }
    $unavailable = (Invoke-QuestionTestCall $mixedJson).content | ConvertFrom-Json
    Assert-Harness ($unavailable.unavailable -and -not $unavailable.cancelled -and $unavailable.answers -is [array] -and $unavailable.answers.Count -eq 0) 'Missing interactive console returns explicit unavailability'
    Assert-Harness ((& $module { $script:QuestionCalls.Count }) -eq $beforeUnavailable) 'Unavailable input never opens a prompt'
    & $module { $script:QuestionAvailable = $true }

    $invalidQuestions = @(
        '{}', '[]', 'null', '"object"', '{"questions":[]}', '{"questions":{}}', '{"questions":null}', '{"questions":[null]}', '{"questions":[[]]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"text","answer":"invented"}]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"Text"}]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"text","options":[]}]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"single_choice"}]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"single_choice","options":"one"}]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"single_choice","options":[]}]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"single_choice","options":[null]}]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"single_choice","options":["one"]}]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"single_choice","options":[{"id":"a","title":"A","description":null}]}]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"single_choice","options":[{"id":"a","title":"A","extra":true}]}]}',
        '{"questions":[{"id":"x","title":"T","description":"D","type":"single_choice","options":[{"id":"a","title":"A"},{"id":"a","title":"B"}]}]}'
    )
    foreach ($field in 'id', 'title', 'description', 'type') {
        foreach ($badValue in @($null, 2, ' ')) {
            $bad = $textQuestion.Clone(); $bad[$field] = $badValue
            $invalidQuestions += @{ questions = @($textQuestion, $bad) } | ConvertTo-Json -Depth 10 -Compress
        }
        $bad = $textQuestion.Clone(); $bad.Remove($field)
        $invalidQuestions += @{ questions = @($textQuestion, $bad) } | ConvertTo-Json -Depth 10 -Compress
    }
    foreach ($field in 'id', 'title') {
        foreach ($badValue in @($null, 2, ' ')) {
            $badOption = @{ id = 'a'; title = 'A' }; $badOption[$field] = $badValue
            $bad = $singleQuestion.Clone(); $bad.options = @($badOption)
            $invalidQuestions += @{ questions = @($textQuestion, $bad) } | ConvertTo-Json -Depth 10 -Compress
        }
    }
    $invalidQuestions += @{ questions = @($textQuestion, $textQuestion) } | ConvertTo-Json -Depth 10 -Compress
    $invalidQuestions += @{ questions = @($textQuestion); extra = $true } | ConvertTo-Json -Depth 10 -Compress
    $invalidQuestions += $textJson.Replace('"questions"', '"Questions"')
    $beforeInvalid = & $module { $script:QuestionCalls.Count }
    foreach ($preference in 'Continue', 'Stop') {
        foreach ($json in $invalidQuestions) {
            Assert-Harness ((Invoke-QuestionTestCall $json $preference).content -like 'ERROR:*') "Malformed questions return an error under $preference"
        }
    }
    Assert-Harness ((& $module { $script:QuestionCalls.Count }) -eq $beforeInvalid) 'Invalid later questions never cause partial prompts'
    Assert-Harness (-not (Test-Json -Json $invalidQuestions[9] -Schema $questionSchema -ErrorAction SilentlyContinue)) 'Advertised schema rejects agent-supplied answers'

    foreach ($preference in 'Continue', 'Stop') {
        foreach ($mode in 'throw', 'continue') {
            foreach ($json in @($textJson, $singleJson)) {
                & $module { param($mode) $script:QuestionError = $mode } $mode
                Assert-Harness ((Invoke-QuestionTestCall $json $preference).content -like 'ERROR:*Synthetic question input failure*') "Input $mode errors become tool errors under $preference"
            }
        }
    }
    & $module { $script:QuestionError = '' }
    foreach ($reply in @('unknown', @('1. Files', '2. Files'), 42)) {
        & $module { param($reply) $script:QuestionReplies.Enqueue($reply) } $reply
        Assert-Harness ((Invoke-QuestionTestCall $singleJson).content -like 'ERROR:*') 'Invalid menu replies never become answers'
    }
    & $module { $script:QuestionReplies.Clear(); $script:QuestionReplies.Enqueue(@('1. Alpha', '1. Alpha')) }
    Assert-Harness ((Invoke-QuestionTestCall $multiJson).content -like 'ERROR:*duplicate*') 'Duplicate menu selections are rejected'
    & $module { $script:QuestionReplies.Enqueue(' ') }
    Assert-Harness ((Invoke-QuestionTestCall $textJson).content -like 'ERROR:*invalid answer*') 'Invalid blank renderer output is rejected'
    & $module { $script:QuestionReplies.Enqueue(('x' * 1000)) }
    $overflow = Invoke-QuestionTestCall $textJson -MaxOutputChars 200
    Assert-Harness ($overflow.content -like 'ERROR: User answers exceed MaxToolOutputChars*' -and $overflow.content -notlike '*truncated*') 'Oversized answers fail explicitly instead of truncating JSON'
    & $module { $script:QuestionSoundError = $true; $script:QuestionReplies.Enqueue('soundless') }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall ask_user $textJson sound_failure))), (New-HarnessResponse))
    $soundRun = Invoke-AgentHarness 'Answer despite sound failure' @withBuiltins -PassThru
    $soundAnswer = @($soundRun.Messages | Where-Object role -eq tool)[0].content | ConvertFrom-Json
    Assert-Harness ($soundAnswer.answers[0].answer -eq 'soundless') 'Sound failure does not prevent collecting an answer'
    Assert-Harness (-not $module.ExportedFunctions.ContainsKey('Read-InteractiveText') -and -not $module.ExportedFunctions.ContainsKey('Invoke-AgentHarnessUserQuestions')) 'Question helpers remain private'
}
finally {
    & $module {
        param($saved)
        Set-Item Function:script:Show-InteractiveMenu -Value $saved.Menu
        Set-Item Function:script:Read-InteractiveText -Value $saved.Text
        Set-Item Function:script:Test-InteractiveConsole -Value $saved.Console
        Set-Item Function:script:Invoke-Sound -Value $saved.Sound
    } $savedQuestionFunctions
}
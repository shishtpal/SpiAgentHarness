# Runs in the isolated decision fixture; all HTTP is mocked.
function New-NativeDecisionResponse {
    @{
        model = 'native-snapshot'; id = 'native-test'; usage = @{ input_tokens = 12 }
        answers = @(
            @{ type = 'choice'; name = 'route'; choice = 'billing'; confidence = 0.8; probabilities = @(@{ value = 'billing'; probability = 0.9 }, @{ value = 'other'; probability = 0.1 }) },
            @{ type = 'predicate'; name = 'relevant'; probability = 0.8 },
            @{ type = 'score'; name = 'urgency'; score = 1.5; probabilities = @(@{ value = 0; probability = 0.1 }, @{ value = 1; probability = 0.3 }, @{ value = 2; probability = 0.6 }) }
        )
    }
}

$nativeQuestions = [ordered]@{
    route    = @{ type = 'choice'; instructions = 'Route ticket'; criteria = [ordered]@{ billing = 'Billing'; other = 'Other' } }
    relevant = @{ type = 'noul'; instructions = 'Is relevant?'; criteria = @{ 'true' = 'Relevant'; 'false' = 'Other' } }
    urgency  = @{ type = 'score'; instructions = 'Urgency'; criteria = @('Low', 'Medium', 'High') }
}
$nativeOptions = @{ Provider = 'ExperientialLabs'; Model = 'gpt-6-luna-decisions'; KeyEnvVar = 'SPI_DECISION_TEST_KEY'; Quiet = $true; State = 'evidence'; Questions = $nativeQuestions }
Set-DecisionResponses @((New-NativeDecisionResponse))
$nativeResult = Invoke-DecisionModel @nativeOptions -Attachment $attachmentPath
$nativeRequest = & $module { $script:Requests[0] }
$nativeBody = $nativeRequest.Json | ConvertFrom-Json -AsHashtable
Assert-Decision ($nativeRequest.Uri -eq 'https://api.experientiallabs.ai/v1/decisions') 'Luna selects its native decision route'
Assert-Decision ($nativeBody.model -ceq 'gpt-6-luna-decisions' -and $nativeBody.questions -is [array] -and $nativeBody.questions.Count -eq 3) 'Native model and ordered questions use the correct wire format'
Assert-Decision ($nativeBody.questions[0].choices[0].value -ceq 'billing' -and $nativeBody.questions[1].type -ceq 'predicate' -and $nativeBody.questions[2].levels[2].label -ceq '2') 'Choice, predicate and score questions are translated'
Assert-Decision ($nativeBody.input[0].content[1].type -ceq 'input_image' -and $nativeBody.input[0].content[1].image_url -like 'data:image/png;base64,*') 'Native images use inline input_image parts'
Assert-Decision ($nativeResult.Answers.route.probabilities.billing -eq 0.9 -and $nativeResult.Answers.relevant.noul -eq 0.8 -and $nativeResult.Answers.urgency.score -eq 1.5) 'Native answers normalize to the existing result contract'
Assert-Decision ($nativeResult.RawResponse.answers -is [array]) 'Native raw response is retained unmodified'

$oneQuestion = @{ single = @{ type = 'choice'; instructions = 'Choose'; criteria = @{ yes = 'Yes'; no = 'No' } } }
$oneResponse = @{ model = 'native'; usage = @{}; answers = @(@{ type = 'choice'; choice = 'yes' }) }
Set-DecisionResponses @($oneResponse)
$oneResult = Invoke-DecisionModel -State @() -Questions $oneQuestion -Provider ExperientialLabs -Model gpt-6-luna-decisions -KeyEnvVar SPI_DECISION_TEST_KEY -Quiet
$oneBody = (& $module { $script:Requests[0].Json }) | ConvertFrom-Json -AsHashtable
Assert-Decision ($oneBody.questions -is [array] -and $oneBody.questions.Count -eq 1 -and $oneBody.input -ceq '[]') 'Singleton questions and empty JSON evidence survive serialization'
Assert-Decision ($null -eq $oneResult.Answers.single.probabilities) 'Unavailable native probabilities remain unavailable'

$refusal = @{ model = 'native'; usage = @{}; answers = @(@{ type = 'refusal'; name = 'single' }) }
Set-DecisionResponses @($refusal)
$refused = Invoke-DecisionModel -State 'x' -Questions $oneQuestion -Provider ExperientialLabs -Model gpt-6-luna-decisions -KeyEnvVar SPI_DECISION_TEST_KEY -Quiet
Assert-Decision ($refused.Answers.single.type -ceq 'refusal' -and $refused.Summary[0].Type -ceq 'refusal') 'Refusals remain distinct from ordinary answers'

Set-DecisionResponses @((New-DecisionResponse))
$clef = Invoke-DecisionModel -State @{ flags = @(); absent = $null } -Questions $nativeQuestions -Provider ExperientialLabs -Model clef -KeyEnvVar SPI_DECISION_TEST_KEY -Quiet
$clefBody = (& $module { $script:Requests[0].Json }) | ConvertFrom-Json -AsHashtable
Assert-Decision ((& $module { $script:Requests[0].Uri }) -eq 'https://api.experientiallabs.ai/v1/systemone' -and $clefBody.questions -is [Collections.IDictionary]) 'Clef uses the native systemone map schema'
Assert-Decision ($clefBody.state.flags -is [array] -and $clefBody.state.flags.Count -eq 0 -and $null -eq $clefBody.state.absent) 'Systemone preserves structured state arrays and nulls'
Assert-Decision ($clef.Answers.route.choice -ceq 'billing') 'Systemone answers reuse normalized validation'

foreach ($badResponse in @(
        @{ model = 'x'; usage = @{}; answers = @{} },
        @{ model = 'x'; usage = @{}; answers = @(@{ type = 'choice'; name = 'wrong'; choice = 'yes' }) },
        @{ model = 'x'; usage = @{}; answers = @(@{ type = 'choice'; choice = 'unknown' }) },
        @{ model = 'x'; usage = @{}; answers = @(@{ type = 'choice'; choice = 'yes'; probabilities = @(@{ value = 'yes'; probability = 1.1 }, @{ value = 'no'; probability = -0.1 }) }) },
        @{ model = 'x'; usage = @{}; answers = @(@{ type = 'choice'; choice = 'yes'; probabilities = @(@{ value = 'yes'; probability = 0.9 }, @{ value = 'yes'; probability = 0.1 }) }) }
    )) {
    Set-DecisionResponses @($badResponse)
    $null = Assert-DecisionThrows { Invoke-DecisionModel -State x -Questions $oneQuestion -Provider ExperientialLabs -Model gpt-6-luna-decisions -KeyEnvVar SPI_DECISION_TEST_KEY -Quiet }
}

foreach ($preference in 'Continue', 'Stop') {
    $ErrorActionPreference = $preference
    Set-DecisionResponses @((New-DecisionFailure 503), (New-NativeDecisionResponse))
    $null = Assert-DecisionThrows { Invoke-DecisionModel @nativeOptions } '*HTTP 503*'
    Assert-Decision ((& $module { $script:Requests.Count }) -eq 1) 'Native requests do not retry by default'
}
$ErrorActionPreference = 'Stop'
Set-DecisionResponses @()
$null = Assert-DecisionThrows { Invoke-DecisionModel @nativeOptions -Protocol systemone -Attachment $attachmentPath } '*image attachments*'
$badImage = Join-Path $fixture 'fake.png'
[IO.File]::WriteAllText($badImage, 'not an image')
$null = Assert-DecisionThrows { Invoke-DecisionModel @nativeOptions -Attachment $badImage } '*image type*'
$tooMany = [ordered]@{}
for ($i = 0; $i -lt 33; $i++) { $tooMany["q$i"] = $oneQuestion.single }
$null = Assert-DecisionThrows { Invoke-DecisionModel -State x -Questions $tooMany -Provider ExperientialLabs -Model clef -KeyEnvVar SPI_DECISION_TEST_KEY -Quiet } '*32 questions*'
Assert-Decision ((& $module { $script:Requests.Count }) -eq 0) 'Invalid native input never reaches HTTP'
Assert-Decision (@(Get-DecisionModels -Provider ExperientialLabs -All).Count -eq 2) 'Experiential model catalogue includes both native protocols'
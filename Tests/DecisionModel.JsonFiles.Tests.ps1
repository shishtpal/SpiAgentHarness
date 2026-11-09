# Run by Invoke-DecisionModel.Tests.ps1 with its isolated module and HTTP mocks.
$jsonDirectory = Join-Path $fixture 'json input [literal]'
$null = New-Item -ItemType Directory -Path $jsonDirectory
$questionFile = Join-Path $jsonDirectory 'questions [literal].json'
$stateFile = Join-Path $jsonDirectory 'state [literal].json'
[IO.File]::WriteAllText($questionFile, (ConvertTo-Json -InputObject $questions -Depth 20), [Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText($stateFile, '{"ticket":"नमस्ते","flags":[false],"empty":[],"absent":null}')
Set-DecisionResponses @((New-DecisionResponse))
$result = Invoke-DecisionModel -StateFile $stateFile -QuestionsFile $questionFile -Model test -Quiet
$body = (& $module { $script:Requests[0].Json }) | ConvertFrom-Json
Assert-Decision ($result.Answers.route.choice -eq 'billing' -and $body.state.ticket -ceq 'नमस्ते') 'Both file inputs support BOM, Unicode, spaces and literal brackets'
Assert-Decision ($body.state.flags -is [array] -and $body.state.flags.Count -eq 1 -and $body.state.flags[0] -ceq $false -and $body.state.empty -is [array] -and $body.state.empty.Count -eq 0 -and $null -eq $body.state.absent) 'JSON file context preserves booleans, nulls and array shapes'
Assert-Decision ($body.questions.urgency.criteria -is [array] -and $body.questions.urgency.criteria.Count -eq 3) 'Questions files preserve score criteria arrays'
Push-Location -LiteralPath $jsonDirectory
try {
    Set-DecisionResponses @((New-DecisionResponse))
    $null = Invoke-DecisionModel -StatePath './state [literal].json' -QuestionsPath './questions [literal].json' -Pick -All -Quiet
    Assert-Decision ((& $module { $script:Requests.Count }) -eq 1 -and (& $module { $script:MenuOptions.Count }) -eq 6) 'Relative file aliases work with the model picker'
}
finally { Pop-Location }
Set-DecisionResponses @((New-DecisionResponse))
$null = Invoke-DecisionModel -State text -QuestionsFile $questionFile -Model test -Quiet
Assert-Decision (((& $module { $script:Requests[0].Json }) | ConvertFrom-Json).state -ceq 'text') 'Inline state can be combined with a questions file'
Set-DecisionResponses @((New-DecisionResponse))
$null = Invoke-DecisionModel -StateFile $stateFile -Questions $questions -Model test -Quiet
Assert-Decision ((& $module { $script:Requests.Count }) -eq 1) 'Inline questions can be combined with a state file'

foreach ($stateJson in '[]', '[{"active":false,"empty":[],"absent":null}]', '"hello"') {
    [IO.File]::WriteAllText($stateFile, $stateJson)
    Set-DecisionResponses @((New-DecisionResponse))
    $null = Invoke-DecisionModel -StateFile $stateFile -QuestionsFile $questionFile -Model test -Quiet
    $body = (& $module { $script:Requests[0].Json }) | ConvertFrom-Json
    if ($stateJson -ceq '[]') {
        Assert-Decision ($body.state -is [array] -and $body.state.Count -eq 0) 'Empty root state arrays remain arrays when loaded from JSON'
    }
    elseif ($stateJson.StartsWith('[')) {
        Assert-Decision ($body.state -is [array] -and $body.state.Count -eq 1 -and $body.state[0].active -ceq $false) 'Singleton root state arrays remain arrays when loaded from JSON'
    }
    else { Assert-Decision ($body.state -ceq 'hello') 'A quoted JSON string is accepted as file state' }
}

# Use the shipped examples through the same request path as user files.
$null = Copy-Item -LiteralPath (Join-Path $repo 'Examples/DecisionModels/questions.json') -Destination $questionFile -Force
$null = Copy-Item -LiteralPath (Join-Path $repo 'Examples/DecisionModels/state.json') -Destination $stateFile -Force
Set-DecisionResponses @((New-DecisionResponse))
$null = Invoke-DecisionModel -StateFile $stateFile -QuestionsFile $questionFile -Model test -Quiet
Assert-Decision ((& $module { $script:Requests.Count }) -eq 1) 'Shipped example files contain valid state and all three question types'

foreach ($preference in 'Continue', 'Stop') {
    & {
        $ErrorActionPreference = $preference
        foreach ($action in @(
            { Invoke-DecisionModel @basic -Model test -QuestionsFile $questionFile },
            { Invoke-DecisionModel @basic -Model test -StateFile $stateFile },
            { Invoke-DecisionModel -QuestionsFile $questionFile -Model test -Quiet },
            { Invoke-DecisionModel -StateFile $stateFile -Model test -Quiet }
        )) {
            Set-DecisionResponses @()
            $null = Assert-DecisionThrows $action '*Specify exactly one*'
            Assert-Decision ((& $module { $script:Requests.Count }) -eq 0) "Missing or conflicting file inputs fail before HTTP under $preference"
        }
        foreach ($path in (Join-Path $jsonDirectory 'missing.json'), $jsonDirectory) {
            Set-DecisionResponses @()
            $null = Assert-DecisionThrows { Invoke-DecisionModel -State text -QuestionsFile $path -Model test -Quiet } '*Cannot read QuestionsFile*'
            $null = Assert-DecisionThrows { Invoke-DecisionModel -StateFile $path -Questions $questions -Model test -Quiet } '*Cannot read StateFile*'
            Assert-Decision ((& $module { $script:Requests.Count }) -eq 0) "Missing paths and directory inputs fail before HTTP under $preference"
        }
        $invalidFile = Join-Path $jsonDirectory 'invalid.json'
        foreach ($json in '', ' ', '{"synthetic-secret":', '[]', '[{"q":{"type":"noul"}}]', 'null', 'true', '{}') {
            [IO.File]::WriteAllText($invalidFile, $json)
            Set-DecisionResponses @()
            $menuBefore = & $module { $script:MenuCount }
            $failure = Assert-DecisionThrows { Invoke-DecisionModel -State text -QuestionsFile $invalidFile -Pick -Quiet }
            Assert-Decision ($failure.Exception.Message -notmatch 'synthetic-secret' -and (& $module { $script:Requests.Count }) -eq 0 -and (& $module { $script:MenuCount }) -eq $menuBefore) "Invalid questions JSON fails before picker and HTTP without printing file contents under $preference"
        }
        foreach ($json in 'null', '42', 'false', '{"synthetic-secret":') {
            [IO.File]::WriteAllText($invalidFile, $json)
            Set-DecisionResponses @()
            $failure = Assert-DecisionThrows { Invoke-DecisionModel -StateFile $invalidFile -Questions $questions -Model test -Quiet }
            Assert-Decision ($failure.Exception.Message -notmatch 'synthetic-secret' -and (& $module { $script:Requests.Count }) -eq 0) "Invalid JSON state roots fail before HTTP under $preference"
        }
    }
}

$caseFile = Join-Path $jsonDirectory 'case-sensitive.json'
$caseJson = '{"Question":{"type":"noul","instructions":"First?","criteria":{"true":"Yes","false":"No"}},"question":{"type":"noul","instructions":"Second?","criteria":{"true":"Yes","false":"No"}}}'
[IO.File]::WriteAllText($caseFile, $caseJson)
Set-DecisionResponses @(@{ model = 'case-model'; usage = @{}; answers = $caseAnswers })
$result = Invoke-DecisionModel -State text -QuestionsFile $caseFile -Model test -Quiet
Assert-Decision ($result.Answers.Count -eq 2 -and $result.Answers['Question'].noul -eq 0.8 -and $result.Answers['question'].noul -eq 0.2) 'File parsing preserves question names that differ only by case'
$null = Assert-DecisionThrows { Invoke-DecisionModel -State text -QuestionsFile '' -Model test -Quiet }
#requires -Version 7.0
# Run with pwsh -NoProfile -File ./Tests/Invoke-DecisionModel.Tests.ps1
$ErrorActionPreference = 'Stop'
# Test dependencies must never auto-load a user-installed legacy module.
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('SpiDecisionTests-' + [guid]::NewGuid().ToString('N'))
$module = $null
$checks = 0
$previousTestKey = [Environment]::GetEnvironmentVariable('SPI_DECISION_TEST_KEY')

function Assert-Decision {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}

function Assert-DecisionThrows {
    param([scriptblock]$Action, [string]$Pattern = '*')
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert-Decision ($null -ne $failure -and $failure.Exception.Message -like $Pattern) "Expected error matching $Pattern"
    if ($failure) { $failure }
}

function New-DecisionResponse {
    @{
        id = 'decision-test'; model = 'served-snapshot'; provider = 'Synthetic provider'
        usage = @{ input_tokens = 40; output_tokens = 0; cost = 0.000001 }
        answers = @{
            route    = @{ type = 'choice'; choice = 'billing'; confidence = 0.73; probabilities = @{ billing = 0.8; other = 0.2 } }
            relevant = @{ type = 'noul'; noul = 0.91 }
            urgency  = @{ type = 'score'; score = 1.75; confidence = 0.9; probabilities = @{ '0' = 0.05; '1' = 0.15; '2' = 0.8 }; legend = @{ '0' = 'Low'; '1' = 'Medium'; '2' = 'High' } }
        }
    } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function New-DecisionFailure {
    param([int]$Status)
    $failure = [Exception]::new('synthetic-secret state-content')
    $failure.Data['Status'] = $Status
    $failure
}

function Set-DecisionResponses {
    param([object[]]$Responses)
    & $module {
        param($items)
        $script:Requests.Clear()
        $script:Delays.Clear()
        $script:Responses.Clear()
        $script:NonTerminating = $false
        $script:RawContent = $null
        foreach ($item in $items) { $script:Responses.Enqueue($item) }
    } $Responses
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
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $repo 'SpiAgentHarness.psd1')
    $fixtureManifest = Join-Path $fixture 'SpiAgentHarness.psd1'
    Assert-Decision ($manifest.FormatsToProcess -contains 'SpiAgentHarness.Format.ps1xml') 'Manifest loads the decision result format file'

    foreach ($directory in 'Public', 'Private') {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $fixture $directory) -Filter '*.ps1' -Recurse) {
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert-Decision ($errors.Count -eq 0) "Parse $($file.Name)"
        }
    }
    $module = Import-Module $fixtureManifest -PassThru -Force
    foreach ($command in 'Invoke-DecisionModel', 'Get-DecisionModels') {
        Assert-Decision ($module.ExportedFunctions.ContainsKey($command)) "Manifest exports $command"
        $line = "$command -Provider Open"
        Assert-Decision ((TabExpansion2 $line $line.Length).CompletionMatches.CompletionText -contains 'OpenRouter') "$command completes decision providers"
        $line = "$command -Provider Ki"
        Assert-Decision ((TabExpansion2 $line $line.Length).CompletionMatches.CompletionText -notcontains 'Kilo') "$command excludes chat-only providers from completion"
    }
    Assert-Decision (-not $module.ExportedFunctions.ContainsKey('Invoke-DecisionModelRequest')) 'Request helper stays private'
    $line = 'Invoke-DecisionModel -Model typesafe/'
    Assert-Decision ((TabExpansion2 $line $line.Length).CompletionMatches.CompletionText -contains 'typesafe/jev-1.14') 'Model IDs complete without network access'
    Assert-Decision ((& $module { $script:FreeModelProviders['OpenRouter'].DecisionUri }) -eq 'https://openrouter.ai/api/alpha/decisions') 'OpenRouter registers its Decisions endpoint'
    & $module {
        $script:FreeModelProviders['OpenRouter'].KeyEnvVar = 'SPI_DECISION_TEST_KEY'
        $script:Requests = [Collections.Generic.List[object]]::new()
        $script:Delays = [Collections.Generic.List[int]]::new()
        $script:Responses = [Collections.Generic.Queue[object]]::new()
        $script:MenuIndex = 0
        $script:MenuCount = 0
        $script:MenuOptions = @()
        $script:NonTerminating = $false
        function script:Invoke-WebRequest {
            [CmdletBinding()]
            param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
            $script:Requests.Add([pscustomobject]@{ Uri = $Uri; Headers = $Headers; Json = $Body; ContentType = $ContentType; TimeoutSec = $TimeoutSec; Method = $Method })
            if ($script:NonTerminating) { Write-Error 'synthetic-secret state-content'; return }
            if ($null -ne $script:RawContent) { return [pscustomobject]@{ Content = $script:RawContent } }
            if (-not $script:Responses.Count) { throw 'Unexpected network request in decision tests.' }
            $next = $script:Responses.Dequeue()
            if ($next -is [Exception]) { throw $next }
            [pscustomobject]@{ Content = (ConvertTo-Json -InputObject $next -Depth 100 -Compress) }
        }
        function script:Start-Sleep { param([int]$Seconds) $script:Delays.Add($Seconds) }
        function script:Show-InteractiveMenu {
            param($Options, $Title)
            $script:MenuCount++
            $script:MenuOptions = $Options
            if ($script:MenuIndex -eq -1) { return $null }
            if ($script:MenuIndex -eq -2) { return 'invalid selection' }
            $Options[$script:MenuIndex]
        }
    }
    [Environment]::SetEnvironmentVariable('SPI_DECISION_TEST_KEY', 'synthetic-secret')
    $all = @(Get-DecisionModels -All)
    $expectedIds = @('perplexity/pplx-decider-flash-v1.2', 'liquid/d1-ultra', 'typesafe/jev-1.14', 'cloudflare/clef-omni', 'openai/gpt-6-luna-decisions', 'inception/mercury-decide:free')
    Assert-Decision ($all.Count -eq 6 -and ($all.Id -join ',') -ceq ($expectedIds -join ',')) 'Bundled catalogue contains all six supplied IDs'
    Assert-Decision (@(Get-DecisionModels).Count -eq 1 -and (Get-DecisionModels).Id -eq $expectedIds[-1]) 'Default catalogue lists only the free variant'
    Assert-Decision ((Get-DecisionModels -All -Name '*Jev*').Id -eq 'typesafe/jev-1.14') 'Catalogue filters by display name'
    Assert-Decision (@(Get-DecisionModels -All -Provider Kilo).Count -eq 0) 'Chat providers do not inherit decision models'
    Assert-Decision ((& $module { $script:Requests.Count }) -eq 0) 'Listing makes no HTTP requests'

    $questions = [ordered]@{
        route    = @{ type = 'choice'; instructions = 'Which team?'; criteria = @{ billing = 'Payments'; other = 'Other issues' } }
        relevant = @{ type = 'noul'; instructions = 'Is this relevant?'; criteria = @{ 'true' = 'Relevant'; 'false' = 'Irrelevant' } }
        urgency  = @{ type = 'score'; instructions = 'How urgent?'; criteria = @('Low', 'Medium', 'High') }
    }
    $basic = @{ State = 'state-content'; Questions = $questions; Quiet = $true }
    foreach ($id in $expectedIds + 'future/decision-model') {
        Set-DecisionResponses @((New-DecisionResponse))
        $result = Invoke-DecisionModel @basic -Model $id
        $request = & $module { $script:Requests[0] }
        $body = ConvertFrom-Json -InputObject $request.Json
        Assert-Decision ($body.model -ceq $id -and $request.Method -eq 'Post' -and $request.Uri -eq 'https://openrouter.ai/api/alpha/decisions') 'Each model ID uses the Decisions endpoint'
        Assert-Decision ($request.Headers.Authorization -ceq 'Bearer synthetic-secret' -and $request.TimeoutSec -eq 120 -and $request.ContentType -eq 'application/json; charset=utf-8') 'Requests use configured authentication, UTF-8 and timeout'
        Assert-Decision ($result.Answers.urgency.score -eq 1.75 -and $result.Answers.relevant.noul -eq 0.91 -and $result.Answers.route.probabilities.billing -eq 0.8) 'Answers preserve scores and probabilities without thresholds'
        Assert-Decision ($result.Answers.route.confidence -eq 0.73 -and $result.Answers.urgency.legend.'2' -eq 'High') 'Confidence and legend are preserved independently of option probabilities'
        Assert-Decision ($result.RequestedModel -ceq $id -and $result.Model -eq 'served-snapshot' -and $result.Provider -eq 'OpenRouter' -and $result.ServedBy -eq 'Synthetic provider') 'Result distinguishes requested model, served snapshot and upstream provider'
        Assert-Decision ($result.Id -eq 'decision-test' -and $result.Usage.cost -eq 0.000001 -and $result.ElapsedMilliseconds -ge 0 -and $result.RawResponse.answers.route.choice -eq 'billing') 'Result preserves usage, ID, timing and raw response'
    }

    $states = @(
        @{ empty = @(); single = @(1); nested = @{ enabled = $false; absent = $null }; unicode = 'नमस्ते' },
        @(),
        @(@{ only = $true }),
        @('one', 'two'),
        ''
    )
    foreach ($state in $states) {
        Set-DecisionResponses @((New-DecisionResponse))
        $null = Invoke-DecisionModel -State $state -Questions $questions -Model test -Quiet
        $body = (& $module { $script:Requests[0].Json }) | ConvertFrom-Json
        if ($state -is [Collections.IDictionary]) {
            Assert-Decision ($body.state.empty -is [array] -and $body.state.empty.Count -eq 0 -and $body.state.single -is [array] -and $body.state.single.Count -eq 1) 'Nested empty and singleton arrays remain arrays'
            Assert-Decision ($body.state.nested.enabled -ceq $false -and $null -eq $body.state.nested.absent -and $body.state.unicode -ceq 'नमस्ते') 'Boolean, null and Unicode context survive JSON serialization'
        }
        elseif ($state -is [array]) {
            Assert-Decision ($body.state -is [array] -and $body.state.Count -eq $state.Count) 'Root context arrays preserve their shape'
        }
        else { Assert-Decision ($body.state -ceq '') 'Empty text state is preserved' }
        Assert-Decision ($body.questions.urgency.criteria -is [array] -and $body.questions.urgency.criteria.Count -eq 3) 'Score criteria remain an ordered array'
    }
    Set-DecisionResponses @((New-DecisionResponse))
    $jsonQuestions = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $questions -Depth 10)
    $null = Invoke-DecisionModel -State ([pscustomobject]@{ ticket = 'hello' }) -Questions $jsonQuestions -Model test -Quiet
    Assert-Decision ((& $module { $script:Requests.Count }) -eq 1) 'PSCustomObject questions and state are accepted'

    Set-DecisionResponses @((New-DecisionResponse))
    $null = Invoke-DecisionModel @basic -Pick
    Assert-Decision ((& $module { $script:MenuOptions.Count }) -eq 1 -and ((& $module { $script:Requests[0].Json }) | ConvertFrom-Json).model -eq $expectedIds[-1]) 'Picker defaults to the free variant'
    Set-DecisionResponses @((New-DecisionResponse))
    $null = Invoke-DecisionModel @basic -Pick -All -ModelFilter '*Jev*'
    Assert-Decision ((& $module { $script:MenuOptions.Count }) -eq 1 -and ((& $module { $script:Requests[0].Json }) | ConvertFrom-Json).model -eq 'typesafe/jev-1.14') 'Picker includes paid models with All and applies filters'
    Set-DecisionResponses @((New-DecisionResponse))
    $null = Invoke-DecisionModel @basic -Pick -All
    Assert-Decision ((& $module { $script:MenuOptions.Count }) -eq 6) 'All six models are available in the full picker'
    foreach ($index in -1, -2) {
        Set-DecisionResponses @()
        & $module { param($value) $script:MenuIndex = $value } $index
        $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Pick } '*selection*'
        Assert-Decision ((& $module { $script:Requests.Count }) -eq 0) 'Cancelled or invalid picker selection makes no request'
    }
    & $module { $script:MenuIndex = 0 }
    $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Pick -ModelFilter '*missing*' } '*No bundled decision models*'

    $invalidQuestions = @(
        $null, @(), @(1), @{}, '[]',
        @{ bad = @() },
        @{ bad = @{ type = 'chat'; instructions = 'x'; criteria = @{} } },
        @{ bad = @{ type = 'choice'; instructions = ''; criteria = @{ a = 'A' } } },
        @{ bad = @{ type = 'choice'; instructions = 'x'; criteria = @() } },
        @{ bad = @{ type = 'choice'; instructions = 'x'; criteria = @{ a = $null } } },
        @{ bad = @{ type = 'choice'; instructions = 'x'; criteria = @{ 1 = 'bad key' } } },
        @{ bad = @{ type = 'noul'; instructions = 'x'; criteria = @{ yes = 'Yes'; no = 'No' } } },
        @{ bad = @{ type = 'score'; instructions = 'x'; criteria = @{} } },
        @{ bad = @{ type = 'score'; instructions = 'x'; criteria = @() } },
        @{ bad = @{ type = 'score'; instructions = 'x'; criteria = @('Low', $null) } }
    )
    foreach ($preference in 'Continue', 'Stop') {
        & {
            $ErrorActionPreference = $preference
            foreach ($invalid in $invalidQuestions) {
                Set-DecisionResponses @()
                $null = Assert-DecisionThrows { Invoke-DecisionModel -State text -Questions $invalid -Model test -Quiet }
                Assert-Decision ((& $module { $script:Requests.Count }) -eq 0) "Invalid questions fail before HTTP under $preference"
            }
            foreach ($invalid in $null, 42, $true) {
                $null = Assert-DecisionThrows { Invoke-DecisionModel -State $invalid -Questions $questions -Model test -Quiet }
            }
            $null = Assert-DecisionThrows { Invoke-DecisionModel @basic } '*Specify -Model*'
            $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test -Provider Kilo } '*no Decisions endpoint*'
            $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test -DecisionUri 'http://provider.invalid' } '*HTTPS*'
            $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test -DecisionUri 'https://name:password@provider.invalid' } '*HTTPS*'
            Set-DecisionResponses @()
            & $module { $script:NonTerminating = $true }
            $failure = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test } '*HTTP 0*'
            Assert-Decision ($failure.Exception.Message -notmatch 'synthetic-secret|state-content' -and (& $module { $script:Requests.Count }) -eq 1) "Nonterminating HTTP errors are caught and sanitized under $preference"
        }
    }
    [Environment]::SetEnvironmentVariable('SPI_DECISION_TEST_KEY', $null)
    Set-DecisionResponses @()
    $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test } '*SPI_DECISION_TEST_KEY*'
    Assert-Decision ((& $module { $script:Requests.Count }) -eq 0) 'Missing credentials fail before HTTP'
    Set-DecisionResponses @((New-DecisionResponse))
    $null = Invoke-DecisionModel @basic -Model test -ApiKey 'synthetic-override' -DecisionUri 'https://provider.invalid/decisions' -TimeoutSec 7
    $request = & $module { $script:Requests[0] }
    Assert-Decision ($request.Headers.Authorization -eq 'Bearer synthetic-override' -and $request.Uri -eq 'https://provider.invalid/decisions' -and $request.TimeoutSec -eq 7) 'Explicit credentials, URI and timeout override registry configuration'
    Register-FreeModelProvider -Name DecisionTest -Uri 'https://provider.invalid/models' -DecisionUri 'https://provider.invalid/judge' -KeyEnvVar SPI_DECISION_TEST_KEY
    [Environment]::SetEnvironmentVariable('SPI_DECISION_TEST_KEY', 'synthetic-secret')
    Set-DecisionResponses @((New-DecisionResponse))
    $result = Invoke-DecisionModel @basic -Model custom/judge -Provider DecisionTest
    Assert-Decision ($result.Provider -eq 'DecisionTest' -and (& $module { $script:Requests[0].Uri }) -eq 'https://provider.invalid/judge') 'Custom providers reuse registered decision endpoint and credential configuration'

    foreach ($status in 400, 401, 402, 403, 404, 413) {
        Set-DecisionResponses @((New-DecisionFailure $status))
        $failure = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model fixed } "*HTTP $status*"
        Assert-Decision ($failure.Exception.Data['Status'] -eq $status -and (& $module { $script:Requests.Count }) -eq 1 -and (& $module { $script:Delays.Count }) -eq 0) 'Permanent errors retain status and do not retry'
        Assert-Decision ($failure.Exception.Message -notmatch 'synthetic-secret|state-content') 'Provider error bodies do not leak through exception messages'
    }
    Set-DecisionResponses @((New-DecisionFailure 429), (New-DecisionFailure 503), (New-DecisionResponse))
    $result = Invoke-DecisionModel @basic -Model fixed
    Assert-Decision ($result.Model -eq 'served-snapshot' -and ((& $module { $script:Delays.ToArray() }) -join ',') -eq '2,4') 'Transient failures retry with bounded exponential delays'
    Assert-Decision ((@(& $module { $script:Requests.ToArray() }) | Where-Object { ($_.Json | ConvertFrom-Json).model -cne 'fixed' }).Count -eq 0) 'Retries keep the requested model fixed'
    Set-DecisionResponses @((New-DecisionFailure 503), (New-DecisionFailure 503), (New-DecisionFailure 503), (New-DecisionFailure 503))
    $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model fixed } '*HTTP 503*'
    Assert-Decision ((& $module { $script:Requests.Count }) -eq 4 -and (& $module { $script:Delays.Count }) -eq 3) 'Default retries stop after four attempts'
    Set-DecisionResponses @((New-DecisionFailure 429))
    $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model fixed -MaxRetries 0 } '*HTTP 429*'
    Assert-Decision ((& $module { $script:Requests.Count }) -eq 1) 'MaxRetries zero sends exactly one attempt'
    $embedded = [pscustomobject]@{ error = [pscustomobject]@{ code = 502; message = 'synthetic-secret state-content' } }
    Set-DecisionResponses @($embedded, (New-DecisionResponse))
    $null = Invoke-DecisionModel @basic -Model fixed
    Assert-Decision ((& $module { $script:Requests.Count }) -eq 2) 'HTTP 200 API error objects participate in retries'
    $httpResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::TooManyRequests)
    $httpResponse.Headers.RetryAfter = [Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]::FromSeconds(80))
    $httpError = [Microsoft.PowerShell.Commands.HttpResponseException]::new('synthetic-secret', $httpResponse)
    Set-DecisionResponses @($httpError, (New-DecisionResponse))
    $null = Invoke-DecisionModel @basic -Model fixed
    Assert-Decision ((& $module { $script:Delays[0] }) -eq 30) 'Retry-After is honored with a thirty second cap'

    $mutations = @(
        { param($r) $r.model = '' },
        { param($r) $r.usage = @() },
        { param($r) $r.answers = @() },
        { param($r) $r.answers.PSObject.Properties.Remove('route') },
        { param($r) $r.answers | Add-Member extra @{ type = 'noul'; noul = 0.5 } },
        { param($r) $r.answers.route.type = 'noul' },
        { param($r) $r.answers.route.choice = 'unknown' },
        { param($r) $r.answers.route.confidence = 2 },
        { param($r) $r.answers.relevant.noul = $true },
        { param($r) $r.answers.relevant.noul = '0.9' },
        { param($r) $r.answers.relevant.noul = [double]::NaN },
        { param($r) $r.answers.urgency.score = [double]::PositiveInfinity },
        { param($r) $r.answers.urgency.score = -0.5 },
        { param($r) $r.answers.route.probabilities.billing = 1.2 },
        { param($r) $r.answers.route.probabilities.PSObject.Properties.Remove('other') }
    )
    foreach ($mutate in $mutations) {
        $response = New-DecisionResponse
        & $mutate $response
        Set-DecisionResponses @($response)
        $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test }
        Assert-Decision ((& $module { $script:Requests.Count }) -eq 1) 'Malformed responses fail without retrying'
    }
    foreach ($response in $null, @(), 'chat reply') {
        Set-DecisionResponses @($response)
        $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test }
    }

    foreach ($content in '<html>synthetic-secret</html>', '{broken json', '[{"model":"unexpected"}]') {
        Set-DecisionResponses @()
        & $module { param($text) $script:RawContent = $text } $content
        $failure = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test } '*HTTP 0*'
        Assert-Decision ($failure.Exception.Message -notmatch 'synthetic-secret' -and (& $module { $script:Requests.Count }) -eq 1) 'Invalid JSON and singleton array responses fail without leaking bodies or retrying'
    }

    # Labels differing only by case must not be collapsed by PowerShell maps.
    $criteria = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $criteria.Add('A', 'First'); $criteria.Add('a', 'Second')
    $caseQuestions = @{ label = @{ type = 'choice'; instructions = 'Choose a label'; criteria = $criteria } }
    $probabilities = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $probabilities.Add('A', 0.7); $probabilities.Add('a', 0.3)
    $caseResponse = @{ model = 'case-model'; usage = @{}; answers = @{ label = @{ type = 'choice'; choice = 'A'; probabilities = $probabilities } } }
    Set-DecisionResponses @($caseResponse)
    $caseResult = Invoke-DecisionModel -State text -Questions $caseQuestions -Model test -Quiet
    Assert-Decision ($caseResult.Answers.label.probabilities.Count -eq 2 -and $caseResult.Answers.label.probabilities['A'] -eq 0.7) 'Case-sensitive choice labels remain distinct'
    Assert-Decision ((& $module { $script:Requests[0].Json }) -cmatch '"A":"First"' -and (& $module { $script:Requests[0].Json }) -cmatch '"a":"Second"') 'Case-sensitive labels serialize distinctly'

    $caseNames = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $caseNames.Add('Question', @{ type = 'noul'; instructions = 'First?'; criteria = @{ 'true' = 'Yes'; 'false' = 'No' } })
    $caseNames.Add('question', @{ type = 'noul'; instructions = 'Second?'; criteria = @{ 'true' = 'Yes'; 'false' = 'No' } })
    $caseAnswers = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $caseAnswers.Add('Question', @{ type = 'noul'; noul = 0.8 })
    $caseAnswers.Add('question', @{ type = 'noul'; noul = 0.2 })
    Set-DecisionResponses @(@{ model = 'case-model'; usage = @{}; answers = $caseAnswers })
    $caseResult = Invoke-DecisionModel -State text -Questions $caseNames -Model test -Quiet
    Assert-Decision ($caseResult.Answers.Count -eq 2 -and $caseResult.Answers['Question'].noul -eq 0.8 -and $caseResult.Answers['question'].noul -eq 0.2) 'Case-sensitive question names survive the complete HTTP parsing path'

    Set-DecisionResponses @((New-DecisionResponse))
    $trace = @(Invoke-DecisionModel -State state-content -Questions $questions -Model test 6>&1)
    $information = @($trace | Where-Object { $_ -is [Management.Automation.InformationRecord] })
    $results = @($trace | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })
    Assert-Decision ($information.Count -eq 2 -and $results.Count -eq 1 -and ($information -join ' ') -notmatch 'synthetic-secret|state-content|Which team') 'Trace contains metadata and leaves one result on the success stream'
    Set-DecisionResponses @((New-DecisionResponse))
    $quietTrace = @(Invoke-DecisionModel @basic -Model test 6>&1)
    Assert-Decision ($quietTrace.Count -eq 1 -and $quietTrace[0].Model -eq 'served-snapshot') 'Quiet suppresses trace and retains the structured result'

    # Synthetic image bytes only; the requests go to the mocked transport.
    $pngBytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
    $attachmentPath = Join-Path $fixture 'receipt [1].PNG'
    [IO.File]::WriteAllBytes($attachmentPath, $pngBytes)
    $textAttachment = Join-Path $fixture 'notes.txt'
    [IO.File]::WriteAllText($textAttachment, 'not an image')
    Set-DecisionResponses @((New-DecisionResponse))
    $null = Invoke-DecisionModel -State 'Is this a refund?' -Questions $questions -Model test -Attachment $attachmentPath -Quiet
    $imageBody = (& $module { $script:Requests[0].Json }) | ConvertFrom-Json
    Assert-Decision ($imageBody.state -is [array] -and $imageBody.state.Count -eq 2) 'Attachments turn state into an ordered content array'
    Assert-Decision ($imageBody.state[0].type -ceq 'text' -and $imageBody.state[0].text -ceq 'Is this a refund?') 'Text state is the first content part'
    Assert-Decision ($imageBody.state[1].type -ceq 'image_url' -and $imageBody.state[1].image_url.url -ceq ('data:image/png;base64,' + [Convert]::ToBase64String($pngBytes))) 'Image attachment is sent as an exact PNG data URL'
    Set-DecisionResponses @((New-DecisionResponse))
    $null = Invoke-DecisionModel -State ([pscustomobject]@{ ticket = 'json' }) -Questions $questions -Model test -Attachment $attachmentPath, $attachmentPath -Quiet
    $multiBody = (& $module { $script:Requests[0].Json }) | ConvertFrom-Json
    Assert-Decision ($multiBody.state[0].text -ceq '{"ticket":"json"}' -and $multiBody.state.Count -eq 3 -and $multiBody.state[2].type -ceq 'image_url') 'Structured state is serialized as text before ordered images'
    Set-DecisionResponses @((New-DecisionResponse))
    $null = Invoke-DecisionModel @basic -Model test -Attachment @()
    Assert-Decision ((& $module { $script:Requests[0].Json }) -cmatch '"state":"state-content"') 'An empty attachment array keeps the plain-text state'
    Set-DecisionResponses @()
    $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test -Attachment 'missing.png' } '*Cannot read Attachment*'
    $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test -Attachment $textAttachment } '*PNG, JPEG, GIF or WebP*'
    $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test -Attachment $fixture } '*Cannot read Attachment*'
    $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test -Attachment ' ' } '*cannot be blank*'
    Assert-Decision ((& $module { $script:Requests.Count }) -eq 0) 'Invalid attachments make no decision request'

    . (Join-Path $PSScriptRoot 'DecisionModel.JsonFiles.Tests.ps1')
    . (Join-Path $PSScriptRoot 'DecisionModel.Output.Tests.ps1')
    . (Join-Path $PSScriptRoot 'DecisionModel.Protocols.Tests.ps1')

    Write-Host "Passed $checks decision checks. Synthetic requests only; isolated module fixture."
}

finally {
    [Environment]::SetEnvironmentVariable('SPI_DECISION_TEST_KEY', $previousTestKey)
    if ($module) { Remove-Module $module -Force }
    if (Test-Path -LiteralPath $fixture) {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixture).ProviderPath
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolvedFixture -Leaf) -notlike 'SpiDecisionTests-*') {
            throw 'Refusing cleanup outside the decision test fixture.'
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
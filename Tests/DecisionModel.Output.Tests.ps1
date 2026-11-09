# Run by Invoke-DecisionModel.Tests.ps1 with its isolated module and HTTP mocks.
Set-DecisionResponses @((New-DecisionResponse))
$result = Invoke-DecisionModel @basic -Model test
Assert-Decision ($result.PSObject.TypeNames[0] -ceq 'SpiAgentHarness.DecisionModelResult') 'Result carries a type name for its default view'
$summary = @($result.Summary)
Assert-Decision ($summary.Count -eq 3 -and ($summary.Question -join ',') -ceq 'route,relevant,urgency') 'Summary has one row per question in question order'
Assert-Decision ($summary[0].PSObject.TypeNames[0] -ceq 'SpiAgentHarness.DecisionModelAnswer' -and $summary[0].Type -ceq 'choice' -and $summary[0].Answer -ceq 'billing' -and $summary[0].Confidence -eq 0.73) 'Choice rows expose answer and confidence'
Assert-Decision ((($summary[0].Probabilities -split ', ') | Sort-Object) -join ',' -ceq 'billing=0.8,other=0.2') 'Choice probabilities are flattened'
Assert-Decision ($summary[1].Answer -eq 0.91 -and $null -eq $summary[1].Confidence -and $null -eq $summary[1].Probabilities) 'Noul rows expose the yes probability without inventing other fields'
Assert-Decision ($summary[2].Answer -eq 1.75 -and $summary[2].Probabilities -ceq '0=0.05, 1=0.15, 2=0.8') 'Score rows expose the fractional score and ordered probabilities'
Assert-Decision ($result.Answers.route.choice -ceq 'billing' -and $result.RawResponse.answers.route.choice -ceq 'billing') 'Native answers and raw response remain available'

$display = ($result | Out-String -Width 200)
Assert-Decision ($display -match 'Model: served-snapshot \(requested test\)' -and $display -match 'Synthetic provider') 'Default view shows a model header'
Assert-Decision ($display -match '(?m)^Question\s+Type\s+Answer\s+Confidence\s+Probabilities' -and $display -match 'route\s+choice\s+billing\s+0\.73\s+\S+=0\.[28], \S+=0\.[28]') 'Default view shows one table row per question'
Assert-Decision ($display -notmatch 'RawResponse|System\.Collections') 'Default view hides raw response and nested collection type names'
$culture = [Globalization.CultureInfo]::CurrentCulture
try {
    [Globalization.CultureInfo]::CurrentCulture = 'de-DE'
    Set-DecisionResponses @((New-DecisionResponse))
    $german = Invoke-DecisionModel @basic -Model test
    Assert-Decision ($german.Summary[2].Probabilities -ceq '0=0.05, 1=0.15, 2=0.8') 'Summary probabilities use invariant number formatting'
}
finally { [Globalization.CultureInfo]::CurrentCulture = $culture }

$outDirectory = Join-Path $fixture 'output [literal]'
$null = New-Item -ItemType Directory -Path $outDirectory
$outFile = Join-Path $outDirectory 'result [1].json'
Set-DecisionResponses @((New-DecisionResponse))
$saved = Invoke-DecisionModel @basic -Model test -OutFile $outFile
$text = [IO.File]::ReadAllText($outFile)
$json = $text | ConvertFrom-Json -AsHashtable
Assert-Decision ($saved.Model -ceq 'served-snapshot' -and @($saved.Summary).Count -eq 3) 'OutFile still returns the structured result'
Assert-Decision ($json.Answers.route.probabilities.billing -eq 0.8 -and $json.Answers.urgency.legend.'2' -ceq 'High' -and $json.Usage.cost -eq 0.000001) 'Saved JSON preserves answers, legends and usage'
Assert-Decision ($json.RequestedModel -ceq 'test' -and $json.Model -ceq 'served-snapshot' -and $json.Provider -ceq 'OpenRouter' -and $json.ServedBy -ceq 'Synthetic provider' -and $json.Id -ceq 'decision-test' -and $json.SavedAt) 'Saved JSON includes request metadata and a timestamp'
Assert-Decision (-not $json.Contains('RawResponse') -and -not $json.Contains('Summary') -and $text -notmatch 'synthetic-secret|state-content|Which team') 'Saved JSON omits raw response, summary, credentials, state and questions'
$bytes = [IO.File]::ReadAllBytes($outFile)
Assert-Decision (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'Saved JSON is UTF-8 without a BOM'
# Ordered criteria (as loaded from JSON files) set the probability order of choice rows.
$ordered = [ordered]@{ route = [ordered]@{ type = 'choice'; instructions = 'Which team?'; criteria = [ordered]@{ other = 'Other issues'; billing = 'Payments' } } }
Set-DecisionResponses @(@{ model = 'm'; usage = @{}; answers = @{ route = @{ type = 'choice'; choice = 'other'; probabilities = @{ billing = 0.25; other = 0.75 } } } })
$orderedResult = Invoke-DecisionModel -State text -Questions $ordered -Model test -Quiet
Assert-Decision ($orderedResult.Summary[0].Probabilities -ceq 'other=0.75, billing=0.25') 'Choice probabilities follow question criteria order'

Push-Location -LiteralPath $outDirectory
try {
    Set-DecisionResponses @((New-DecisionResponse))
    $null = Invoke-DecisionModel @basic -Model test -OutFile './relative.json'
    Assert-Decision (Test-Path -LiteralPath (Join-Path $outDirectory 'relative.json')) 'Relative OutFile paths resolve against the current location'
}
finally { Pop-Location }
Set-DecisionResponses @((New-DecisionResponse))
$null = Invoke-DecisionModel @basic -Model test -OutFile $outFile
Assert-Decision (([IO.File]::ReadAllText($outFile) | ConvertFrom-Json).Model -ceq 'served-snapshot') 'OutFile overwrites an existing file'

foreach ($preference in 'Continue', 'Stop') {
    & {
        $ErrorActionPreference = $preference
        foreach ($path in (Join-Path $outDirectory 'missing/result.json'), $outDirectory, 'Env:/SPI_DECISION_OUT') {
            Set-DecisionResponses @()
            $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test -OutFile $path } '*Cannot use OutFile*'
            Assert-Decision ((& $module { $script:Requests.Count }) -eq 0) "Invalid OutFile paths fail before HTTP under $preference"
        }
        $null = Assert-DecisionThrows { Invoke-DecisionModel @basic -Model test -OutFile '' }
    }
}

# A write failure after a successful (possibly paid) request warns and still returns the result.
$lockedFile = Join-Path $outDirectory 'locked.json'
$lock = [IO.File]::Open($lockedFile, 'Create', 'ReadWrite', 'None')
try {
    Set-DecisionResponses @((New-DecisionResponse))
    $warnings = $null
    $kept = Invoke-DecisionModel @basic -Model test -OutFile $lockedFile -WarningVariable warnings -WarningAction SilentlyContinue
    Assert-Decision ($kept.Model -ceq 'served-snapshot' -and @($warnings).Count -eq 1 -and "$warnings" -like '*Cannot write OutFile*') 'Write failures warn and keep the result'
}
finally { $lock.Dispose() }
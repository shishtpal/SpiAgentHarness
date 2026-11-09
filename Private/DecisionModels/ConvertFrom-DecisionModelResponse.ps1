function ConvertFrom-DecisionModelResponse {
    param(
        [AllowNull()][object]$Response, [Collections.IDictionary]$Questions,
        [string]$RequestedModel, [string]$Provider, [double]$ElapsedMilliseconds,
        [switch]$AllowMissingProbabilities, [switch]$AllowRefusal
    )

    $root = ConvertTo-DecisionModelMap -Value $Response -Name 'Decisions response'
    if ($root['model'] -isnot [string] -or [string]::IsNullOrWhiteSpace($root['model'])) {
        throw 'Decisions response contained no served model ID.'
    }
    $null = ConvertTo-DecisionModelMap -Value $root['usage'] -Name 'Decisions response usage'
    $answers = ConvertTo-DecisionModelMap -Value $root['answers'] -Name 'Decisions response answers'
    if ($answers.Count -ne $Questions.Count) { throw 'Decisions response did not answer exactly the requested questions.' }
    foreach ($name in $Questions.Keys) {
        if (-not $answers.Contains($name)) { throw 'Decisions response is missing a requested answer.' }
        $question = ConvertTo-DecisionModelMap -Value $Questions[$name]
        $answer = ConvertTo-DecisionModelMap -Value $answers[$name] -Name 'Decision answer'
        if ($AllowRefusal -and $answer['type'] -ceq 'refusal') { continue }
        if ($answer['type'] -cne $question['type']) { throw 'Decisions response answer type does not match the question.' }
        if ($answer.Contains('confidence') -and -not (Test-DecisionModelNumber $answer['confidence'] -Probability)) {
            throw 'Decisions response confidence must be a number between zero and one.'
        }
        if ($question['type'] -ceq 'noul') {
            if (-not (Test-DecisionModelNumber $answer['noul'] -Probability)) {
                throw 'Decisions response noul must be a number between zero and one.'
            }
            continue
        }
        if ($question['type'] -ceq 'choice') {
            $criteria = ConvertTo-DecisionModelMap -Value $question['criteria']
            $labels = @($criteria.Keys)
            if ($answer['choice'] -isnot [string] -or -not $criteria.Contains($answer['choice'])) {
                throw 'Decisions response choice is outside the allowed criteria.'
            }
        }
        else {
            $labels = @(for ($i = 0; $i -lt $question['criteria'].Count; $i++) { [string]$i })
            if (-not (Test-DecisionModelNumber $answer['score']) -or
                $answer['score'] -lt 0 -or $answer['score'] -gt ($labels.Count - 1)) {
                throw 'Decisions response score is outside the ordered rubric.'
            }
        }
        if ($AllowMissingProbabilities -and $null -eq $answer['probabilities']) { continue }
        $probabilities = ConvertTo-DecisionModelMap -Value $answer['probabilities'] -Name 'Decision probabilities'
        if ($probabilities.Count -ne $labels.Count) { throw 'Decisions response probabilities do not match the criteria.' }
        foreach ($label in $labels) {
            if (-not $probabilities.Contains($label) -or -not (Test-DecisionModelNumber $probabilities[$label] -Probability)) {
                throw 'Decisions response requires a probability between zero and one for every criterion.'
            }
        }
        if ($AllowMissingProbabilities) {
            $total = 0.0
            foreach ($probability in $probabilities.Values) { $total += [double]$probability }
            if ([Math]::Abs($total - 1.0) -gt 0.01) { throw 'Decision probabilities must sum to one within rounding tolerance.' }
        }
    }
    [pscustomobject]@{
        PSTypeName          = 'SpiAgentHarness.DecisionModelResult'
        Answers             = $root['answers']
        Summary             = @(ConvertTo-DecisionModelSummary -Answers $answers -Questions $Questions)
        RequestedModel      = $RequestedModel
        Model               = $root['model']
        Provider            = $Provider
        ServedBy            = $root['provider']
        Id                  = $root['id']
        Usage               = $root['usage']
        ElapsedMilliseconds = $ElapsedMilliseconds
        RawResponse         = $Response
    }
}
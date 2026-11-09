function Invoke-AgentHarnessMenu {
    param([hashtable]$Arguments, [hashtable]$Context)

    $isBatch = $Arguments.ContainsKey('questions')
    if ($isBatch) {
        foreach ($key in 'title', 'options', 'multi_select') {
            if ($Arguments.ContainsKey($key)) { throw 'Use questions or top-level title/options/multi_select, not both.' }
        }
        if ($Arguments.questions -isnot [array] -or $Arguments.questions.Count -eq 0) {
            throw 'questions must be a nonempty array of question objects.'
        }
        $questions = $Arguments.questions
        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($question in $questions) {
            if ($question -isnot [hashtable]) { throw 'Each question must be a JSON object.' }
            if ($question.id -isnot [string] -or [string]::IsNullOrWhiteSpace($question.id) -or -not $ids.Add($question.id)) {
                throw 'Each question id must be a distinct, nonblank string.'
            }
        }
    }
    else {
        $questions = @($Arguments)
    }

    # Validate the entire batch before asking the user anything.
    foreach ($question in $questions) {
        Assert-AgentHarnessMenuQuestion -Question $question
    }

    $answers = [Collections.Generic.List[object]]::new()
    $cancelled = $false
    foreach ($question in $questions) {
        if (-not $Context.NoPromptSound) {
            try { Invoke-Sound }
            catch { } # Audio must not prevent the user from choosing.
        }
        $selection = @(Show-InteractiveMenu -Options $question.options -Title $question.title `
                -MultiSelect:($question.multi_select -eq $true) -Filter -ErrorAction Stop 2>&1)

        # An external menu can explicitly write a nonterminating error. Stop the batch too.
        $menuError = $selection | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | Select-Object -First 1
        if ($menuError) { throw $menuError }

        # PowerShell can emit a null item on Escape; always return a JSON array.
        $selections = @($selection | Where-Object { $null -ne $_ })
        $cancelled = $selections.Count -eq 0
        $answer = @{ cancelled = $cancelled; selections = $selections }
        Write-AgentHarnessPromptHistory -Context $Context -Type 'menu_answer' -Text '' -Data @{
            id = $question.id; title = $question.title; selections = $selections; cancelled = $cancelled
        }

        if (-not $isBatch) { return ($answer | ConvertTo-Json -Compress) }
        $answer.id = $question.id
        $answers.Add($answer)
        if ($cancelled) { break }
    }
    @{ cancelled = $cancelled; answers = $answers.ToArray() } | ConvertTo-Json -Depth 10 -Compress
}
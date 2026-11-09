function Invoke-AgentHarnessUserQuestions {
    param([hashtable]$Arguments, [hashtable]$Context)

    # Validate the full batch before checking the console, sounding or asking.
    Assert-AgentHarnessUserQuestions -Arguments $Arguments
    if (-not (Test-InteractiveConsole)) {
        return '{"cancelled":false,"unavailable":true,"answers":[]}'
    }
    $answers = [Collections.Generic.List[object]]::new()
    $cancelled = $false
    foreach ($question in $Arguments.questions) {
        if (-not $Context.NoPromptSound) {
            try { Invoke-Sound } catch { } # Sound failure must not prevent input.
        }
        $value = $null
        if ($question.type -ceq 'text') {
            $raw = @(Read-InteractiveText -Title $question.title -Description $question.description -ErrorAction Stop 2>&1)
        }
        else {
            # Numbered labels let distinct options share the same display title.
            $labels = @(for ($i = 0; $i -lt $question.options.Count; $i++) { '{0}. {1}' -f ($i + 1), $question.options[$i].title })
            $descriptions = @($question.options | ForEach-Object { [string]$_.description })
            $raw = @(Show-InteractiveMenu -Title $question.title -Description $question.description `
                    -Options $labels -OptionDescriptions $descriptions -MultiSelect:($question.type -ceq 'multi_choice') `
                    -Filter -ErrorAction Stop 2>&1)
        }

        # Catch nonterminating errors from replacements retaining Continue preference.
        $inputError = $raw | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | Select-Object -First 1
        if ($inputError) { throw $inputError }

        $values = @($raw | Where-Object { $null -ne $_ })
        $cancelled = $values.Count -eq 0
        if ($question.type -ceq 'text') {
            if (-not $cancelled) {
                if ($values.Count -ne 1 -or $values[0] -isnot [string] -or [string]::IsNullOrWhiteSpace($values[0])) {
                    throw 'Text input returned an invalid answer.'
                }
                $value = $values[0]
            }
        }
        else {
            if ($question.type -ceq 'single_choice' -and $values.Count -gt 1) { throw 'Single choice returned multiple answers.' }
            $selectedIds = [Collections.Generic.List[string]]::new()
            foreach ($selection in $values) {
                if ($selection -isnot [string]) { throw 'Menu returned an invalid choice.' }
                $index = [Array]::IndexOf($labels, $selection)
                if ($index -lt 0) { throw 'Menu returned an unknown choice.' }
                $id = $question.options[$index].id
                if ($selectedIds.Contains($id)) { throw 'Menu returned a duplicate choice.' }
                $selectedIds.Add($id)
            }
            $value = $selectedIds.ToArray()
        }

        $answers.Add(@{ id = $question.id; cancelled = $cancelled; answer = $value })
        $answerText = if ($question.type -ceq 'text' -and -not $cancelled) { $value } else { '' }
        Write-AgentHarnessPromptHistory -Context $Context -Type 'question_answer' -Text $answerText -Data @{
            id = $question.id; title = $question.title; questionType = $question.type
            answer = $value; cancelled = $cancelled
        }
        if ($cancelled) { break }
    }
    @{ cancelled = $cancelled; answers = $answers.ToArray() } | ConvertTo-Json -Depth 10 -Compress
}
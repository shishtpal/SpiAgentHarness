function Assert-AgentHarnessUserQuestions {
    param([hashtable]$Arguments)

    if ($Arguments.Count -ne 1 -or $Arguments.Keys -cnotcontains 'questions' -or
        $Arguments.questions -isnot [array] -or $Arguments.questions.Count -eq 0) {
        throw 'Supply only questions: a nonempty array of question objects.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($question in $Arguments.questions) {
        if ($question -isnot [hashtable]) { throw 'Each question must be a JSON object.' }
        foreach ($key in $question.Keys) {
            if ($key -cnotin @('id', 'title', 'description', 'type', 'options')) { throw 'Unknown question field.' }
        }
        foreach ($key in 'id', 'title', 'description', 'type') {
            if ($question[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($question[$key])) {
                throw "Question $key must be a nonblank string."
            }
        }
        if (-not $ids.Add($question.id)) { throw 'Question IDs must be distinct.' }
        if ($question.type -cnotin @('text', 'single_choice', 'multi_choice')) {
            throw 'Question type must be text, single_choice or multi_choice.'
        }
        if ($question.type -ceq 'text') {
            if ($question.ContainsKey('options')) { throw 'Text questions cannot have options.' }
            continue
        }
        if ($question.options -isnot [array] -or $question.options.Count -eq 0) {
            throw 'Choice options must be a nonempty array of option objects.'
        }
        $optionIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($option in $question.options) {
            if ($option -isnot [hashtable]) { throw 'Each option must be a JSON object.' }
            foreach ($key in $option.Keys) {
                if ($key -cnotin @('id', 'title', 'description')) { throw 'Unknown option field.' }
            }
            foreach ($key in 'id', 'title') {
                if ($option[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($option[$key])) {
                    throw "Option $key must be a nonblank string."
                }
            }
            if (-not $optionIds.Add($option.id)) { throw 'Option IDs must be distinct within each question.' }
            if ($option.ContainsKey('description') -and $option.description -isnot [string]) {
                throw 'Option description must be a string when supplied.'
            }
        }
    }
}
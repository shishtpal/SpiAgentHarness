function Assert-DecisionModelQuestions {
    param([Collections.IDictionary]$Questions)

    if (-not $Questions.Count) { throw 'Questions must contain at least one named question.' }
    foreach ($name in $Questions.Keys) {
        $question = ConvertTo-DecisionModelMap -Value $Questions[$name] -Name "Question '$name'"
        if ($question['type'] -cnotin 'choice', 'noul', 'score') {
            throw "Question '$name' type must be choice, noul, or score."
        }
        if ($question['instructions'] -isnot [string] -or [string]::IsNullOrWhiteSpace($question['instructions'])) {
            throw "Question '$name' requires nonempty instructions."
        }
        if ($question['type'] -ceq 'score') {
            $criteria = $question['criteria']
            if ($criteria -isnot [Collections.IList] -or -not $criteria.Count) {
                throw "Score question '$name' criteria must be a nonempty ordered array of descriptions."
            }
            foreach ($description in $criteria) {
                if ($description -isnot [string] -or [string]::IsNullOrWhiteSpace($description)) {
                    throw "Question '$name' criteria descriptions must be nonempty strings."
                }
            }
        }
        else {
            $criteria = ConvertTo-DecisionModelMap -Value $question['criteria'] -Name "Question '$name' criteria"
            if (-not $criteria.Count) { throw "Question '$name' requires at least one criterion." }
            if ($question['type'] -ceq 'noul' -and
                ($criteria.Count -ne 2 -or -not $criteria.Contains('true') -or -not $criteria.Contains('false'))) {
                throw "Noul question '$name' criteria must contain exactly the string keys 'true' and 'false'."
            }
            foreach ($description in $criteria.Values) {
                if ($description -isnot [string] -or [string]::IsNullOrWhiteSpace($description)) {
                    throw "Question '$name' criteria descriptions must be nonempty strings."
                }
            }
        }
    }
}
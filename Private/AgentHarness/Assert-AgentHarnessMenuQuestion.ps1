function Assert-AgentHarnessMenuQuestion {
    param([hashtable]$Question)

    if ($Question.title -isnot [string] -or [string]::IsNullOrWhiteSpace($Question.title)) {
        throw 'title must be a nonblank string.'
    }
    if ($Question.options -isnot [array] -or $Question.options.Count -eq 0) {
        throw 'options must be a nonempty array of distinct, nonblank strings.'
    }
    $labels = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($option in $Question.options) {
        if ($option -isnot [string] -or [string]::IsNullOrWhiteSpace($option) -or -not $labels.Add($option)) {
            throw 'options must be a nonempty array of distinct, nonblank strings.'
        }
    }
    if ($Question.ContainsKey('multi_select') -and $Question.multi_select -isnot [bool]) {
        throw 'multi_select must be a boolean.'
    }
}
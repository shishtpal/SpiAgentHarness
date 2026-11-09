function ConvertFrom-DecisionModelProtocolResponse {
    param([object]$Response, [Collections.IDictionary]$Questions, [string]$Protocol)

    $root = ConvertTo-DecisionModelMap $Response -Name 'Decisions response'
    if ($Protocol -ne 'openai_decisions') { return ,$root }
    if ($root['answers'] -isnot [Collections.IList] -or $root['answers'].Count -ne $Questions.Count) {
        throw 'Decisions response must contain an ordered answer array matching the questions.'
    }
    $answers = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $names = @($Questions.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        $name = $names[$i]
        $answer = ConvertTo-DecisionModelMap $root['answers'][$i] -Name 'Decision answer'
        if ($answer.Contains('name') -and $answer['name'] -cne $name) { throw 'Decision answer order/name does not match the request.' }
        if ($answer['type'] -ceq 'predicate') {
            if ($Questions[$name].type -cne 'noul') { throw 'Unexpected predicate answer.' }
            $answer['type'] = 'noul'
            $answer['noul'] = $answer['probability']
        }
        if ($answer.Contains('probabilities') -and $null -ne $answer['probabilities']) {
            if ($answer['probabilities'] -isnot [Collections.IList]) { throw 'Native decision probabilities must be an array.' }
            $probabilities = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($item in $answer['probabilities']) {
                $entry = ConvertTo-DecisionModelMap $item -Name 'Decision probability'
                if (-not $entry.Contains('value') -or $null -eq $entry['value']) { throw 'Decision probability has no value.' }
                $label = [string]$entry['value']
                if ($probabilities.Contains($label)) { throw 'Duplicate decision probability value.' }
                $probabilities.Add($label, $entry['probability'])
            }
            $answer['probabilities'] = $probabilities
        }
        $answers.Add($name, $answer)
    }
    $root['answers'] = $answers
    return ,$root
}
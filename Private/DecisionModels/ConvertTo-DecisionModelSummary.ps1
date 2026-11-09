function ConvertTo-DecisionModelSummary {
    param([Collections.IDictionary]$Answers, [Collections.IDictionary]$Questions)

    # One flat row per question, in question order, for tables and CSV exports.
    $culture = [Globalization.CultureInfo]::InvariantCulture
    foreach ($name in $Questions.Keys) {
        $answer = ConvertTo-DecisionModelMap -Value $Answers[$name]
        $question = ConvertTo-DecisionModelMap -Value $Questions[$name]
        $type = $answer['type']
        $probabilities = $null
        if ($type -cne 'noul' -and $type -cne 'refusal' -and $null -ne $answer['probabilities']) {
            # Validated earlier: one probability per criterion. Follow the question's label order.
            $map = ConvertTo-DecisionModelMap -Value $answer['probabilities']
            $labels = if ($type -ceq 'choice') { @((ConvertTo-DecisionModelMap -Value $question['criteria']).Keys) }
            else { @(for ($i = 0; $i -lt $question['criteria'].Count; $i++) { [string]$i }) }
            $probabilities = @(foreach ($label in $labels) {
                    '{0}={1}' -f $label, ([double]$map[$label]).ToString('0.###', $culture)
                }) -join ', '
        }
        [pscustomobject]@{
            PSTypeName    = 'SpiAgentHarness.DecisionModelAnswer'
            Question      = $name
            Type          = $type
            # The answer value is stored under its type name: choice, noul or score.
            Answer        = $answer[$type]
            Confidence    = $answer['confidence']
            Probabilities = $probabilities
        }
    }
}
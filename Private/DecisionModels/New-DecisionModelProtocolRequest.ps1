function New-DecisionModelProtocolRequest {
    param(
        [object]$State, [Collections.IDictionary]$Questions, [string]$Model,
        [string[]]$Attachment, [string]$Protocol
    )

    if ($Questions.Count -gt 32) { throw 'This decision protocol allows at most 32 questions.' }
    foreach ($question in $Questions.Values) {
        if ($question.type -eq 'choice' -and $question.criteria.Count -gt 64) { throw 'Choice questions allow at most 64 options.' }
        if ($question.type -eq 'score' -and ($question.criteria.Count -lt 2 -or $question.criteria.Count -gt 10)) {
            throw 'Score questions require 2 to 10 levels.'
        }
    }
    if ($Protocol -eq 'systemone') {
        if ($Attachment.Count) { throw 'The systemone adapter accepts text/JSON state only; image attachments are unsupported.' }
        # Treat state as evidence, never as an implicitly executable message/image envelope.
        return @{ model = $Model; state = $State; questions = $Questions }
    }

    $wireQuestions = @(foreach ($name in $Questions.Keys) {
        $question = $Questions[$name]
        $wire = @{ name = $name; type = $question.type; instructions = $question.instructions }
        switch ($question.type) {
            'noul' {
                $wire.type = 'predicate'
                $wire.instructions += "`nTrue: $($question.criteria['true'])`nFalse: $($question.criteria['false'])"
            }
            'choice' {
                $criteria = ConvertTo-DecisionModelMap $question.criteria
                $wire.choices = @(foreach ($label in $criteria.Keys) { @{ value = $label; description = $criteria[$label] } })
            }
            'score' {
                $wire.levels = @(for ($i = 0; $i -lt $question.criteria.Count; $i++) {
                    @{ label = [string]$i; description = $question.criteria[$i] }
                })
            }
        }
        $wire
    })
    $text = if ($State -is [string]) { $State } else { ConvertTo-Json -InputObject $State -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop }
    $inputValue = $text
    if ($Attachment.Count) {
        $parts = @(@{ type = 'input_text'; text = $text })
        foreach ($path in $Attachment) {
            $part = ConvertTo-DecisionModelImagePart -Path $path -MaxBytes 20971520 -ValidateSignature
            $parts += @{ type = 'input_image'; image_url = $part.image_url.url }
        }
        $inputValue = @(@{ role = 'user'; content = $parts })
    }
    @{ model = $Model; input = $inputValue; questions = $wireQuestions }
}
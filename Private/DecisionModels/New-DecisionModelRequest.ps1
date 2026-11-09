function New-DecisionModelRequest {
    param(
        [object]$State, [AllowNull()][object]$Questions, [string]$Model,
        [AllowNull()][AllowEmptyCollection()][string[]]$Attachment,
        [string]$Protocol = 'openrouter'
    )

    if ($null -eq $State -or ($State -isnot [string] -and $State -isnot [Collections.IDictionary] -and
            $State -isnot [Management.Automation.PSCustomObject] -and $State -isnot [Collections.IList])) {
        throw 'State must be text, a JSON object, or an array of context.'
    }
    $questionMap = ConvertTo-DecisionModelMap -Value $Questions -Name 'Questions'
    Assert-DecisionModelQuestions -Questions $questionMap
    if ($Protocol -ne 'openrouter') {
        $body = New-DecisionModelProtocolRequest -State $State -Questions $questionMap -Model $Model -Attachment $Attachment -Protocol $Protocol
        $json = ConvertTo-Json -InputObject $body -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop
        $maxBytes = if ($Protocol -eq 'systemone') { 262144 } else { 33554432 }
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $maxBytes) { throw 'Decision request exceeds the protocol byte limit.' }
        return [pscustomobject]@{ Json = $json; Questions = $questionMap }
    }
    $stateValue = $State
    if ($null -ne $Attachment -and $Attachment.Count -gt 0) {
        # Multimodal state: the context as one text part, followed by one image part per attachment.
        $text = if ($State -is [string]) { $State } else { ConvertTo-Json -InputObject $State -Depth 100 -Compress -ErrorAction Stop }
        $parts = @(@{ type = 'text'; text = $text })
        foreach ($path in $Attachment) { $parts += ConvertTo-DecisionModelImagePart -Path $path }
        $stateValue = $parts
    }
    $body = @{ model = $Model; state = $stateValue; questions = $questionMap }
    # InputObject preserves empty/single-item arrays. Treat depth truncation as an error.
    $json = ConvertTo-Json -InputObject $body -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop
    [pscustomobject]@{ Json = $json; Questions = $questionMap }
}
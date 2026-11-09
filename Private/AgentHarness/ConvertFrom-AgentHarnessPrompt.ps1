function ConvertFrom-AgentHarnessPrompt {
    # Parse attachment markers as data; never evaluate prompt text as PowerShell.
    param([string]$Prompt)

    $attachments = [Collections.Generic.List[object]]::new()
    $text = [Text.StringBuilder]::new()
    $prefixPattern = [regex]::new('(?<clipboard>(?<![\w@])@@?clipboard(?:\(\))?(?![\w.(]))|@@?attach\(', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $attachmentPattern = [regex]::new(@'
\G@attach\(\s*(?:"(?<double>[^"]*)"|'(?<single>[^']*)'|(?<bare>[^()'"\r\n]*))\s*\)
'@, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $position = 0
    while ($true) {
        $prefix = $prefixPattern.Match($Prompt, $position)
        if (-not $prefix.Success) { break }
        [void]$text.Append($Prompt.Substring($position, $prefix.Index - $position))
        $escaped = $prefix.Value.StartsWith('@@')
        if ($prefix.Groups['clipboard'].Success) {
            if ($escaped) { [void]$text.Append($prefix.Value.Substring(1)) }
            else {
                $attachments.Add(@{ Source = 'Clipboard' })
                [void]$text.Append(' ')
            }
            $position = $prefix.Index + $prefix.Length
            continue
        }
        $start = $prefix.Index + [int]$escaped
        $attachment = $attachmentPattern.Match($Prompt, $start)
        if ($escaped) {
            if ($attachment.Success) {
                [void]$text.Append($attachment.Value)
                $position = $attachment.Index + $attachment.Length
            }
            else {
                [void]$text.Append('@attach(')
                $position = $prefix.Index + $prefix.Length
            }
            continue
        }
        if (-not $attachment.Success) {
            throw 'Invalid attachment syntax. Use @attach("path/to/file") or @@attach(...) for literal text.'
        }
        $path = if ($attachment.Groups['double'].Success) { $attachment.Groups['double'].Value }
        elseif ($attachment.Groups['single'].Success) { $attachment.Groups['single'].Value }
        else { $attachment.Groups['bare'].Value.Trim() }
        if ([string]::IsNullOrWhiteSpace($path)) { throw 'Attachment paths cannot be blank.' }
        $attachments.Add($path)
        [void]$text.Append(' ')
        $position = $attachment.Index + $attachment.Length
    }
    [void]$text.Append($Prompt.Substring($position))
    $promptText = $text.ToString()
    if ($attachments.Count) {
        $promptText = $promptText.Trim()
        if (-not $promptText) { $promptText = 'Review the attached files.' }
    }
    @{ Text = $promptText; Attachments = $attachments.ToArray() }
}
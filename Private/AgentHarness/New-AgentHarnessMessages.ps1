function New-AgentHarnessMessages {
    param(
        [string]$SystemPrompt,
        [string]$Prompt,
        [object[]]$History,
        [switch]$KeepLatestAnswer,
        [string[]]$Attachments,
        [string]$WorkingDirectory,
        [Collections.Generic.List[object]]$PendingInjections
    )

    # Refresh instructions for this invocation; avoid duplicate or stale AGENTS.md content.
    $messages = [Collections.Generic.List[object]]::new()
    $messages.Add(@{ role = 'system'; content = $SystemPrompt })
    $latestAnswer = if ($KeepLatestAnswer) {
        $History | Where-Object { $_.role -eq 'assistant' -and -not $_.tool_calls } | Select-Object -Last 1
    }
    foreach ($message in $History) {
        if ($KeepLatestAnswer) {
            if ($message.role -eq 'user' -or [object]::ReferenceEquals($message, $latestAnswer)) {
                # Rebuild entries so no tool metadata survives compaction.
                $messages.Add(@{ role = $message.role; content = $message.content })
            }
            continue
        }
        if ($message.role -ne 'system') { $messages.Add($message) }
    }

    $parsedPrompt = ConvertFrom-AgentHarnessPrompt -Prompt $Prompt
    $allAttachments = [Collections.Generic.List[object]]::new()

    if ($Attachments.Count) { $allAttachments.AddRange([object[]]$Attachments) }
    $allAttachments.AddRange([object[]]$parsedPrompt.Attachments)
    $content = $parsedPrompt.Text
    $injectionsForUser = [Collections.Generic.List[object]]::new()
    if ($allAttachments.Count) {
        $parts = [Collections.Generic.List[object]]::new()
        $parts.Add(@{ type = 'text'; text = $parsedPrompt.Text })
        $clipboardImage = $null
        foreach ($attachment in $allAttachments) {
            $partIndex = $parts.Count
            if ($attachment -is [Collections.IDictionary] -and $attachment.Source -eq 'Clipboard') {
                if ($null -eq $clipboardImage) {
                    $clipboardImage = Get-AgentHarnessClipboardImage -PlaceholderOnly
                }
                $parts.Add($clipboardImage.PlaceholderPart)
                $injectionsForUser.Add(@{ PartIndex = $partIndex; ContentPart = $clipboardImage.ContentPart; Placeholder = $clipboardImage.Placeholder })
            }
            else {
                $conv = ConvertTo-AgentHarnessAttachment -Path $attachment -WorkingDirectory $WorkingDirectory -PlaceholderMode
                $parts.Add($conv.Part)
                if ($conv -is [Collections.IDictionary] -and $conv.ContainsKey('ContentPart') -and $null -ne $conv.ContentPart) {
                    $injectionsForUser.Add(@{ PartIndex = $partIndex; ContentPart = $conv.ContentPart; Placeholder = $conv.Placeholder })
                }
            }
        }
        $content = $parts.ToArray()
    }

    $messages.Add(@{ role = 'user'; content = $content })
    if ($null -ne $PendingInjections -and $injectionsForUser.Count -gt 0) {
        $userIndex = $messages.Count - 1
        foreach ($inj in $injectionsForUser) {
            $PendingInjections.Add(@{
                    MessageIndex = $userIndex
                    PartIndex    = $inj.PartIndex
                    ContentPart  = $inj.ContentPart
                    Placeholder  = $inj.Placeholder
                }) | Out-Null
        }
    }
    # Keep the mutable list as one pipeline object, including with only two messages.
    , $messages
}
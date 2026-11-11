function Read-AgentHarnessNextPrompt {
    param(
        [string]$Answer,
        [switch]$NoPromptSound,
        [switch]$SkipAnswer,
        [switch]$AnswerAlreadyDisplayed,
        [hashtable]$Context
    )

    # The answer and checkpoint remain visible in Quiet mode.
    if (-not $SkipAnswer) {
        if ($AnswerAlreadyDisplayed) { Write-Host 'Task complete' -ForegroundColor Cyan }
        else { Write-AgentHarnessBlock -Title 'Task complete' -Text $Answer }
    }

    if (-not $NoPromptSound) {
        try { Invoke-Sound }
        catch { } # Audio must not prevent continuation or stopping.
    }

    $prompt = Read-Host 'Continue with another task or stop? [exit]'
    if ($null -ne $prompt -and $Context) {
        $isStop = [string]::IsNullOrWhiteSpace($prompt) -or $prompt.Trim() -eq 'exit'
        $type = if ($isStop) { 'stop_reply' } elseif ($prompt.TrimStart() -match '^/save-context(?:\s|$)') { 'context_save_command' } else { 'continuation_prompt' }
        Write-AgentHarnessPromptHistory -Context $Context -Type $type -Text $prompt
    }

    if ([string]::IsNullOrWhiteSpace($prompt) -or $prompt.Trim() -eq 'exit') { return }
    $prompt
}
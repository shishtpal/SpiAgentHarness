function Read-AgentHarnessNextPrompt {
    param([string]$Answer, [switch]$NoPromptSound, [switch]$SkipAnswer)

    # The answer and checkpoint remain visible in Quiet mode.
    if (-not $SkipAnswer) { Write-AgentHarnessBlock -Title 'Task complete' -Text $Answer }
    if (-not $NoPromptSound) {
        try { Invoke-Sound }
        catch { } # Audio must not prevent continuation or stopping.
    }
    $prompt = Read-Host 'Continue with another task or stop? [exit]'
    if ([string]::IsNullOrWhiteSpace($prompt) -or $prompt.Trim() -eq 'exit') { return }
    $prompt
}
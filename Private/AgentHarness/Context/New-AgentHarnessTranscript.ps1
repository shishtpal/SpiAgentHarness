function New-AgentHarnessTranscript {
    param(
        [object[]]$Messages, [hashtable]$Context, [string]$Provider, [string]$Model,
        [int]$Index, [string]$Reason, [long]$EstimatedBefore
    )

    $snapshot = [ordered]@{
        format = 'SpiAgentHarness.Transcript'; version = 1
        sessionId = $Context.ContextSessionId; index = $Index; reason = $Reason
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        workingDirectory = $Context.Root; provider = $Provider; model = $Model
        budget = $Context.AutoCompact.Budget; estimatedBefore = $EstimatedBefore
        toolSpecCharacters = $Context.AutoCompact.ToolSpecCharacters
        promptTokens = $Context.AutoCompact.PromptTokens; completionTokens = $Context.AutoCompact.CompletionTokens
        messages = @($Messages)
    }
    if ($Context.ParentContextSessionId) { $snapshot.parentSessionId = $Context.ParentContextSessionId }
    $snapshot
}
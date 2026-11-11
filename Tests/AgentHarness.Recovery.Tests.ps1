# Included by AgentHarness.Context.Tests.ps1; local fixtures and mocked requests only.
$recoveryRoot = Join-Path $contextRoot 'recovery-fixture'
$null = New-Item -ItemType Directory -Path $recoveryRoot
$recoveryOptions = $contextOptions.Clone(); $recoveryOptions.WorkingDirectory = $recoveryRoot
$checkpointRoot = Join-Path $recoveryRoot '.agents/harness/checkpoints'

# Opting in alone must not persist successful runs or recoverable request failures.
Set-HarnessResponses @((New-HarnessResponse 'successful'))
$successfulRecovery = Invoke-AgentHarness 'successful task' @recoveryOptions -SaveContextOnFailure -PassThru
Assert-Harness (-not (Test-Path -LiteralPath $checkpointRoot) -and $null -eq $successfulRecovery.RecoveryContextPath) 'Successful runs write no failure checkpoint'
Set-HarnessResponses @((New-HarnessApiError 429), (New-HarnessResponse 'transport retry succeeded'))
$null = Invoke-AgentHarness 'retry task' @recoveryOptions -SaveContextOnFailure
Assert-Harness (-not (Test-Path -LiteralPath $checkpointRoot)) 'Successful transport retries write no failure checkpoint'

foreach ($preference in 'Continue', 'Stop') {
    Set-HarnessResponses @((New-HarnessApiError 400))
    $caughtRecovery = $null; $recoveryWarnings = @()
    try {
        $null = Invoke-AgentHarness 'initial provider failure' @recoveryOptions -SaveContextOnFailure `
            -ApiKey 'synthetic-recovery-key' -ErrorAction $preference -WarningAction Stop -WarningVariable recoveryWarnings
    }
    catch { $caughtRecovery = $_ }
    Assert-Harness ($null -ne $caughtRecovery -and $caughtRecovery.Exception.Message -like '*after 1 attempt*mock API failure*') "Initial provider error is preserved under $preference"
    $initialRecoveryPath = $caughtRecovery.Exception.Data['RecoveryContextPath']
    Assert-Harness ($initialRecoveryPath -and [IO.Path]::GetDirectoryName($initialRecoveryPath) -eq $checkpointRoot -and (Test-Path -LiteralPath $initialRecoveryPath)) 'Failure generates an absolute checkpoint path under the current working directory'
    $initialRecovery = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($initialRecoveryPath)) -AsHashtable -NoEnumerate
    Assert-Harness ($initialRecovery.format -ceq 'SpiAgentHarness.Recovery' -and $initialRecovery.version -eq 1 -and $initialRecovery.mode -ceq 'raw' -and $initialRecovery.status -ceq 'interrupted' -and $initialRecovery.stopReason -ceq 'provider_failure') 'Failure checkpoint has an explicit interrupted format and stop reason'
    Assert-Harness (($initialRecovery.messages.role -join ',') -ceq 'system,user' -and $initialRecovery.provider -ceq 'custom' -and $initialRecovery.model -ceq 'custom-model') 'A first-turn failure retains the prompt and attempted model even after candidate removal'
    Assert-Harness (($recoveryWarnings -join "`n").Contains($initialRecoveryPath) -and @(Get-HarnessRequests).Count -eq 1) 'Failure path is reported even with Quiet and WarningAction Stop, without another provider request'
    Assert-Harness (-not ([IO.File]::ReadAllText($initialRecoveryPath)).Contains('synthetic-recovery-key') -and -not $initialRecovery.ContainsKey('ApiKey')) 'Failure checkpoint excludes connection credentials'
}
Assert-Harness (@(Get-ChildItem -LiteralPath $checkpointRoot -Filter '*.json').Count -eq 2) 'Repeated failures produce distinct checkpoint files'

# User-ending checkpoints can be resumed, with current instructions and a new prompt.
Set-HarnessResponses @((New-HarnessResponse 'initial failure resumed'))
$initialResumed = Invoke-AgentHarness 'Continue after checking current state' @recoveryOptions -ContextPath $initialRecoveryPath -Instructions 'Fresh recovery instructions' -PassThru
Assert-Harness ($initialResumed.Answer -ceq 'initial failure resumed' -and $initialResumed.Messages[0].content.EndsWith('Fresh recovery instructions') -and $initialResumed.Messages[1].content -ceq 'initial provider failure' -and @(Get-HarnessRequests).Count -eq 1) 'Recovery refreshes instructions and preserves the unfinished prompt'

# Preserve every completed result in a batch, and never replay tools while loading.
$recoveryTools = @{
    recovery_echo = @{ Script = { param($a, $ctx) [IO.File]::AppendAllText((Join-Path $ctx.Root 'executions.txt'), 'x'); 'completed evidence' } }
}
$recoveryBatch = @((New-HarnessCall recovery_echo '{"items":[]}' 'recovery_a'), (New-HarnessCall recovery_echo '{"items":[1]}' 'recovery_b'))
foreach ($preference in 'Continue', 'Stop') {
    $providerFailure = New-HarnessApiError 400
    Set-HarnessResponses @((New-HarnessResponse '' $recoveryBatch), $providerFailure)
    $caughtRecovery = $null
    try { $null = Invoke-AgentHarness 'tool run then failure' @recoveryOptions -Tools $recoveryTools -SaveContextOnFailure -ErrorAction $preference 3>$null }
    catch { $caughtRecovery = $_ }
    Assert-Harness ($caughtRecovery -and $caughtRecovery.Exception.Message -ceq 'HTTP 400 : mock API failure' -and $caughtRecovery.Exception.Data['Status'] -eq 400) "Locked provider failure keeps its existing transport error and status under $preference"
    $batchRecoveryPath = $caughtRecovery.Exception.Data['RecoveryContextPath']
    $batchRecovery = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($batchRecoveryPath)) -AsHashtable -NoEnumerate
    Assert-Harness (($batchRecovery.messages.role -join ',') -ceq 'system,user,assistant,tool,tool' -and $batchRecovery.messages[2].tool_calls -is [array] -and $batchRecovery.messages[2].tool_calls.Count -eq 2 -and $batchRecovery.messages[2].tool_calls[0].function.arguments -ceq '{"items":[]}' -and $batchRecovery.messages[-1].tool_call_id -ceq 'recovery_b') 'Raw recovery preserves complete tool pairs and JSON object arguments containing arrays'
}
$executionsBeforeResume = [IO.File]::ReadAllText((Join-Path $recoveryRoot 'executions.txt'))
Set-HarnessResponses @((New-HarnessResponse 'tool history resumed'))
$batchResumed = Invoke-AgentHarness 'Verify existing effects and continue' @recoveryOptions -Tools $recoveryTools -ContextPath $batchRecoveryPath -PassThru
$batchResumeRequest = @(Get-HarnessRequests)[0]
Assert-Harness ($batchResumed.Answer -ceq 'tool history resumed' -and $batchResumeRequest.Body.messages[-2].role -ceq 'tool' -and $batchResumeRequest.Body.messages[-2].content -ceq 'completed evidence' -and [IO.File]::ReadAllText((Join-Path $recoveryRoot 'executions.txt')) -ceq $executionsBeforeResume) 'Loading recovery sends tool history as data without executing historical actions'

# Iteration exhaustion reports a path in PassThru and leaves completed exports intact.
Set-HarnessResponses @((New-HarnessResponse '' $recoveryBatch))
$limitWarnings = @()
$limitedRecovery = Invoke-AgentHarness 'exhaust tool budget' @recoveryOptions -Tools $recoveryTools -MaxIterations 1 -SaveContextOnFailure `
    -SaveContextPath $raw.ContextPath -ContextMode Summary -PassThru -WarningVariable limitWarnings 3>$null
$limitRecovery = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($limitedRecovery.RecoveryContextPath)) -AsHashtable -NoEnumerate
Assert-Harness ($limitedRecovery.Answer -ceq '' -and $null -eq $limitedRecovery.ContextPath -and $limitRecovery.stopReason -ceq 'iteration_limit' -and $limitRecovery.messages[-1].role -ceq 'tool') 'Iteration exhaustion exposes a separate recovery path without claiming a completed export'
Assert-Harness (($limitWarnings -join "`n").Contains($limitedRecovery.RecoveryContextPath) -and @(Get-HarnessRequests).Count -eq 1 -and (Read-ContextFixture raw.json).messages[-1].content -ceq 'first answer') 'Failure saving stays raw, makes no summary request, and preserves an existing completed export'

# Raw recovery must retain earlier answers/tools after interactive continuation pruning.
& $module { $script:ContextReplies.Enqueue('unfinished second task') }
$continuedRecoveryOptions = $recoveryOptions.Clone(); $continuedRecoveryOptions.NoCompletionPrompt = $false
Set-HarnessResponses @((New-HarnessResponse '' $recoveryBatch), (New-HarnessResponse 'first task complete'), (New-HarnessApiError 400))
$caughtRecovery = $null
try { $null = Invoke-AgentHarness 'first task' @continuedRecoveryOptions -Tools $recoveryTools -SaveContextOnFailure 3>$null 6>$null }
catch { $caughtRecovery = $_ }
$continuedRecovery = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($caughtRecovery.Exception.Data['RecoveryContextPath'])) -AsHashtable -NoEnumerate
Assert-Harness (($continuedRecovery.messages.role -join ',') -ceq 'system,user,assistant,tool,tool,assistant,user' -and $continuedRecovery.messages[-1].content -ceq 'unfinished second task') 'Recovery saves raw history across completed and unfinished tasks'

# Recovery validation allows interrupted boundaries only; malformed pairs stay invalid.
foreach ($preference in 'Continue', 'Stop') {
    foreach ($kind in 'status', 'reason', 'reason-array', 'mode', 'pending', 'orphan', 'arguments', 'system-only', 'completed-format') {
        $invalidRecovery = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($batchRecoveryPath)) -AsHashtable -NoEnumerate
        switch ($kind) {
            status { $invalidRecovery.status = @('interrupted') }
            reason { $invalidRecovery.stopReason = 'unknown' }
            'reason-array' { $invalidRecovery.stopReason = @('provider_failure') }
            mode { $invalidRecovery.mode = 'summary' }
            pending { $invalidRecovery.messages = $invalidRecovery.messages[0..3] }
            orphan { $invalidRecovery.messages[-1].tool_call_id = 'missing' }
            arguments { $invalidRecovery.messages[2].tool_calls[0].function.arguments = '[{}]' }
            'system-only' { $invalidRecovery.messages = @($invalidRecovery.messages[0]) }
            'completed-format' { $invalidRecovery.format = 'SpiAgentHarness.Context' }
        }
        Write-ContextFixture invalid-recovery.json $invalidRecovery
        Set-HarnessResponses @()
        Assert-HarnessThrows { Invoke-AgentHarness 'Do not send invalid recovery' @recoveryOptions -ContextPath (Join-Path $contextRoot 'invalid-recovery.json') -ErrorAction $preference } '*'
        Assert-Harness (@(Get-HarnessRequests).Count -eq 0) "Invalid recovery $kind never reaches a provider under $preference"
    }
}

# A blocked checkpoint destination cannot hide the original provider error or iteration result.
$blockedRecoveryRoot = Join-Path $contextRoot 'blocked-recovery-fixture'
$null = New-Item -ItemType Directory -Path $blockedRecoveryRoot
[IO.File]::WriteAllText((Join-Path $blockedRecoveryRoot '.agents'), 'existing sentinel')
$blockedRecoveryOptions = $recoveryOptions.Clone(); $blockedRecoveryOptions.WorkingDirectory = $blockedRecoveryRoot
foreach ($preference in 'Continue', 'Stop') {
    $providerFailure = New-HarnessApiError 400
    Set-HarnessResponses @((New-HarnessResponse '' $recoveryBatch), $providerFailure)
    $caughtRecovery = $null; $blockedWarnings = @()
    try { $null = Invoke-AgentHarness 'blocked checkpoint' @blockedRecoveryOptions -Tools $recoveryTools -SaveContextOnFailure -ErrorAction $preference -WarningAction Stop -WarningVariable blockedWarnings 3>$null }
    catch { $caughtRecovery = $_ }
    Assert-Harness ($caughtRecovery -and $caughtRecovery.Exception.Message -ceq 'HTTP 400 : mock API failure' -and $caughtRecovery.Exception.Data['Status'] -eq 400 -and -not $caughtRecovery.Exception.Data.Contains('RecoveryContextPath')) 'Checkpoint write failure preserves the original provider error without reporting a saved path'
    Assert-Harness (($blockedWarnings -join "`n") -like '*Recovery context could not be saved*' -and @(Get-HarnessRequests).Count -eq 2 -and [IO.File]::ReadAllText((Join-Path $blockedRecoveryRoot '.agents')) -ceq 'existing sentinel') 'Failed checkpoint emits a sanitized warning and preserves existing files'
    Set-HarnessResponses @((New-HarnessResponse '' $recoveryBatch))
    $blockedLimit = Invoke-AgentHarness 'blocked iteration checkpoint' @blockedRecoveryOptions -Tools $recoveryTools -MaxIterations 1 -SaveContextOnFailure -PassThru -ErrorAction $preference 3>$null
    Assert-Harness ($blockedLimit.Answer -ceq '' -and $null -eq $blockedLimit.RecoveryContextPath -and @(Get-HarnessRequests).Count -eq 1) 'Checkpoint write failure preserves the iteration-exhaustion result'
}
Assert-Harness (@(Get-ChildItem -LiteralPath $checkpointRoot -Filter '.context-*.tmp').Count -eq 0) 'Recovery writes leave no temporary files'
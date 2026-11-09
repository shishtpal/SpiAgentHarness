function Stop-AgentHarnessSubAgent {
    param([string]$Id, [hashtable]$Context)

    $status = Get-AgentHarnessSubAgent -Id $Id -Context $Context
    if ($status.State -notin 'starting', 'running') { return $status }
    if (-not $status.ProcessId -or [int]$status.ProcessId -eq $PID) { throw 'The worker has not supplied a stoppable process identity.' }
    if (-not (Confirm-AgentHarnessAction -Ctx $Context -Description "Stop sub-agent $Id ($($status.Name)) and its child processes?")) {
        throw 'The user denied stopping this sub-agent.'
    }

    # It may have completed while the user was considering the approval prompt.
    $status = Get-AgentHarnessSubAgent -Id $Id -Context $Context
    if ($status.State -notin 'starting', 'running') { return $status }

    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById([int]$status.ProcessId)
        if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$status.ProcessStartTicks) { throw 'The worker process identity changed; refusing to stop it.' }
        $process.Kill($true)
        if (-not $process.WaitForExit(5000)) { throw 'The worker has not stopped yet.' }
    }
    catch [ArgumentException] { } # Already exited after the status check.
    finally { if ($process) { $process.Dispose() } }

    $status.State = 'stopped'
    $status.UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Write-AgentHarnessSubAgentJson -Root $Context.Root -Path (Join-Path ".agents/children/$Id" 'status.json') -Value $status
    $status
}
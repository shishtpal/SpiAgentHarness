function Get-AgentHarnessSubAgent {
    param([string]$Id, [hashtable]$Context)

    $agentsRoot = Resolve-AgentHarnessStatePath -Root $Context.Root -Path '.agents/children'
    if (-not $PSBoundParameters.ContainsKey('Id')) {
        if (Test-Path -LiteralPath $agentsRoot) {
            foreach ($directory in Get-ChildItem -LiteralPath $agentsRoot -Directory -ErrorAction Stop) {
                if ($directory.Name -cmatch '^[a-f0-9]{32}$') { Get-AgentHarnessSubAgent -Id $directory.Name -Context $Context }
            }
        }
        return
    }
    if ($Id -cnotmatch '^[a-f0-9]{32}$') { throw 'agent_id must be a 32-character lowercase hexadecimal ID.' }
    $directory = Join-Path $agentsRoot $Id
    $status = Read-AgentHarnessSubAgentJson -Root $Context.Root -Path (Join-Path $directory 'status.json')
    if ($status.Id -cne $Id -or $status.State -notin 'starting', 'running', 'completed', 'failed', 'stopped', 'interrupted') { throw 'Invalid sub-agent status.' }
    $processPath = Join-Path $directory 'process.json'
    if (-not $status.ProcessId -and (Test-Path -LiteralPath $processPath)) {
        $identity = Read-AgentHarnessSubAgentJson -Root $Context.Root -Path $processPath
        $status.ProcessId = $identity.ProcessId
        $status.ProcessStartTicks = $identity.ProcessStartTicks
    }
    if ($status.State -in 'starting', 'running') {
        $alive = $false
        if ($status.ProcessId -and $status.ProcessStartTicks) {
            $process = $null
            try {
                $process = [Diagnostics.Process]::GetProcessById([int]$status.ProcessId)
                $alive = -not $process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$status.ProcessStartTicks
            }
            catch [ArgumentException] { }
            finally { if ($process) { $process.Dispose() } }
        }
        # Allow a short handshake interval while the terminal process starts.
        if (-not $alive -and ($status.ProcessId -or [DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($status.StartedAt) -gt [TimeSpan]::FromSeconds(30))) {
            $status.State = 'interrupted'
            $status.Error = 'The worker process is no longer running. Inspect saved work before resuming.'
        }
    }
    $status.ResultFile = Join-Path $directory 'result.json'
    $status.WorkStatusFile = Join-Path $directory 'WORK_STATUS.md'
    $status.TaskFile = Join-Path $directory 'task.json'
    if ($status.State -eq 'completed' -and (Test-Path -LiteralPath $status.ResultFile)) {
        $result = Read-AgentHarnessSubAgentJson -Root $Context.Root -Path $status.ResultFile
        $status.Answer = $result.Answer
    }
    $status
}
function Start-AgentHarnessSubAgent {
    param([hashtable]$Arguments, [hashtable]$Context)

    $ErrorActionPreference = 'Stop'
    foreach ($key in $Arguments.Keys) {
        if ($key -cnotin 'task', 'name', 'yolo', 'allow_write') { throw "Unknown spawn_agent argument: $key" }
    }
    if ($Arguments.task -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments.task)) { throw 'task must be a nonblank string.' }
    if ($Arguments.ContainsKey('name') -and ($Arguments.name -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments.name) -or $Arguments.name.Length -gt 80)) { throw 'name must be a nonblank string up to 80 characters.' }
    foreach ($key in 'yolo', 'allow_write') {
        if ($Arguments.ContainsKey($key) -and $Arguments[$key] -isnot [bool]) { throw "$key must be a boolean." }
    }
    if (-not $Context.AllowShell) { throw 'Sub-agent launches are disabled when shell execution is disabled.' }
    if (-not $Context.SubAgentModel -or -not $Context.SubAgentConnection) { throw 'Sub-agent model context is unavailable.' }
    $active = @($Context.SubAgents | ForEach-Object { Get-AgentHarnessSubAgent -Id $_ -Context $Context } | Where-Object State -in 'starting', 'running')
    if ($active.Count -ge $Context.MaxSubAgents) { throw "The active sub-agent limit ($($Context.MaxSubAgents)) has been reached. Wait for or stop a child first." }
    $yolo = if ($Arguments.ContainsKey('yolo')) { $Arguments.yolo } else { [bool]$Context.YOLO }
    $allowWrite = [bool]$Arguments.allow_write
    if ($allowWrite -and -not $Context.AllowWrite) { throw 'Child write tools cannot be enabled when parent writes are disabled.' }
    $name = if ($Arguments.name) { $Arguments.name } else { 'Sub-agent' }
    if (-not (Confirm-AgentHarnessAction -Ctx $Context -Description "Launch '$name' in a new PowerShell terminal?`nChild YOLO: $yolo; child writes/shell: $allowWrite`nTask:`n$($Arguments.task)")) {
        return 'ERROR: the user denied this sub-agent launch.'
    }

    $id = [guid]::NewGuid().ToString('N')
    $relative = ".agents/children/$id"
    $directory = Resolve-AgentHarnessStatePath -Root $Context.Root -Path $relative
    $options = $Context.SubAgentOptions.Clone()
    $options.Provider = $Context.SubAgentProvider
    $options.Model = $Context.SubAgentModel
    $options.ChatUri = $Context.SubAgentConnection.ChatUri
    $options.WorkingDirectory = $Context.Root
    $options.AllowWrite = $allowWrite
    $options.NoShellTool = -not ($allowWrite -and $Context.AllowShell)
    $options.YOLO = $yolo
    $options.NoSubAgents = $true
    $options.NoModelRecovery = $true
    $options.NoCompletionPrompt = $true
    $options.PassThru = $true
    $options.Prompt = $Arguments.task
    $workStatus = "$relative/WORK_STATUS.md"
    $options.Instructions = @($options.Instructions, "You are delegated sub-agent $id ($name). Work only on the assigned task and respect its file ownership boundaries. Do not spawn other agents. Your work-status file is $workStatus; update it instead of the parent's WORK_STATUS.md. Return a concrete result and verification summary.") -join "`n`n"
    $keyVariable = if ($Context.SubAgentApiKey) { 'SPI_HARNESS_AGENT_KEY_' + $id } else { $null }
    $task = @{ Id = $id; Name = $name; Options = $options; KeyVariable = $keyVariable; Connection = $Context.SubAgentConnection }
    $status = [ordered]@{
        Id = $id; Name = $name; State = 'starting'; ProcessId = 0; ProcessStartTicks = 0
        StartedAt = [DateTimeOffset]::UtcNow.ToString('o'); UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        YOLO = $yolo; AllowWrite = $allowWrite; Provider = $options.Provider; Model = $options.Model
    }
    Write-AgentHarnessSubAgentJson -Root $Context.Root -Path "$relative/task.json" -Value $task
    Write-AgentHarnessSubAgentJson -Root $Context.Root -Path "$relative/status.json" -Value $status
    $workerPath = Join-Path $PSScriptRoot 'Invoke-AgentHarnessWorker.ps1'
    $bootstrap = ". '" + $workerPath.Replace("'", "''") + "'; Invoke-AgentHarnessWorker -TaskDirectory '" + $directory.Replace("'", "''") + "'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $process = $null
    try {
        $process = Start-AgentHarnessTerminal -EncodedCommand $encoded -WorkingDirectory $Context.Root -KeyVariable $keyVariable -ApiKey $Context.SubAgentApiKey
        Write-AgentHarnessSubAgentJson -Root $Context.Root -Path "$relative/process.json" -Value @{
            ProcessId = $process.Id; ProcessStartTicks = $process.StartTime.ToUniversalTime().Ticks
        }
        $Context.SubAgents.Add($id)
    }
    catch {
        $status.State = 'failed'
        $status.Error = 'Unable to launch or track the sub-agent terminal.'
        if ($process) { try { $process.Kill($true) } catch { } }
        Write-AgentHarnessSubAgentJson -Root $Context.Root -Path "$relative/status.json" -Value $status
        throw 'Unable to launch or track the sub-agent terminal. See the saved status file.'
    }
    finally { if ($process) { $process.Dispose() } }
    Get-AgentHarnessSubAgent -Id $id -Context $Context | ConvertTo-Json -Depth 20
}
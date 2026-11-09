function Invoke-AgentHarnessWorker {
    param([string]$TaskDirectory)

    $ErrorActionPreference = 'Stop'
    $moduleRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    # This file contains definitions only, so the normal private loader can load it.
    $runtime = $null
    try {
        . (Join-Path $PSScriptRoot 'Import-AgentHarnessWorkerRuntime.ps1')
        $runtime = Import-AgentHarnessWorkerRuntime -ModuleRoot $moduleRoot
        & $runtime {
            param($directory)
            $taskPath = Join-Path $directory 'task.json'
            # Parent-created task directories are always below the recorded working root.
            $task = Read-AgentHarnessSubAgentJson -Root $directory -Path $taskPath
            $root = [string]$task.Options.WorkingDirectory
            $expected = Resolve-AgentHarnessStatePath -Root $root -Path ".agents/children/$($task.Id)"
            if ($task.Id -cnotmatch '^[a-f0-9]{32}$' -or -not $expected.Equals([IO.Path]::GetFullPath($directory), [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid worker task directory.' }
            $statusPath = Join-Path $directory 'status.json'
            $status = Read-AgentHarnessSubAgentJson -Root $root -Path $statusPath
            $process = [Diagnostics.Process]::GetCurrentProcess()
            try {
                $status.ProcessId = $PID
                $status.ProcessStartTicks = $process.StartTime.ToUniversalTime().Ticks
            }
            finally { $process.Dispose() }
            $status.State = 'running'
            $status.UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Write-AgentHarnessSubAgentJson -Root $root -Path $statusPath -Value $status
            $key = $null
            try {
                if ($task.KeyVariable) {
                    $key = [Environment]::GetEnvironmentVariable($task.KeyVariable, 'Process')
                    [Environment]::SetEnvironmentVariable($task.KeyVariable, $null, 'Process')
                    if (-not $key) { throw 'The inherited API key is unavailable.' }
                    $task.Options.ApiKey = $key
                }
                elseif ($task.Connection.KeyEnvVar) { $key = [Environment]::GetEnvironmentVariable($task.Connection.KeyEnvVar) }
                # Preserve explicit endpoint, environment-key lookup and tool_choice behavior
                # even for providers registered only in the parent process.
                $script:FreeModelProviders[$task.Options.Provider] = [pscustomobject]@{
                    Name = $task.Options.Provider; ChatUri = $task.Connection.ChatUri
                    Uri = $task.Connection.ChatUri; KeyEnvVar = $task.Connection.KeyEnvVar
                    OmitToolChoice = [bool]$task.Connection.OmitToolChoice
                }
                $Host.UI.RawUI.WindowTitle = "Agent: $($task.Name) [$($task.Id)]"
                Write-Host "Sub-agent $($task.Id): $($task.Name)" -ForegroundColor Cyan
                Write-Host "YOLO: $($task.Options.YOLO); work status: .agents/children/$($task.Id)/WORK_STATUS.md"
                $options = $task.Options
                # Reinforce worker limits even if a saved task is edited before launch.
                $options.NoSubAgents = $true
                $options.NoCompletionPrompt = $true
                $options.PassThru = $true
                $result = Invoke-AgentHarness @options
                if ([string]::IsNullOrWhiteSpace($result.Answer)) { throw 'The child ended without a final answer; inspect its work-status file.' }
                $answer = [string]$result.Answer
                if ($key) { $answer = $answer.Replace($key, '[REDACTED]') }
                Write-AgentHarnessSubAgentJson -Root $root -Path (Join-Path $directory 'result.json') -Value @{
                    Answer = $answer; Provider = $result.Provider; Model = $result.Model
                    Iterations = $result.Iterations; PromptTokens = $result.PromptTokens; CompletionTokens = $result.CompletionTokens
                }
                $status.State = 'completed'
                Write-Host $answer
            }
            catch {
                $status.State = 'failed'
                $message = $_.Exception.Message
                if ($key) { $message = $message.Replace($key, '[REDACTED]') }
                $status.Error = $message
                Write-Host 'Sub-agent failed. Inspect its saved status and work-status files.' -ForegroundColor Red
            }
            finally {
                $status.UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
                Write-AgentHarnessSubAgentJson -Root $root -Path $statusPath -Value $status
            }
        } $TaskDirectory
    }
    catch {
        # Initialization failures are visible without echoing untrusted task/config data.
        try {
            . (Join-Path $PSScriptRoot '../Resolve-AgentHarnessPath.ps1')
            foreach ($name in 'Resolve-AgentHarnessStatePath', 'Read-AgentHarnessSubAgentJson', 'Write-AgentHarnessSubAgentJson') {
                . (Join-Path $PSScriptRoot "$name.ps1")
            }
            $statusPath = Join-Path $TaskDirectory 'status.json'
            $status = Read-AgentHarnessSubAgentJson -Root $TaskDirectory -Path $statusPath
            $status.State = 'failed'
            $status.Error = 'Unable to initialize the sub-agent runtime.'
            $status.UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Write-AgentHarnessSubAgentJson -Root $TaskDirectory -Path $statusPath -Value $status
        }
        catch { } # A damaged state directory may itself be unwritable.
        Write-Host 'Unable to initialize the sub-agent. Inspect its saved task and resume it from the parent.' -ForegroundColor Red
    }
    finally { if ($runtime) { Remove-Module $runtime -Force } }
}
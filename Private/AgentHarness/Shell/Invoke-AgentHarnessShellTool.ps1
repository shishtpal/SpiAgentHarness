function Invoke-AgentHarnessShellTool {
    param(
        [ValidateSet('run', 'start', 'poll', 'stop')][string]$Operation,
        [hashtable]$Arguments,
        [hashtable]$Context
    )

    $ErrorActionPreference = 'Stop'
    $launch = $Operation -in 'run', 'start'
    $allowed = if ($launch) { @('command', 'timeout_sec') } elseif ($Operation -eq 'poll') { @('process_id', 'wait_ms') } else { @('process_id') }
    foreach ($key in $Arguments.Keys) {
        if ($key -cnotin $allowed) { throw "Unknown shell argument: $key" }
    }

    $timeout = if ($Operation -eq 'start') { 1800 } else { 60 }
    $wait = 0
    foreach ($option in @(@{ Name = 'timeout_sec'; Min = 1; Max = 86400 }, @{ Name = 'wait_ms'; Min = 0; Max = 1000 })) {
        if (-not $Arguments.ContainsKey($option.Name)) { continue }
        $value = $Arguments[$option.Name]
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $option.Min -or $value -gt $option.Max) {
            throw "$($option.Name) must be an integer from $($option.Min) to $($option.Max)."
        }
        if ($option.Name -eq 'timeout_sec') { $timeout = [int]$value } else { $wait = [int]$value }
    }

    $limit = if ($Context.MaxToolOutputChars) { [int]$Context.MaxToolOutputChars } else { 8000 }
    if ($launch) {
        if ($Arguments.command -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments.command)) { throw 'command must be a nonblank string.' }
        if ($Arguments.command.Length -gt 1MB) { throw 'command cannot exceed 1,048,576 characters.' }
        if ($Operation -eq 'start' -and $limit -lt 256) { throw 'start_powershell requires MaxToolOutputChars of at least 256 to return a process ID and status.' }
        if ($Operation -eq 'start' -and $Context.ShellProcesses) {
            if (@($Context.ShellProcesses.Values | Where-Object { -not $_.Completed }).Count -ge 8) { throw 'At most eight shell processes may run in one invocation.' }
        }
        if (-not (Confirm-AgentHarnessAction $Context "run PowerShell (deadline ${timeout}s): $($Arguments.command)")) { return 'ERROR: the user denied this command.' }
        if ($Operation -eq 'run') {
            return Invoke-AgentHarnessShell -Command $Arguments.command -WorkingDirectory $Context.Root -TimeoutSec $timeout -MaxOutputChars $limit
        }
        if ($null -eq $Context.ShellProcesses) { $Context.ShellProcesses = [ordered]@{} }
        if ($Context.ShellProcesses.Count -ge 32) {
            $oldest = @($Context.ShellProcesses.Keys | Where-Object { $Context.ShellProcesses[$_].Completed })[0]
            $Context.ShellProcesses[$oldest].Dispose()
            $Context.ShellProcesses.Remove($oldest)
        }
        $process = New-AgentHarnessShellProcess -Command $Arguments.command -WorkingDirectory $Context.Root -TimeoutSec $timeout
        $Context.ShellProcesses[$process.Id] = $process
    }
    else {
        if ($Arguments.process_id -isnot [string] -or $Arguments.process_id -cnotmatch '^[a-f0-9]{32}$') { throw 'process_id must be an ID returned by start_powershell.' }
        if (-not $Context.ShellProcesses -or -not $Context.ShellProcesses.Contains($Arguments.process_id)) { throw 'Unknown shell process ID for this invocation.' }
        $process = $Context.ShellProcesses[$Arguments.process_id]
        if ($Operation -eq 'stop') { $process.Stop(); $wait = 1000 }
        if ($wait) { $null = $process.Wait($wait) }
    }
    Format-AgentHarnessShellResult -Process $process -MaxOutputChars $limit -IncludeId
}
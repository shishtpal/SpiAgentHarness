function Close-AgentHarnessShellProcesses {
    param([hashtable]$Context)

    if (-not $Context.ShellProcesses) { return }
    # Request every stop before waiting for any one command to drain its pipes.
    foreach ($process in $Context.ShellProcesses.Values) { $process.Stop() }
    foreach ($process in $Context.ShellProcesses.Values) {
        try { $process.Dispose() }
        catch { Write-Warning 'A shell process could not be stopped during cleanup.' -WarningAction Continue }
    }
    $Context.ShellProcesses.Clear()
}
function New-AgentHarnessShellProcess {
    param([string]$Command, [string]$WorkingDirectory, [int]$TimeoutSec)

    if (-not ('SpiAgentHarness.ShellProcess' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'ShellProcess.cs') -ErrorAction Stop
    }
    [SpiAgentHarness.ShellProcess]::new((Get-Process -Id $PID).Path, $Command, $WorkingDirectory, $TimeoutSec)
}
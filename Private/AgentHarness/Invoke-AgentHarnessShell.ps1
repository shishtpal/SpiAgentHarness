function Invoke-AgentHarnessShell {
    param(
        [string]$Command,
        [string]$WorkingDirectory,
        [ValidateRange(1, 86400)][int]$TimeoutSec = 60,
        [int]$MaxOutputChars = 8000
    )

    $process = New-AgentHarnessShellProcess -Command $Command -WorkingDirectory $WorkingDirectory -TimeoutSec $TimeoutSec
    try {
        while (-not $process.Wait(250)) { }
        Format-AgentHarnessShellResult -Process $process -MaxOutputChars $MaxOutputChars
    }
    finally { $process.Dispose() }
}
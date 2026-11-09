function Invoke-AgentHarnessShell {
    param([string]$Command, [string]$WorkingDirectory)

    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($argument in '-NoProfile', '-NonInteractive', '-Command', $Command) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            return 'ERROR: command timed out after 60s.'
        }
        $sections = @("exit code: $($process.ExitCode)")
        if ($stdout.Result) { $sections += "Output:`n$($stdout.Result.TrimEnd("`r", "`n"))" }
        if ($stderr.Result) { $sections += "Errors:`n$($stderr.Result.TrimEnd("`r", "`n"))" }
        $sections -join "`n`n"
    }
    finally { $process.Dispose() }
}
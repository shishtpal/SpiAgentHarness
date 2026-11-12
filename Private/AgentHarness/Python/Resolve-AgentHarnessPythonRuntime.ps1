function Resolve-AgentHarnessPythonRuntime {
    param([string]$WorkingDirectory, [datetime]$Deadline)

    $ErrorActionPreference = 'Stop'
    $probeCode = 'import sys; print("SPI_AGENT_PYTHON_3" if sys.version_info.major == 3 else "UNSUPPORTED")'
    foreach ($kind in 'uv', 'python', 'python3', 'SPI_AGENT_PYTHON') {
        $executable = $null
        if ($kind -eq 'SPI_AGENT_PYTHON') {
            $configured = [Environment]::GetEnvironmentVariable('SPI_AGENT_PYTHON')
            try {
                if (-not [string]::IsNullOrWhiteSpace($configured) -and [IO.Path]::IsPathFullyQualified($configured) -and
                    (Test-Path -LiteralPath $configured -PathType Leaf -ErrorAction Stop)) {
                    $executable = $configured
                }
            }
            catch { $executable = $null }
        }
        else {
            $command = Get-Command -Name $kind -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) { $executable = $command.Source }
        }

        if (-not $executable) { continue }
        $remaining = [int][Math]::Ceiling(($Deadline - [datetime]::UtcNow).TotalSeconds)
        if ($remaining -lt 1) { throw 'Python runtime discovery exhausted timeout_sec before code execution.' }

        $prefix = if ($kind -eq 'uv') { @('run', '--no-config', '--no-project', '--python', '3') } else { @() }
        $probeArguments = @($prefix)
        if ($kind -eq 'uv') { $probeArguments += 'python' }

        $probeArguments += @('-X', 'utf8', '-u', '-c', $probeCode)
        $process = $null
        try {
            $probeLimit = if ($kind -eq 'uv') { 30 } else { 5 }
            $process = New-AgentHarnessNativeProcess -Executable $executable -ArgumentList $probeArguments `
                -WorkingDirectory $WorkingDirectory -TimeoutSec ([Math]::Min($probeLimit, $remaining))
            while (-not $process.Wait(100)) { }
            $snapshot = $process.Snapshot()
            if ($snapshot.State -eq 'exited' -and $snapshot.ExitCode -eq 0 -and
                -not $snapshot.CaptureIncomplete -and $snapshot.Output.Trim() -ceq 'SPI_AGENT_PYTHON_3') {
                return @{ Kind = $kind; Executable = $executable; Prefix = @($prefix) }
            }
        }
        catch {
            # A missing, stale or nonworking runtime must not block later candidates.
            # Do not echo probe output or environment configuration into errors.
        }
        finally { if ($null -ne $process) { $process.Dispose() } }
    }
    throw 'No usable Python 3 runtime found. Install uv or Python on PATH, or set SPI_AGENT_PYTHON to an absolute Python executable path.'
}
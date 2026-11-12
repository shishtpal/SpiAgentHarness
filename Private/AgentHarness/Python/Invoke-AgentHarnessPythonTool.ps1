function Invoke-AgentHarnessPythonTool {
    param([hashtable]$Arguments, [hashtable]$Context)

    $ErrorActionPreference = 'Stop'
    foreach ($key in $Arguments.Keys) {
        if ($key -cnotin @('code', 'timeout_sec', 'packages')) { throw "Unknown Python argument: $key" }
    }

    if ($Arguments.code -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments.code)) { throw 'code must be a nonblank string.' }
    if ($Arguments.code.Length -gt 1MB) { throw 'code cannot exceed 1,048,576 characters.' }

    $timeout = 60
    if ($Arguments.ContainsKey('timeout_sec')) {
        $value = $Arguments.timeout_sec
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 86400) {
            throw 'timeout_sec must be an integer from 1 to 86400.'
        }
        $timeout = [int]$value
    }

    $packages = @()
    if ($Arguments.ContainsKey('packages')) {
        if ($Arguments.packages -isnot [array] -or $Arguments.packages.Count -gt 64) { throw 'packages must be an array of at most 64 package requirements.' }
        foreach ($package in $Arguments.packages) {
            if ($package -isnot [string] -or [string]::IsNullOrWhiteSpace($package) -or $package.Length -gt 512 -or
                $package.StartsWith('-') -or $package -match '[\x00-\x1f\x7f]') {
                throw 'Each package must be a nonblank requirement of at most 512 characters, without control characters or a leading dash.'
            }
            $packages += $package
        }
    }

    $packageLabel = if ($packages.Count) { $packages -join ', ' } else { '(none)' }
    $description = "run Python (deadline ${timeout}s, including setup; uv downloads allowed; packages: $packageLabel):`n$($Arguments.code)"
    if (-not (Confirm-AgentHarnessAction $Context $description)) { return 'ERROR: the user denied this command.' }

    $deadline = [datetime]::UtcNow.AddSeconds($timeout)
    $runtime = Resolve-AgentHarnessPythonRuntime -WorkingDirectory $Context.Root -Deadline $deadline
    $nativeArguments = @($runtime.Prefix)
    if ($runtime.Kind -eq 'uv') {
        foreach ($package in $packages) { $nativeArguments += @('--with', $package) }
        $nativeArguments += 'python'
    }
    elseif ($packages.Count) { throw 'Package installation requires a usable uv runtime. Direct Python uses only installed packages; no code was executed.' }

    $nativeArguments += @('-X', 'utf8', '-u', '-')
    $remaining = [int][Math]::Ceiling(($deadline - [datetime]::UtcNow).TotalSeconds)
    if ($remaining -lt 1) { throw 'Python setup exhausted timeout_sec before code execution.' }
    $limit = if ($Context.MaxToolOutputChars) { [int]$Context.MaxToolOutputChars } else { 8000 }

    $process = $null
    try {
        $process = New-AgentHarnessNativeProcess -Executable $runtime.Executable -ArgumentList $nativeArguments `
            -WorkingDirectory $Context.Root -TimeoutSec $remaining -InputText $Arguments.code
        while (-not $process.Wait(100)) { }

        $snapshot = $process.Snapshot()
        $header = "runtime: $($runtime.Kind)`nstate: $($snapshot.State)`ndeadline: ${timeout} seconds"
        if ($snapshot.State -eq 'timed_out') {
            $header = "ERROR: Python execution timed out.`n$header"
        }
        elseif ($null -ne $snapshot.ExitCode -and $snapshot.ExitCode -ne 0) {
            $header = "ERROR: Python exited with code $($snapshot.ExitCode).`n$header"
        }

        $result = Format-AgentHarnessShellResult -Process $process -MaxOutputChars ([Math]::Max(0, $limit - $header.Length - 2))
        "$header`n`n$result"
    }
    finally { if ($null -ne $process) { $process.Dispose() } }
}
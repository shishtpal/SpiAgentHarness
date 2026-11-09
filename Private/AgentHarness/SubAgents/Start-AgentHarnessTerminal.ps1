function Start-AgentHarnessTerminal {
    param([string]$EncodedCommand, [string]$WorkingDirectory, [string]$KeyVariable, [string]$ApiKey)

    if (-not $IsWindows) { throw 'Visible sub-agent terminals currently require Windows.' }
    # Start-Process uses a new console window on Windows. Only an encoded bootstrap,
    # never a task or credential, is placed on the command line.
    $previousValue = $null
    if ($KeyVariable) {
        $previousValue = [Environment]::GetEnvironmentVariable($KeyVariable, 'Process')
        [Environment]::SetEnvironmentVariable($KeyVariable, $ApiKey, 'Process')
    }
    try {
        $executable = (Get-Process -Id $PID -ErrorAction Stop).Path
        Start-Process -FilePath $executable -ArgumentList @('-NoProfile', '-NoExit', '-EncodedCommand', $EncodedCommand) `
            -WorkingDirectory $WorkingDirectory -WindowStyle Normal -PassThru -ErrorAction Stop
    }
    finally {
        if ($KeyVariable) { [Environment]::SetEnvironmentVariable($KeyVariable, $previousValue, 'Process') }
    }
}
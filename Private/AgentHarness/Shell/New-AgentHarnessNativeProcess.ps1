function New-AgentHarnessNativeProcess {
    param(
        [string]$Executable,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [int]$TimeoutSec,
        [AllowNull()][object]$InputText = $null
    )

    if (-not ('SpiAgentHarness.ShellProcess' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'ShellProcess.cs') -ErrorAction Stop
    }
    $inputValue = if ($null -eq $InputText) { $null } else { [string]$InputText }
    [SpiAgentHarness.ShellProcess]::new($Executable, $ArgumentList, $WorkingDirectory, $TimeoutSec, $inputValue, $true)
}
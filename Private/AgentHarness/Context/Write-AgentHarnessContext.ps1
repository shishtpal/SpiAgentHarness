function Write-AgentHarnessContext {
    param(
        [string]$Path, [ValidateSet('Raw', 'Pruned', 'Summary')][string]$Mode,
        [object[]]$Messages, [hashtable]$Context,
        [string]$Provider, [string]$Model, [string]$ChatUri, [string]$ApiKey,
        [int]$TimeoutSec = 120, [scriptblock]$Log,
        [ValidateSet('', 'provider_failure', 'iteration_limit')][string]$StopReason = ''
    )

    $ErrorActionPreference = 'Stop'
    $full = Resolve-AgentHarnessContextPath -Root $Context.Root -Path $Path
    $snapshot = New-AgentHarnessContext -Mode $Mode -Messages $Messages -Context $Context `
        -Provider $Provider -Model $Model -ChatUri $ChatUri -ApiKey $ApiKey -TimeoutSec $TimeoutSec -Log $Log -StopReason $StopReason
    $json = ConvertTo-Json -InputObject $snapshot -Depth 30 -WarningAction Stop
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    if ($bytes.Length -gt 64MB) { throw 'Context files cannot exceed 64 MiB.' }
    $directory = [IO.Path]::GetDirectoryName($full)
    $null = [IO.Directory]::CreateDirectory($directory)
    $null = Resolve-AgentHarnessContextPath -Root $Context.Root -Path $Path
    $temporary = Join-Path $directory ('.context-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        $null = Resolve-AgentHarnessContextPath -Root $Context.Root -Path $Path
        [IO.File]::Move($temporary, $full, $true)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    if ($StopReason) { $Context.RecoveryContextPath = $full }
    else { $Context.SavedContextPath = $full }
    $full
}
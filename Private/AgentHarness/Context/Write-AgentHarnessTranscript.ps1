function Write-AgentHarnessTranscript {
    param([string]$Path, [object]$Value, [hashtable]$Context, [switch]$Replace)

    $ErrorActionPreference = 'Stop'
    $full = Resolve-AgentHarnessStatePath -Root $Context.Root -Path $Path
    $json = ConvertTo-Json -InputObject $Value -Depth 30 -WarningAction Stop
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    if ($bytes.Length -gt 64MB) { throw 'Transcript files cannot exceed 64 MiB.' }
    $directory = [IO.Path]::GetDirectoryName($full)
    $null = [IO.Directory]::CreateDirectory($directory)
    $null = Resolve-AgentHarnessStatePath -Root $Context.Root -Path $full
    $temporary = Join-Path $directory ('.transcript-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        $null = Resolve-AgentHarnessStatePath -Root $Context.Root -Path $full
        [IO.File]::Move($temporary, $full, [bool]$Replace)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    $full
}
function Write-AgentHarnessSubAgentJson {
    param([string]$Root, [string]$Path, [object]$Value)

    $full = Resolve-AgentHarnessStatePath -Root $Root -Path $Path
    $directory = [IO.Path]::GetDirectoryName($full)
    $null = [IO.Directory]::CreateDirectory($directory)
    $null = Resolve-AgentHarnessStatePath -Root $Root -Path $full
    $temporary = Join-Path $directory ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 30), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $full, $true)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
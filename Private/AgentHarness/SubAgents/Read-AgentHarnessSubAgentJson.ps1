function Read-AgentHarnessSubAgentJson {
    param([string]$Root, [string]$Path)

    $full = Resolve-AgentHarnessStatePath -Root $Root -Path $Path
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or $item.Length -gt 2MB) { throw 'Invalid or oversized sub-agent state file.' }
    $value = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($full)) -AsHashtable -NoEnumerate -ErrorAction Stop
    if ($value -isnot [hashtable]) { throw 'Sub-agent state must be a JSON object.' }
    $value
}
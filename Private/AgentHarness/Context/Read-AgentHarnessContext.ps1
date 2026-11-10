function Read-AgentHarnessContext {
    param([string]$Root, [string]$Path)

    $ErrorActionPreference = 'Stop'
    $full = Resolve-AgentHarnessContextPath -Root $Root -Path $Path
    # Bound the read itself, including a file that grows after its initial length check.
    $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 64MB) { throw 'Context files cannot exceed 64 MiB.' }
        $reader = [IO.BinaryReader]::new($stream)
        try { $bytes = $reader.ReadBytes([int][Math]::Min($stream.Length + 1, 64MB + 1)) }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
    if ($bytes.Length -gt 64MB) { throw 'Context files cannot exceed 64 MiB.' }
    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
        $snapshot = ConvertFrom-AgentHarnessContextJson -Json $json
    }
    catch { throw 'Context file must contain valid UTF-8 JSON.' }
    if ($snapshot -is [Collections.IDictionary] -and $snapshot.format -ceq 'SpiAgentHarness.Transcript') {
        throw 'Transcript archives cannot be loaded with -ContextPath; they are pre-compaction recovery data.'
    }
    if ($snapshot -isnot [Collections.IDictionary] -or $snapshot.format -cne 'SpiAgentHarness.Context' -or ($snapshot.version -isnot [long] -and $snapshot.version -isnot [int]) -or $snapshot.version -ne 1) {
        throw 'Unsupported context format or version.'
    }
    if ($snapshot.mode -isnot [string] -or $snapshot.mode -cnotin @('raw', 'pruned', 'summary') -or $snapshot.messages -isnot [array]) { throw 'Context mode or messages are invalid.' }
    foreach ($field in 'sessionId', 'createdAt', 'workingDirectory', 'provider', 'model') {
        if ($snapshot[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($snapshot[$field])) { throw 'Context metadata is invalid.' }
    }
    if ($snapshot.mode -eq 'summary') {
        Assert-AgentHarnessContextSummary -Summary $snapshot.summary
    }
    $snapshot.messages = ConvertTo-AgentHarnessContextMessages -Messages $snapshot.messages
    $snapshot
}
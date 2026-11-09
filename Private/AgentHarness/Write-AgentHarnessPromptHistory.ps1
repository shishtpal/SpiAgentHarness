function Write-AgentHarnessPromptHistory {
    param([hashtable]$Context, [string]$Type, [AllowEmptyString()][string]$Text, [hashtable]$Data)

    $journal = $Context.PromptHistory
    if (-not $journal -or $journal.Failed) { return }
    # Logging failures must not prevent input from reaching the agent, even with Continue.
    $ErrorActionPreference = 'Stop'
    try {
        $path = Resolve-AgentHarnessStatePath -Root $Context.Root -Path $journal.RelativePath
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        $path = Resolve-AgentHarnessStatePath -Root $Context.Root -Path $journal.RelativePath
        $entry = [ordered]@{
            version   = 1
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            sessionId = $journal.SessionId
            sequence  = $journal.Sequence + 1
            type      = $Type
            text      = $Text
        }
        if ($null -ne $Data) { $entry.data = $Data }
        $json = ConvertTo-Json -InputObject $entry -Depth 12 -Compress
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`r`n")
        # Never overwrite a pre-existing session file; invocations have unique IDs.
        $mode = if ($journal.Sequence -eq 0) { [IO.FileMode]::CreateNew } else { [IO.FileMode]::Append }
        $stream = [IO.File]::Open($path, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        $journal.Sequence++
        $journal.Path = $path
    }
    catch {
        $journal.Failed = $true
        # Avoid exposing input or connection details through exception messages.
        Write-Warning 'Prompt history could not be saved. Recording is disabled for this invocation; the harness will continue.' -WarningAction Continue
    }
}
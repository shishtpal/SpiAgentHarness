function Invoke-AgentHarnessFileWrite {
    param([hashtable]$Arguments, [hashtable]$Context, [string]$Name = 'write_file')

    $ErrorActionPreference = 'Stop'
    if (-not $Context.FileWriteState) { $Context.FileWriteState = New-AgentHarnessFileWriteState }
    $state = $Context.FileWriteState
    Assert-AgentHarnessFileWriteArguments -Arguments $Arguments -Name $Name -State $state
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $bytes = $null
    if ($Name -in 'write_file', 'write_file_chunk') {
        $byteCount = $encoding.GetByteCount($Arguments.content)
        $limit = if ($Name -eq 'write_file_chunk') { $state.Limits.MaxChunkBytes } else { $state.Limits.MaxFileBytes }
        if ($byteCount -gt $limit) { throw "Content exceeds $limit UTF-8 bytes; use smaller staged chunks." }
        $bytes = $encoding.GetBytes($Arguments.content)
        Write-AgentHarnessPayloadDiagnostic -Context $Context -Data @{
            boundary = 'encoded'; chars = $Arguments.content.Length; bytes = $bytes.Length
            sha256 = (Get-AgentHarnessFileWriteHash -Bytes $bytes)
        }
    }
    if ($Name -eq 'write_file') {
        Assert-AgentHarnessFileWriteExpectation -Arguments $Arguments -Bytes $bytes
        $snapshot = Get-AgentHarnessWriteDestination -Root $Context.Root -Path $Arguments.path
        $receipt = Save-AgentHarnessFileCandidate -Context $Context -Path $Arguments.path -Bytes $bytes -Content $Arguments.content -Snapshot $snapshot
        if (-not $receipt) { return 'ERROR: the user denied this write.' }
        return 'Wrote {0} chars ({1} UTF-8 bytes) to {2}; SHA-256 {3}; verified.' -f $receipt.chars, $receipt.bytes, $receipt.path, $receipt.sha256
    }
    if ($Name -eq 'begin_file_write') {
        $active = @($state.Sessions.Values | Where-Object { $_.Stage }).Count
        if ($active -ge $state.Limits.MaxActiveSessions -or $state.Sessions.Count -ge $state.Limits.MaxReceipts) { throw 'File-write session limit reached; finish or abort active sessions, or start a new invocation for more receipts.' }
        if ($state.ReservedBytes + $Arguments.expected_bytes -gt $state.Limits.MaxStagedBytes) { throw 'File-write staging quota exceeded.' }
        $snapshot = Get-AgentHarnessWriteDestination -Root $Context.Root -Path $Arguments.path
        $id = [guid]::NewGuid().ToString('N')
        $beginReceipt = ConvertTo-Json -InputObject @{
            write_id = $id; state = 'open'; expected_bytes = $Arguments.expected_bytes; next_offset_bytes = 0
            max_chunk_bytes = $state.Limits.MaxChunkBytes; max_argument_bytes = $state.Limits.MaxArgumentBytes
        } -Compress
        if ($Context.FileWriteOutputLimit -gt 0 -and $beginReceipt.Length -gt $Context.FileWriteOutputLimit) {
            throw 'Begin receipt cannot fit MaxToolOutputChars; no session was created. Increase the output limit.'
        }
        if (-not $state.StagingRoot) {
            $state.StagingRoot = New-AgentHarnessFileWriteDirectory
        }
        $stage = [IO.Path]::Combine($state.StagingRoot, ($id + '.tmp'))
        $null = Get-AgentHarnessWriteDestination -Root $state.StagingRoot -Path ($id + '.tmp')
        $stream = [IO.File]::Open($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
        $state.Sessions[$id] = @{
            Id = $id; Path = $Arguments.path; Stage = $stage; Snapshot = $snapshot; State = 'open'
            ExpectedBytes = [long]$Arguments.expected_bytes; ExpectedHash = $Arguments.expected_sha256
            ReceivedBytes = [long]0; Chunks = @{}; Receipt = $null; Error = $null
        }
        $state.ReservedBytes += $Arguments.expected_bytes
        return $beginReceipt
    }
    $session = $state.Sessions[$Arguments.write_id]
    if (-not $session) { throw 'Unknown write_id for this invocation; begin a new file write.' }
    if ($Name -eq 'get_file_write_status') {
        return ConvertTo-Json -InputObject @{
            write_id = $session.Id; state = $session.State; expected_bytes = $session.ExpectedBytes
            received_bytes = $session.ReceivedBytes; next_offset_bytes = $session.ReceivedBytes
            receipt = $session.Receipt; error = $session.Error
        } -Compress -Depth 5
    }
    if ($Name -eq 'abort_file_write') {
        if ($session.State -eq 'committed') { throw 'This write was committed; abort cannot undo it.' }
        Remove-AgentHarnessFileWriteStage -State $state -Session $session
        if ($session.State -ne 'failed') { $session.State = 'aborted' }
        return ConvertTo-Json -InputObject @{ write_id = $session.Id; state = $session.State } -Compress
    }
    if ($Name -eq 'commit_file_write' -and $session.State -eq 'committed') {
        return ConvertTo-Json -InputObject $session.Receipt -Compress
    }
    if ($session.State -ne 'open') { throw "File-write session is $($session.State); it cannot accept this operation." }
    $null = Get-AgentHarnessWriteDestination -Root $state.StagingRoot -Path ($session.Id + '.tmp') -SkipHash
    if ($Name -eq 'write_file_chunk') {
        if (-not $bytes.Length) { throw 'Chunks must be nonempty; commit a zero-byte file without chunks.' }
        $offset = [long]$Arguments.offset_bytes
        $retry = $session.Chunks[$offset]
        if ($retry) {
            if ($retry.length -ne $bytes.Length) { throw 'Conflicting retry at this chunk offset.' }
            $stream = [IO.File]::Open($session.Stage, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $null = $stream.Seek($offset, [IO.SeekOrigin]::Begin)
                $existing = [byte[]]::new($bytes.Length)
                $read = 0
                while ($read -lt $existing.Length) {
                    $count = $stream.Read($existing, $read, $existing.Length - $read)
                    if (-not $count) { throw 'Staging file changed while inspecting a retry.' }
                    $read += $count
                }
                if ([Convert]::ToBase64String($existing) -cne [Convert]::ToBase64String($bytes)) { throw 'Conflicting retry at this chunk offset.' }
            }
            finally { $stream.Dispose() }
            return ConvertTo-Json -InputObject $retry.receipt -Compress
        }
        if ($offset -ne $session.ReceivedBytes) { throw "Chunk offset must be $($session.ReceivedBytes); gaps and overlaps are rejected." }
        if ($offset + $bytes.Length -gt $session.ExpectedBytes) { throw 'Chunk exceeds declared expected_bytes.' }
        if ($session.Chunks.Count -ge $state.Limits.MaxChunks) { throw 'File-write chunk count limit reached.' }
        try {
            $stream = [IO.File]::Open($session.Stage, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                if ($stream.Length -ne $offset) { throw 'Staging file length changed.' }
                $null = $stream.Seek($offset, [IO.SeekOrigin]::Begin)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            }
            finally { $stream.Dispose() }
        }
        catch {
            $session.State = 'failed'; $session.Error = 'Staging write failed; begin a new file write.'
            Remove-AgentHarnessFileWriteStage -State $state -Session $session
            throw $session.Error
        }
        $session.ReceivedBytes += $bytes.Length
        $receipt = @{ write_id = $session.Id; accepted_bytes = $bytes.Length; next_offset_bytes = $session.ReceivedBytes; state = 'open' }
        $session.Chunks[$offset] = @{ length = $bytes.Length; receipt = $receipt; hash = (Get-AgentHarnessFileWriteHash -Bytes $bytes) }
        return ConvertTo-Json -InputObject $receipt -Compress
    }
    if ($Name -ne 'commit_file_write') { throw 'Unknown file-write operation.' }
    if ($session.ReceivedBytes -ne $session.ExpectedBytes) { throw "Incomplete file: received $($session.ReceivedBytes) of $($session.ExpectedBytes) expected bytes; no destination was changed." }
    # Read only the declared bounded size, detecting an externally grown staging file before allocation.
    $stream = [IO.File]::Open($session.Stage, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -ne $session.ExpectedBytes) { throw 'Staging file size differs from expected_bytes.' }
        $candidate = [byte[]]::new([int]$session.ExpectedBytes)
        $read = 0
        while ($read -lt $candidate.Length) {
            $count = $stream.Read($candidate, $read, $candidate.Length - $read)
            if (-not $count) { throw 'Staging file changed while reading.' }
            $read += $count
        }
        if ($stream.ReadByte() -ne -1) { throw 'Staging file grew while reading.' }
    }
    finally { $stream.Dispose() }
    foreach ($offset in $session.Chunks.Keys) {
        $chunk = $session.Chunks[$offset]
        if ((Get-AgentHarnessFileWriteHash -Bytes $candidate -Offset ([int]$offset) -Count $chunk.length) -cne $chunk.hash) {
            $session.State = 'failed'; $session.Error = 'Staging integrity check failed; begin a new file write.'
            Remove-AgentHarnessFileWriteStage -State $state -Session $session
            throw $session.Error
        }
    }
    $expectation = @{ expected_bytes = $session.ExpectedBytes }
    if ($session.ExpectedHash) { $expectation.expected_sha256 = $session.ExpectedHash }
    Assert-AgentHarnessFileWriteExpectation -Arguments $expectation -Bytes $candidate
    $content = $encoding.GetString($candidate)
    $session.State = 'committing'
    try {
        $receipt = Save-AgentHarnessFileCandidate -Context $Context -Path $session.Path -Bytes $candidate -Content $content -Snapshot $session.Snapshot
        if (-not $receipt) {
            $session.State = 'aborted'
            return 'ERROR: the user denied this write; staging session aborted.'
        }
        $receipt.write_id = $session.Id
        $receipt.state = 'committed'
        $session.Receipt = $receipt
        $session.State = 'committed'
        return ConvertTo-Json -InputObject $receipt -Compress
    }
    catch {
        $session.State = 'failed'
        $session.Error = if ($_.Exception.Data['FileWriteMayHaveChanged']) { 'Destination may already have changed; inspect before retrying.' } else { 'Commit failed; destination was not replaced by this operation.' }
        throw
    }
    finally { Remove-AgentHarnessFileWriteStage -State $state -Session $session }
}

function Assert-AgentHarnessFileWriteExpectation {
    param([hashtable]$Arguments, [byte[]]$Bytes)

    if ($Arguments.ContainsKey('expected_bytes') -and $Arguments.expected_bytes -ne $Bytes.Length) { throw "Content byte count $($Bytes.Length) differs from expected_bytes $($Arguments.expected_bytes); no destination was changed." }
    if ($Arguments.ContainsKey('expected_sha256') -and (Get-AgentHarnessFileWriteHash -Bytes $Bytes) -ine $Arguments.expected_sha256) {
        throw 'Content SHA-256 differs from expected_sha256; no destination was changed.'
    }
}
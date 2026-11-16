function Save-AgentHarnessFileCandidate {
    param([hashtable]$Context, [string]$Path, [byte[]]$Bytes, [string]$Content, [hashtable]$Snapshot)

    $ErrorActionPreference = 'Stop'
    $hash = Get-AgentHarnessFileWriteHash -Bytes $Bytes
    Assert-AgentHarnessWriteDestination -Context $Context -Path $Path -Snapshot $Snapshot
    if (-not (Confirm-AgentHarnessFileWrite -Context $Context -Path $Path -Content $Content -ByteCount $Bytes.Length -Hash $hash)) { return $null }
    $temporary = $null
    $createdDirectories = [Collections.Generic.List[string]]::new()
    $saved = $false
    try {
        Assert-AgentHarnessWriteDestination -Context $Context -Path $Path -Snapshot $Snapshot
        $missing = [Collections.Generic.Stack[string]]::new()
        $parent = [IO.Path]::GetDirectoryName($Snapshot.File)
        while (-not [IO.Directory]::Exists($parent)) {
            $missing.Push($parent)
            $parent = [IO.Path]::GetDirectoryName($parent)
        }
        while ($missing.Count) {
            $directory = $missing.Pop()
            $null = [IO.Directory]::CreateDirectory($directory)
            $createdDirectories.Add($directory)
            Assert-AgentHarnessWriteDestination -Context $Context -Path $Path -Snapshot $Snapshot
        }
        $temporary = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Snapshot.File), ('.agentharness-' + [guid]::NewGuid().ToString('N') + '.tmp'))
        if ($Snapshot.Exists) { [IO.File]::Copy($Snapshot.File, $temporary, $false) }
        $mode = if ($Snapshot.Exists) { [IO.FileMode]::Open } else { [IO.FileMode]::CreateNew }
        $stream = [IO.File]::Open($temporary, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.SetLength(0)
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        if ((Get-AgentHarnessFileWriteHash -Path $temporary) -cne $hash) { throw 'Staged file verification failed; destination was not replaced.' }
        Assert-AgentHarnessWriteDestination -Context $Context -Path $Path -Snapshot $Snapshot
        if ($Snapshot.Exists) { [IO.File]::Replace($temporary, $Snapshot.File, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Snapshot.File) }
        $saved = $true
        $actual = Get-AgentHarnessWriteDestination -Root $Context.Root -Path $Path
        if ($actual.Length -ne $Bytes.Length -or $actual.Hash -cne $hash) { throw 'Post-save file verification failed.' }
        $receipt = @{ path = $Path; chars = $Content.Length; bytes = $Bytes.Length; sha256 = $hash; verified = $true }
        Write-AgentHarnessPayloadDiagnostic -Context $Context -Data @{ boundary = 'disk'; bytes = $Bytes.Length; sha256 = $hash }
        return $receipt
    }
    catch {
        if ($saved) {
            $failure = [Exception]::new('File may already have changed; post-save verification failed. Inspect the destination before retrying.')
            $failure.Data['FileWriteMayHaveChanged'] = $true
            throw $failure
        }
        throw
    }
    finally {
        if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if (-not $saved) {
            for ($i = $createdDirectories.Count - 1; $i -ge 0; $i--) {
                try { [IO.Directory]::Delete($createdDirectories[$i], $false) } catch { }
            }
        }
    }
}
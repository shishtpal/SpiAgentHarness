function Remove-AgentHarnessFileWriteStage {
    param([hashtable]$State, [hashtable]$Session)

    if (-not $Session.Stage) { return }
    $expected = [IO.Path]::Combine($State.StagingRoot, ($Session.Id + '.tmp'))
    if ([IO.Path]::GetFullPath($Session.Stage) -cne $expected) { throw 'Invalid owned file-write staging path.' }
    $null = Get-AgentHarnessWriteDestination -Root $State.StagingRoot -Path ($Session.Id + '.tmp') -SkipHash
    if ([IO.File]::Exists($expected)) { [IO.File]::Delete($expected) }
    $Session.Stage = $null
    $Session.Chunks.Clear()
    $State.ReservedBytes -= $Session.ExpectedBytes
}

function Close-AgentHarnessFileWrites {
    param([hashtable]$Context)

    $state = $Context.FileWriteState
    if (-not $state) { return }
    foreach ($session in $state.Sessions.Values) {
        try { Remove-AgentHarnessFileWriteStage -State $state -Session $session }
        catch { Write-Warning 'Could not clean an owned file-write staging file.' }
    }
    if ($state.StagingRoot) {
        try { [IO.Directory]::Delete($state.StagingRoot, $false) }
        catch { Write-Warning 'Could not remove the file-write staging directory.' }
    }
}
function Get-AgentHarnessWriteDestination {
    param([string]$Root, [string]$Path, [switch]$SkipHash)

    $file = Resolve-AgentHarnessPath -Root $Root -Path $Path
    if ($IsWindows -and [IO.Path]::GetRelativePath($Root, $file).Contains(':')) {
        throw 'File writes do not support alternate data streams.'
    }
    $target = $null
    $currentPath = $file
    while ($currentPath) {
        $item = $null
        try { $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop }
        catch [Management.Automation.ItemNotFoundException] { }
        if ($item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'File writes do not follow symbolic links, junctions or other reparse points.'
            }
            if ($currentPath -eq $file) {
                if ($item -isnot [IO.FileInfo]) { throw 'File writes require a file destination.' }
                if ($item.IsReadOnly) { throw 'File writes cannot replace a read-only file.' }
                $target = $item
            }
            elseif ($item -isnot [IO.DirectoryInfo]) { throw 'A file blocks a destination directory.' }
        }
        $parent = [IO.Path]::GetDirectoryName($currentPath)
        if ($parent -eq $currentPath) { break }
        $currentPath = $parent
    }
    if (-not $target) { return @{ File = $file; Exists = $false; Hash = $null; Length = [long]0; Ticks = [long]0; Attributes = 0 } }
    $length = $target.Length
    $ticks = $target.LastWriteTimeUtc.Ticks
    $attributes = $target.Attributes
    $hash = if ($SkipHash) { $null } else { Get-AgentHarnessFileWriteHash -Path $file }
    $target.Refresh()
    if (-not $target.Exists -or $target.Length -ne $length -or $target.LastWriteTimeUtc.Ticks -ne $ticks -or $target.Attributes -ne $attributes) {
        throw 'Destination changed while being inspected; prepare the write again.'
    }
    @{ File = $file; Exists = $true; Hash = $hash; Length = $length; Ticks = $ticks; Attributes = $attributes }
}

function Assert-AgentHarnessWriteDestination {
    param([hashtable]$Context, [string]$Path, [hashtable]$Snapshot)

    $current = Get-AgentHarnessWriteDestination -Root $Context.Root -Path $Path
    if ($current.Exists -ne $Snapshot.Exists -or $current.Hash -cne $Snapshot.Hash -or
        $current.Length -ne $Snapshot.Length -or $current.Ticks -ne $Snapshot.Ticks -or $current.Attributes -ne $Snapshot.Attributes) {
        throw 'Destination changed since the write was prepared; read it again and start a new write.'
    }
}
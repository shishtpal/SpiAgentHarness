function Resolve-AgentHarnessEditPath {
    param([string]$Root, [string]$Path)

    $file = Resolve-AgentHarnessPath -Root $Root -Path $Path
    # A colon in a relative Windows path could select an alternate data stream.
    if ($IsWindows -and [IO.Path]::GetRelativePath($Root, $file).Contains(':')) {
        throw 'edit_file does not support alternate data streams.'
    }
    $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo]) { throw 'edit_file requires an existing local text file.' }
    if ($item.IsReadOnly) { throw 'edit_file cannot edit a read-only file.' }
    # Check every ancestor, including the working root and its parents.
    $current = $item
    while ($null -ne $current) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'edit_file does not follow symbolic links, junctions or other reparse points.'
        }
        $current = if ($current -is [IO.FileInfo]) { $current.Directory } else { $current.Parent }
    }
    $file
}
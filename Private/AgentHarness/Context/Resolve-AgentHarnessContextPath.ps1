function Resolve-AgentHarnessContextPath {
    param([string]$Root, [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Context path cannot be blank.' }
    # Like explicit attachments, user-selected context files may be outside the project.
    $full = [IO.Path]::GetFullPath($Path, $Root)
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current -ErrorAction Stop) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Context paths cannot contain symbolic links, junctions or reparse points.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
    if (Test-Path -LiteralPath $full -PathType Container -ErrorAction Stop) { throw 'Context path must name a file.' }
    $full
}
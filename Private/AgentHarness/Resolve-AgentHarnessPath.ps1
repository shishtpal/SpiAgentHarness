function Resolve-AgentHarnessPath {
    # Resolve a path relative to $Root and refuse anything that escapes it.
    param([string]$Root, [string]$Path)
    if (-not $Path) { $Path = '.' }
    $sep = [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $Path))
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd($sep, [IO.Path]::AltDirectorySeparatorChar)
    $cmp = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $full.Equals($rootFull, $cmp) -and -not $full.StartsWith($rootFull + $sep, $cmp)) {
        throw "Path escapes the working directory: $Path"
    }
    $full
}
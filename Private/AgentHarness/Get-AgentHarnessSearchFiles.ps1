function Get-AgentHarnessSearchFiles {
    # Enumerate eligible files without descending into ignored directories.
    param(
        [string]$Root,
        [string]$Path,
        [string]$Filter = '*',
        [object]$IgnoreDirectories = @(),
        [object]$ExcludeFiles = @(),
        [Diagnostics.Stopwatch]$Stopwatch,
        [double]$TimeoutSeconds = 10
    )

    if ($IgnoreDirectories -isnot [array]) { throw 'ignore_dirs must be an array of directory names.' }
    $ignored = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('.git', 'node_modules', 'dist', 'bin') + $IgnoreDirectories) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or
            $name -in '.', '..' -or $name.IndexOfAny([char[]]'\/[*?]') -ge 0) {
            throw 'ignore_dirs entries must be non-empty literal directory names, without paths or wildcards.'
        }
        $null = $ignored.Add($name)
    }
    if ($ExcludeFiles -isnot [array]) { throw 'exclude_files must be an array of file names.' }
    $excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('Initialize.ps1') + $ExcludeFiles) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or
            $name -in '.', '..' -or $name.IndexOfAny([char[]]'\/[*?]') -ge 0) {
            throw 'exclude_files entries must be non-empty literal file names, without paths or wildcards.'
        }
        $null = $excluded.Add($name)
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop)) {
        throw 'Search path must be an existing directory.'
    }

    # Explicit subdirectory searches must also respect ignored ancestors below Root.
    $relative = [IO.Path]::GetRelativePath($Root, $Path)
    if ($relative -ne '.') {
        foreach ($part in ($relative -split '[\\/]')) {
            if ($ignored.Contains($part)) { return }
        }
    }

    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count) {
        if ($Stopwatch -and $Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw 'Search timed out; narrow path or glob, or add ignore_dirs.'
        }
        $directory = $pending.Pop()
        Get-ChildItem -LiteralPath $directory -File -Filter $Filter -ErrorAction Stop | Sort-Object Name | ForEach-Object {
            if (-not $excluded.Contains($_.Name) -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $_ }
        }
        # Reverse the push order so the stack visits subdirectories alphabetically.
        foreach ($child in Get-ChildItem -LiteralPath $directory -Directory -ErrorAction Stop | Sort-Object Name -Descending) {
            if ($Stopwatch -and $Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw 'Search timed out; narrow path or glob, or add ignore_dirs.'
            }
            # Like Get-ChildItem -Recurse, do not follow directory symlinks/junctions.
            if (-not $ignored.Contains($child.Name) -and -not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending.Push($child.FullName)
            }
        }
    }
}
function Find-AgentHarnessFileText {
    # Bound regex work and scan time; stream lines instead of loading whole files.
    param(
        [string]$Root,
        [string]$Path,
        [string]$Pattern,
        [string]$Filter = '*',
        [object]$IgnoreDirectories = @(),
        [object]$ExcludeFiles = @(),
        [double]$TimeoutSeconds = 10,
        [int]$RegexTimeoutMilliseconds = 250,
        [long]$MaxFileBytes = 10MB
    )

    $regex = [regex]::new($Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase,
        [TimeSpan]::FromMilliseconds($RegexTimeoutMilliseconds))
    if (-not (Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop)) {
        throw 'Search path must be an existing directory.'
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $skipped = 0
    $binary = 0
    $matchCount = 0
    Get-AgentHarnessSearchFiles -Root $Root -Path $Path -Filter $Filter -IgnoreDirectories $IgnoreDirectories -ExcludeFiles $ExcludeFiles `
        -Stopwatch $clock -TimeoutSeconds $TimeoutSeconds | ForEach-Object {
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw 'Search timed out; narrow path or glob, or add ignore_dirs.'
        }
        if ($_.Length -gt $MaxFileBytes) {
            $skipped++
        }
        else {
            $relative = [IO.Path]::GetRelativePath($Root, $_.FullName)
            $stream = [IO.File]::OpenRead($_.FullName)
            $reader = $null
            try {
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
                $sample = [char[]]::new(4096)
                $sampleLength = $reader.ReadBlock($sample, 0, $sample.Length)
                if ([Array]::IndexOf($sample, [char]0, 0, $sampleLength) -ge 0) {
                    $binary++
                }
                else {
                    # Recreate the decoder after rewinding so BOMs are handled again.
                    $reader.Dispose()
                    $stream.Position = 0
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
                    $lineNumber = 0
                    while ($null -ne ($line = $reader.ReadLine())) {
                        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                            throw 'Search timed out; narrow path or glob, or add ignore_dirs.'
                        }
                        $lineNumber++
                        if ($regex.IsMatch($line)) {
                            $matchCount++
                            '{0}:{1}: {2}' -f $relative, $lineNumber, $line.Trim()
                        }
                    }
                }
            }
            catch [Text.RegularExpressions.RegexMatchTimeoutException] {
                throw "Regex timed out in '$relative'; simplify pattern or narrow path/glob."
            }
            finally {
                if ($reader) { $reader.Dispose() }
                $stream.Dispose()
            }
        }
    } | Select-Object -First 50
    if ($matchCount -eq 50) {
        '...[stopped after 50 matches; more matches may exist]'
    }
    if ($skipped) {
        '...[skipped {0} files larger than {1} bytes]' -f $skipped, $MaxFileBytes
    }
    if ($binary) {
        '...[skipped {0} binary files (NUL in first 4096 decoded characters)]' -f $binary
    }
}
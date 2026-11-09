function Resolve-DecisionModelOutFile {
    param([string]$Path)

    $message = 'Cannot use OutFile. Supply a filesystem file path in an existing directory.'
    if ([string]::IsNullOrWhiteSpace($Path)) { throw $message }
    try {
        $provider = $null
        $drive = $null
        # Literal resolution: brackets in filenames are not wildcards.
        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    }
    catch { throw $message }
    if ($provider.Name -ne 'FileSystem' -or [IO.Directory]::Exists($fullPath)) { throw $message }
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrEmpty($directory) -or -not [IO.Directory]::Exists($directory)) { throw $message }
    $fullPath
}
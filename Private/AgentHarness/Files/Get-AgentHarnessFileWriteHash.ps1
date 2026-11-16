function Get-AgentHarnessFileWriteHash {
    param([byte[]]$Bytes, [string]$Path, [int]$Offset = 0, [int]$Count = -1)

    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $hash = if ($PSBoundParameters.ContainsKey('Path')) {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $sha.ComputeHash($stream)
        }
        else {
            $value = [byte[]]($Bytes ?? [byte[]]::new(0))
            if ($Count -lt 0) { $Count = $value.Length }
            $sha.ComputeHash($value, $Offset, $Count)
        }
        ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}
function Read-AgentHarnessEditFile {
    param([string]$Path)

    # Bound allocation even if the file grows after the initial path check.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 1MB) { throw 'edit_file supports files up to 1 MiB.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw 'File changed while being read. Read it again before editing.' }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw 'File changed while being read. Read it again before editing.' }
    }
    finally { $stream.Dispose() }

    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $bomLength = 0
    # UTF-32 LE must be checked before UTF-16 LE, which shares its first two bytes.
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254 -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
        $encoding = [Text.UTF32Encoding]::new($false, $true, $true); $bomLength = 4
    }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 254 -and $bytes[3] -eq 255) {
        $encoding = [Text.UTF32Encoding]::new($true, $true, $true); $bomLength = 4
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $encoding = [Text.UTF8Encoding]::new($true, $true); $bomLength = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true, $true); $bomLength = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true, $true); $bomLength = 2
    }
    try { $text = $encoding.GetString($bytes, $bomLength, $bytes.Length - $bomLength) }
    catch { throw 'edit_file requires valid UTF-8, or BOM-marked UTF-16/UTF-32 text.' }
    if ($text -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') {
        throw 'edit_file does not support binary files or text containing control characters other than tab and newlines.'
    }
    @{ Bytes = $bytes; Text = $text; Encoding = $encoding }
}
function Assert-AgentHarnessFileWriteArguments {
    param([hashtable]$Arguments, [string]$Name, [hashtable]$State)

    $fields = switch ($Name) {
        'write_file' { @('path', 'content', 'expected_bytes', 'expected_sha256') }
        'begin_file_write' { @('path', 'expected_bytes', 'expected_sha256') }
        'write_file_chunk' { @('write_id', 'offset_bytes', 'content') }
        default { @('write_id') }
    }
    foreach ($key in $Arguments.Keys) {
        if ($key -cnotin $fields) { throw "Unknown $Name argument: $key" }
    }
    if ($Name -in 'write_file', 'begin_file_write') {
        if ($Arguments.path -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments.path)) {
            throw "$Name path must be a nonblank string."
        }
    }
    else {
        if ($Arguments.write_id -isnot [string] -or $Arguments.write_id -cnotmatch '^[a-f0-9]{32}$') {
            throw 'write_id must be the ID returned by begin_file_write.'
        }
    }
    if ($Name -in 'write_file', 'write_file_chunk') {
        if (-not $Arguments.ContainsKey('content') -or $Arguments.content -isnot [string]) {
            throw "$Name content must be present and a string; use an explicit empty string for an empty file."
        }
    }
    foreach ($key in 'expected_bytes', 'offset_bytes') {
        if ($Arguments.ContainsKey($key)) {
            $value = $Arguments[$key]
            if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt $State.Limits.MaxFileBytes) {
                throw "$key must be an integer from 0 to $($State.Limits.MaxFileBytes)."
            }
        }
        elseif (($key -eq 'expected_bytes' -and $Name -eq 'begin_file_write') -or
            ($key -eq 'offset_bytes' -and $Name -eq 'write_file_chunk')) { throw "$key is required." }
    }
    if ($Arguments.ContainsKey('expected_sha256') -and
        ($Arguments.expected_sha256 -isnot [string] -or $Arguments.expected_sha256 -notmatch '^[a-fA-F0-9]{64}$')) {
        throw 'expected_sha256 must be a 64-character hexadecimal SHA-256.'
    }
    if ($Name -ne 'write_file') {
        $json = ConvertTo-Json -InputObject $Arguments -Compress -Depth 10 -ErrorAction Stop
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $State.Limits.MaxArgumentBytes) {
            throw 'File-write arguments exceed MaxArgumentBytes; use a smaller chunk.'
        }
    }
}
function New-AgentHarnessFileWriteState {
    param([hashtable]$Options)

    $limits = @{
        MaxChunkBytes = 4096; MaxFileBytes = 16777216; MaxActiveSessions = 4
        MaxStagedBytes = 67108864; MaxArgumentBytes = 65536; MaxReceipts = 256; MaxChunks = 65536
    }
    foreach ($key in $Options.Keys) {
        if ($key -cnotin @($limits.Keys)) { throw "Unknown FileWriteOptions setting: $key" }
        $value = $Options[$key]
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 1073741824) {
            throw "FileWriteOptions $key must be an integer from 1 to 1073741824."
        }
        $limits[$key] = [long]$value
    }
    if ($limits.MaxChunkBytes -gt $limits.MaxFileBytes -or $limits.MaxFileBytes -gt $limits.MaxStagedBytes -or
        $limits.MaxActiveSessions -gt $limits.MaxReceipts -or $limits.MaxArgumentBytes -lt 1024 -or
        $limits.MaxActiveSessions -gt 256 -or $limits.MaxReceipts -gt 4096 -or $limits.MaxChunks -gt 1048576) {
        throw 'Inconsistent FileWriteOptions limits; chunk <= file <= staged, active <= receipts, argument >= 1024, active <= 256, receipts <= 4096 and chunks <= 1048576 are required.'
    }
    @{ Limits = $limits; Sessions = @{}; StagingRoot = $null; ReservedBytes = [long]0 }
}
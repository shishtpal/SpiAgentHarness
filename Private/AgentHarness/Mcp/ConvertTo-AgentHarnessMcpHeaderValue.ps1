function ConvertTo-AgentHarnessMcpHeaderValue {
    param([string]$Value, [switch]$Json)

    if ($Json) {
        $parsed = ConvertFrom-Json -InputObject $Value -NoEnumerate
        if ($parsed -is [string]) { $Value = $parsed }
    }
    if ($Value -match '[^\x20-\x7E]' -or $Value -cne $Value.Trim() -or ($Value.StartsWith('=?base64?') -and $Value.EndsWith('?='))) {
        return '=?base64?' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value)) + '?='
    }
    $Value
}
function Format-AgentHarnessToolArguments {
    param([string]$Arguments)

    try {
        $parsed = ConvertFrom-Json -InputObject $Arguments -AsHashtable -NoEnumerate -ErrorAction Stop
        if ($parsed -isnot [hashtable]) { return $Arguments }
    }
    catch { return $Arguments }

    if (-not $parsed.Count) { return '(no arguments)' }
    $parts = foreach ($key in $parsed.Keys) {
        $value = $parsed[$key]
        if ($value -is [Collections.IDictionary] -or $value -is [array]) {
            $value = ConvertTo-Json -InputObject $value -Depth 20
        }
        if ($key -in 'command', 'content' -or [string]$value -match '[\r\n]') {
            "${key}:`n$value"
        }
        else { "${key}: $value" }
    }
    $parts -join "`n`n"
}
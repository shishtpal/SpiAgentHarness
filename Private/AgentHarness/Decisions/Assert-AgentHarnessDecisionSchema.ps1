function Assert-AgentHarnessDecisionSchema {
    param([object]$Value, [object]$Schema)

    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop
        $schemaJson = ConvertTo-Json -InputObject $Schema -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop
        if ($schemaJson -match '"\$(ref|dynamicRef)"\s*:') { throw 'Schema references are unsupported.' }
        if (-not (Test-Json -Json $json -Schema $schemaJson -ErrorAction Stop)) { throw 'Schema mismatch.' }
    }
    catch { throw 'Decision tool arguments do not match the configured JSON schema.' }
}
function ConvertFrom-AgentHarnessContextJson {
    param([string]$Json)

    # ConvertFrom-Json on older PowerShell versions coerces ISO-looking text to dates.
    # System.Text.Json is bundled with PowerShell 7's .NET runtime and preserves text.
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 32
    $document = [System.Text.Json.JsonDocument]::Parse($Json, $options)
    try { ConvertFrom-AgentHarnessContextElement -Element $document.RootElement }
    finally { $document.Dispose() }
}

function ConvertFrom-AgentHarnessContextElement {
    param([System.Text.Json.JsonElement]$Element)

    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $map = [hashtable]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if ($map.ContainsKey($property.Name)) { throw 'Context JSON contains duplicate object keys.' }
                $map[$property.Name] = ConvertFrom-AgentHarnessContextElement -Element $property.Value
            }
            $map
        }
        'Array' {
            $list = [Collections.Generic.List[object]]::new()
            foreach ($value in $Element.EnumerateArray()) { $list.Add((ConvertFrom-AgentHarnessContextElement -Element $value)) }
            , $list.ToArray()
        }
        'String' { $Element.GetString() }
        'Number' {
            $integer = [long]0
            if ($Element.TryGetInt64([ref]$integer)) { $integer } else { $Element.GetDouble() }
        }
        'True' { $true }
        'False' { $false }
        'Null' { $null }
        default { throw 'Context contains an unsupported JSON value.' }
    }
}
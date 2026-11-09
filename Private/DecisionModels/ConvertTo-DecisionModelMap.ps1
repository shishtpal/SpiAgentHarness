function ConvertTo-DecisionModelMap {
    param([AllowNull()][object]$Value, [string]$Name = 'Value')

    # Use ordinal keys: JSON question names and choice labels are case sensitive.
    $map = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string] -or [string]::IsNullOrWhiteSpace($key)) {
                throw "$Name must have nonempty string keys."
            }
            $map.Add($key, $Value[$key])
        }
    }
    elseif ($Value -is [Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace($property.Name)) { throw "$Name has an empty key." }
            $map.Add($property.Name, $property.Value)
        }
    }
    else { throw "$Name must be a JSON object (a dictionary or PSCustomObject)." }
    return ,$map
}
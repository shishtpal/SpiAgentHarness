function Get-AgentHarnessMcpHeaderMappings {
    param([hashtable]$Schema)

    $mappings = [Collections.Generic.List[object]]::new()
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $visit = {
        param($node, [string[]]$path, [bool]$reachable)
        if ($node -is [Collections.IDictionary]) {
            if ($node.Contains('x-mcp-header')) {
                $name = [string]$node['x-mcp-header']
                if (-not $reachable -or -not $path.Count -or $name -notmatch "^[!#$%&'*+.^_``|~0-9A-Za-z-]+$" -or
                    $node.type -notin 'string', 'integer', 'boolean' -or -not $names.Add($name)) { throw 'Invalid x-mcp-header annotation.' }
                $mappings.Add(@{ Name = $name; Path = $path; Type = $node.type })
            }
            foreach ($key in $node.Keys) {
                if ($key -eq 'properties' -and $node[$key] -is [Collections.IDictionary]) {
                    foreach ($property in $node[$key].Keys) { & $visit $node[$key][$property] @($path + $property) $reachable }
                }
                elseif ($node[$key] -is [Collections.IDictionary] -or $node[$key] -is [array]) { & $visit $node[$key] $path $false }
            }
        }
        elseif ($node -is [array]) { foreach ($item in $node) { & $visit $item $path $false } }
    }
    & $visit $Schema @() $true
    $mappings.ToArray()
}
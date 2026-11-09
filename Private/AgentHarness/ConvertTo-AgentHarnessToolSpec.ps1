function ConvertTo-AgentHarnessToolSpec {
    param([Collections.IDictionary]$ToolTable)

    foreach ($name in $ToolTable.Keys) {
        $tool = $ToolTable[$name]
        @{
            type     = 'function'
            function = @{
                name        = $name
                description = [string]$tool.Description
                parameters  = ($tool.Parameters ?? @{ type = 'object'; properties = @{} })
            }
        }
    }
}
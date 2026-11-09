function Get-AgentHarnessDecisionTools {
    param([hashtable]$State)

    $tools = [ordered]@{}
    $invoke = ${function:Invoke-AgentHarnessDecisionTool}
    foreach ($name in $State.Definitions.Keys) {
        $definition = $State.Definitions[$name].Definition
        $tools[$name] = @{
            Description = $definition.tool.function.description
            Parameters = $definition.tool.function.parameters
            OutputMustFit = $true
            DecisionTool = $true
            Script = {
                param($a, $ctx)
                & $invoke -Arguments $a -Context $ctx -Name $name
            }.GetNewClosure()
        }
    }
    $tools
}
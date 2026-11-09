function Invoke-AgentHarnessDecisionTool {
    param([hashtable]$Arguments, [hashtable]$Context, [string]$Name)

    $entry = $Context.DecisionState.Definitions[$Name]
    Assert-AgentHarnessDecisionSchema -Value $Arguments -Schema $entry.Definition.tool.function.parameters
    $result = & $entry.Handler $Arguments $Context $entry.Definition
    ConvertTo-Json -InputObject $result -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop
}
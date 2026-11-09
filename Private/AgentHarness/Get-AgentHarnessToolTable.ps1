function Get-AgentHarnessToolTable {
    param(
        [hashtable]$Tools,
        [switch]$NoBuiltinTools,
        [switch]$AllowWrite = $true,
        [switch]$AllowShell = $true,
        [switch]$AllowSubAgents = $true,
        [switch]$AllowSkills = $true,
        [hashtable]$DecisionState
    )

    $table = [ordered]@{}
    if (-not $NoBuiltinTools) {
        $builtin = Get-AgentHarnessBuiltinTools -AllowWrite:$AllowWrite -AllowShell:$AllowShell -AllowSubAgents:$AllowSubAgents -AllowSkills:$AllowSkills
        foreach ($name in $builtin.Keys) { $table[$name] = $builtin[$name] }
    }
    if ($DecisionState -and -not $NoBuiltinTools) {
        $decisionTools = Get-AgentHarnessDecisionTools -State $DecisionState
        foreach ($name in $decisionTools.Keys) {
            if ($table.Contains($name)) { throw 'Decision tool name conflicts with a built-in tool.' }
            $table[$name] = $decisionTools[$name]
        }
    }
    if ($Tools) {
        foreach ($name in $Tools.Keys) { $table[$name] = $Tools[$name] }
    }
    foreach ($name in $table.Keys) {
        if ($table[$name].Script -isnot [scriptblock]) {
            throw "Tool '$name' must provide a Script scriptblock."
        }
    }
    $table
}
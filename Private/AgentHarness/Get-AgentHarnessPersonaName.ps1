function Get-AgentHarnessPersonaName {
    param([string]$AgentProfile = 'Default', [string]$PretendAgent)

    $selected = if ($AgentProfile -and $AgentProfile -ne 'Default') { $AgentProfile } else { $PretendAgent }
    switch ($selected) {
        'Codex' { 'Codex' }
        'ClaudeCode' { 'Claude Code' }
        'OpenCode' { 'OpenCode' }
        'Kilo' { 'Kilo' }
        'Cline' { 'Cline' }
        { [string]::IsNullOrEmpty($_) } { 'SpiAgentHarness' }
        default { throw "Unknown agent persona: $selected" }
    }
}
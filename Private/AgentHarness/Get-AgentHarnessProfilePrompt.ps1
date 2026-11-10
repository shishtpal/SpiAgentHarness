function Get-AgentHarnessProfilePrompt {
    param(
        [ValidateSet('Default', 'Codex', 'ClaudeCode', 'OpenCode', 'Kilo', 'Cline')]
        [string]$AgentProfile = 'Default'
    )

    if ($AgentProfile -eq 'Default') { return }
    $profileName = (Get-AgentHarnessPersonaName -AgentProfile $AgentProfile).Replace(' ', '')
    $path = Join-Path $PSScriptRoot "Profiles/$profileName.md"
    $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($text)) { throw "Agent profile is empty: $AgentProfile" }
    @"
Adapted agent behavior profile: $profileName
This profile guides working style inside SpiAgentHarness using the persona name in your introduction. It does not change your actual runtime, provider, model, permissions or tools. The harness rules, repository instructions and user instructions take precedence over profile guidance. Use only the tool definitions exposed in this request; do not assume upstream tools, parallel execution, persistent shells, hidden modes or automatic checkpoints exist.

$text
"@
}
@{
    RootModule = 'SpiAgentHarness.psm1'
    ModuleVersion = '1.0.0'
    GUID = '1de3f586-70b6-46ce-9d70-d11d0d97063c'
    Author = 'Shisht Pal'
    Copyright = '(c) Shisht Pal. All rights reserved.'
    Description = 'Independent PowerShell agent harness with tools, MCP, skills, model providers, and decisions.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-DecisionModels'
        'Get-FreeModels'
        'Get-McpServer'
        'Invoke-AgentHarness'
        'Invoke-DecisionModel'
        'Register-FreeModelProvider'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    FormatsToProcess = @('SpiAgentHarness.Format.ps1xml')
}
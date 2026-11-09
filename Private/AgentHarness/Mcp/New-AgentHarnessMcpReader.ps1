function New-AgentHarnessMcpReader {
    param([IO.StreamReader]$Reader, [int]$MaxResponseChars)

    if (-not ('SpiAgentHarness.McpLineReader' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'McpLineReader.cs') -ErrorAction Stop
    }
    [SpiAgentHarness.McpLineReader]::new($Reader, $MaxResponseChars)
}
function Import-AgentHarnessWorkerRuntime {
    param([string]$ModuleRoot)

    # Parent and workers use the same independent module and private dependencies.
    Import-Module -Name (Join-Path $ModuleRoot 'SpiAgentHarness.psd1') -PassThru -Force -Scope Local
}
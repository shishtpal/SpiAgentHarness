# Dot-sourced by AgentHarness.Skills.Tests.ps1 after the synthetic global root exists.
$moduleLinkAlias = Join-Path $fixture 'module-link'
$moduleLinkChain = Join-Path $fixture 'module-link-chain'
$moduleLinkSkill = Join-Path $globalDefaultRoot 'linked-definition'
$moduleLinkResource = Join-Path $globalDefaultRoot 'global-workflow/linked-resource'
$moduleLinkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
try {
    $null = New-Item -ItemType $moduleLinkType -Path $moduleLinkAlias -Target $fixture
    $null = New-Item -ItemType $moduleLinkType -Path $moduleLinkChain -Target $moduleLinkAlias
    $moduleLinkResolved = & $module { param($root) Get-AgentHarnessDefaultSkillPath -ModuleRoot $root } $moduleLinkChain
    Assert-Harness ($moduleLinkResolved -eq $globalDefaultRoot) 'Default skill root follows chained module installation links to the physical directory'
    $moduleLinkAncestor = & $module { param($root) Get-AgentHarnessDefaultSkillPath -ModuleRoot $root } (Join-Path $moduleLinkAlias 'Private')
    Assert-Harness ($moduleLinkAncestor -eq (Join-Path $fixture 'Private/.agents/skills')) 'Module resolution handles a linked ancestor and preserves the remaining path'

    # Run the alias-loaded runtime in a separate process so its module commands
    # and mocked transport cannot shadow the parent fixture's exported commands.
    $moduleLinkProbePath = Join-Path $fixture 'Probe-LinkedModule.ps1'
    $moduleLinkProbe = @'
param([string]$ModuleRoot, [string]$WorkingDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $ModuleRoot 'Private/AgentHarness/SubAgents/Import-AgentHarnessWorkerRuntime.ps1')
$runtime = Import-AgentHarnessWorkerRuntime -ModuleRoot $ModuleRoot
try {
    & $runtime {
        param($root)
        $state = New-AgentHarnessSkillState -WorkingDirectory $root
        function script:Invoke-AgentHarnessChat {
            param($Uri, $ApiKey, $Body, $TimeoutSec, $Log, $RequestHeaders, $Stream, $OnText)
            if ($Uri -ne 'https://provider.invalid/module-link') { throw "Unmocked linked-module endpoint: $Uri" }
            $calls = @()
            if (-not @($Body.messages | Where-Object role -eq tool).Count) {
                $calls = @(@{ id = 'root_probe'; type = 'function'; function = @{ name = 'capture_skill_root'; arguments = '{}' } })
            }
            @{
                choices = @(@{ finish_reason = $(if ($calls.Count) { 'tool_calls' } else { 'stop' }); message = @{ role = 'assistant'; content = 'Linked module completed.'; tool_calls = $calls } })
            } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        }
        $tools = @{ capture_skill_root = @{ Parameters = @{ type = 'object'; properties = @{} }; Script = {
            param($a, $ctx)
            $ctx.SubAgentOptions.GlobalSkillPath
        } } }
        $warnings = @()
        $result = Invoke-AgentHarness 'Inspect synthetic global skills' -WorkingDirectory $root `
            -Model synthetic-model -ChatUri https://provider.invalid/module-link -Tools $tools `
            -NoSkills:$false -NoAgentsFile -NoSubAgents -NoCompletionPrompt -NoModelRecovery -Quiet -PassThru -WarningVariable warnings
        [pscustomobject]@{
            GlobalDirectory = $state.Catalog['global-workflow'].Directory
            WarningCount = @($warnings).Count
            HasGlobalDescription = $result.Messages[0].content.Contains('GLOBAL_DEFAULT_DESCRIPTION')
            ForwardedRoot = @($result.Messages | Where-Object role -eq tool)[0].content
        }
    } $WorkingDirectory | ConvertTo-Json -Compress
}
finally { Remove-Module $runtime -Force }
'@
    [IO.File]::WriteAllText($moduleLinkProbePath, $moduleLinkProbe)
    $moduleLinkStart = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $moduleLinkProbePath, '-ModuleRoot', $moduleLinkChain, '-WorkingDirectory', $skillRoot)) {
        $moduleLinkStart.ArgumentList.Add($argument)
    }
    $moduleLinkStart.UseShellExecute = $false
    $moduleLinkStart.CreateNoWindow = $true
    $moduleLinkStart.RedirectStandardOutput = $true
    $moduleLinkStart.RedirectStandardError = $true
    $moduleLinkProcess = [Diagnostics.Process]::Start($moduleLinkStart)
    try {
        $moduleLinkOutput = $moduleLinkProcess.StandardOutput.ReadToEndAsync()
        $moduleLinkError = $moduleLinkProcess.StandardError.ReadToEndAsync()
        if (-not $moduleLinkProcess.WaitForExit(30000)) { throw 'Linked-module probe timed out.' }
        if ($moduleLinkProcess.ExitCode -ne 0) { throw "Linked-module probe failed: $($moduleLinkError.GetAwaiter().GetResult())" }
        $moduleLinkRun = ConvertFrom-Json -InputObject ($moduleLinkOutput.GetAwaiter().GetResult())
    }
    finally {
        if (-not $moduleLinkProcess.HasExited) { $moduleLinkProcess.Kill($true); $null = $moduleLinkProcess.WaitForExit(5000) }
        $moduleLinkProcess.Dispose()
    }
    Assert-Harness ($moduleLinkRun.GlobalDirectory -eq (Join-Path $globalDefaultRoot 'global-workflow')) 'A runtime loaded through the module link discovers physical global skills'
    Assert-Harness ($moduleLinkRun.WarningCount -eq 0 -and $moduleLinkRun.HasGlobalDescription) 'Public discovery through a linked install has no skipped-root warnings'
    Assert-Harness ($moduleLinkRun.ForwardedRoot -eq $globalDefaultRoot) 'The physical default global root is forwarded to child options'

    $moduleLinkOverride = & $module {
        param($root, $global)
        New-AgentHarnessSkillState -WorkingDirectory $root -GlobalSkillPath $global
    } $skillRoot (Join-Path $moduleLinkAlias '.agents/skills') 3>$null
    Assert-Harness (-not $moduleLinkOverride.Catalog.Contains('global-workflow')) 'Explicit global root overrides still reject link ancestry'

    $moduleLinkTarget = New-SkillFixture (Join-Path $skillRoot 'linked-targets') blocked-linked-skill
    $null = New-Item -ItemType $moduleLinkType -Path $moduleLinkSkill -Target $moduleLinkTarget
    $null = New-Item -ItemType $moduleLinkType -Path $moduleLinkResource -Target $chosen
    $moduleLinkState = & $module { param($root) New-AgentHarnessSkillState -WorkingDirectory $root } $skillRoot 3>$null
    Assert-Harness (-not $moduleLinkState.Catalog.Contains('blocked-linked-skill')) 'Resolving the module installation does not allow linked skill definitions'
    foreach ($preference in 'Continue', 'Stop') {
        $moduleLinkResult = Invoke-SkillFixtureTool read_skill_resource @{ name = 'global-workflow'; path = 'linked-resource/SKILL.md' } `
            -Context @{ Root = $skillRoot; Quiet = $true; SkillState = $moduleLinkState } -Preference $preference
        Assert-Harness ($moduleLinkResult.content -like 'ERROR:*reparse points*') "Linked global resources remain rejected under $preference"
    }
}
finally {
    # Delete only the link entries, never recurse into their targets.
    foreach ($moduleLinkPath in @($moduleLinkResource, $moduleLinkSkill, $moduleLinkChain, $moduleLinkAlias)) {
        if (Test-Path -LiteralPath $moduleLinkPath) { [IO.Directory]::Delete($moduleLinkPath) }
    }
}
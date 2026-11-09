# Dot-sourced by Invoke-AgentHarness.Tests.ps1 inside its isolated module fixture.
$agentRoot = Join-Path $fixture 'sub-agent-fixture'
$null = New-Item -ItemType Directory -Path $agentRoot
$agentChatPath = Join-Path $fixture 'Private/AgentHarness/Invoke-AgentHarnessChat.ps1'
$savedAgentChatBytes = [IO.File]::ReadAllBytes($agentChatPath)
$savedAgentTerminal = & $module { ${function:Start-AgentHarnessTerminal} }
$savedAgentPreference = $ErrorActionPreference

function Invoke-SubAgentFixtureTool {
    [CmdletBinding()]
    param([string]$Name, [object]$Arguments = @{}, [hashtable]$Context, [string]$Preference = 'Stop')
    $json = ConvertTo-Json -InputObject $Arguments -Depth 20 -Compress
    & $module {
        param($name, $json, $context, $preference)
        $ErrorActionPreference = $preference
        Invoke-AgentHarnessToolCall -Call @{ id = 'agent_fixture'; function = @{ name = $name; arguments = $json } } `
            -ToolTable (Get-AgentHarnessBuiltinTools) -Context $context -MaxOutputChars 20000
    } $Name $json $Context $Preference
}

try {
    $ErrorActionPreference = 'Stop'
    & $module { $script:AgentFixtureProcesses = [Collections.Generic.List[object]]::new() }
    $agentContext = @{
        Root = $agentRoot; YOLO = $true; Quiet = $true; NoPromptSound = $true
        AllowWrite = $true; AllowShell = $true; MaxSubAgents = 3
        SubAgents = [Collections.Generic.List[string]]::new()
        SubAgentProvider = 'TestA'; SubAgentModel = 'synthetic-child-model'
        SubAgentConnection = [pscustomobject]@{ ChatUri = 'https://provider.invalid/child'; KeyEnvVar = $null; OmitToolChoice = $true }
        SubAgentApiKey = 'synthetic-child-key-for-environment-only'
        SubAgentOptions = @{ Instructions = 'Synthetic parent instructions.'; NoAgentsFile = $true; NoSkills = $true; MaxIterations = 4; MaxToolOutputChars = 8000; TimeoutSec = 10; NoPromptSound = $true; Temperature = 0.2 }
    }
    Assert-Harness ($defaultPrompt.Contains('Persistent work status and resumption') -and $defaultPrompt.Contains('WORK_STATUS.md') -and $defaultPrompt.Contains('pending sub-agent IDs/result paths')) 'Default prompt records resumable work and delegated status without storing a transcript'
    $disabledAgentNames = & $module { (Get-AgentHarnessBuiltinTools -AllowSubAgents:$false).Keys }
    Assert-Harness (@($disabledAgentNames | Where-Object { $_ -in 'spawn_agent', 'agent_status', 'wait_agent', 'stop_agent' }).Count -eq 0) 'NoSubAgents removes every child lifecycle tool'
    $noShellAgentNames = & $module { (Get-AgentHarnessBuiltinTools -AllowShell:$false).Keys }
    Assert-Harness ($noShellAgentNames -notcontains 'spawn_agent' -and $noShellAgentNames -contains 'agent_status') 'Shell restriction removes launches while preserving saved status inspection'
    $emptyAgents = Invoke-SubAgentFixtureTool agent_status -Context $agentContext
    Assert-Harness ($emptyAgents.content -eq '[]') 'No saved agents returns a JSON array without creating state directories'
    Assert-Harness (-not (Test-Path -LiteralPath (Join-Path $agentRoot '.agents/children'))) 'Inspecting absent agent state does not create files'

    # Old state is deliberately excluded; no migration or fallback reads.
    $oldStateRoot = Join-Path $fixture 'old-sub-agent-state'
    $oldStateDirectory = Join-Path $oldStateRoot ('.agent-harness/agents/' + ('a' * 32))
    $null = New-Item -ItemType Directory -Path $oldStateDirectory -Force
    [IO.File]::WriteAllText((Join-Path $oldStateDirectory 'status.json'), '{}')
    $oldStateContext = @{ Root = $oldStateRoot; Quiet = $true }
    foreach ($preference in 'Continue', 'Stop') {
        $oldInventory = Invoke-SubAgentFixtureTool agent_status -Context $oldStateContext -Preference $preference
        Assert-Harness ($oldInventory.content -eq '[]') "Old records are not read or migrated under $preference"
        $oldLookup = Invoke-SubAgentFixtureTool agent_status @{ agent_id = ('a' * 32) } -Context $oldStateContext -Preference $preference
        Assert-Harness ($oldLookup.content -like 'ERROR:*') "Looking up an old ID does not fall back under $preference"
    }
    Assert-Harness (-not (Test-Path -LiteralPath (Join-Path $oldStateRoot '.agents/children'))) 'Inspecting old-only state does not create or migrate child directories'

    foreach ($preference in 'Continue', 'Stop') {
        foreach ($arguments in @(@{}, @{ task = '' }, @{ task = @('a') }, @{ task = 'x'; yolo = 'true' }, @{ task = 'x'; allow_write = 1 }, @{ task = 'x'; name = 9 }, @{ task = 'x'; extra = $true })) {
            $invalid = Invoke-SubAgentFixtureTool spawn_agent $arguments -Context $agentContext -Preference $preference
            Assert-Harness ($invalid.content -like 'ERROR:*') "Invalid spawn arguments fail as tool errors under $preference"
        }
        foreach ($name in 'agent_status', 'wait_agent', 'stop_agent') {
            $invalid = Invoke-SubAgentFixtureTool $name @{ agent_id = '../escape' } -Context $agentContext -Preference $preference
            Assert-Harness ($invalid.content -like 'ERROR:*agent_id*') "Invalid $name ID fails under $preference"
        }
        $invalid = Invoke-SubAgentFixtureTool wait_agent @{ agent_id = ('a' * 32); timeout_seconds = 61 } -Context $agentContext -Preference $preference
        Assert-Harness ($invalid.content -like 'ERROR:*timeout_seconds*') "Wait timeout is bounded under $preference"
    }
    $restrictedContext = $agentContext.Clone(); $restrictedContext.AllowWrite = $false
    $invalid = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'x'; allow_write = $true } -Context $restrictedContext
    Assert-Harness ($invalid.content -like 'ERROR:*parent writes are disabled*') 'Child writes cannot exceed parent write permissions'
    $restrictedContext = $agentContext.Clone(); $restrictedContext.AllowShell = $false
    $invalid = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'x' } -Context $restrictedContext
    Assert-Harness ($invalid.content -like 'ERROR:*shell execution is disabled*') 'Launch helper also enforces disabled parent shell'

    # Test the real visible-terminal launcher contract without opening a window.
    if ($IsWindows) {
        $testKeyVariable = 'SPI_HARNESS_TEST_' + [guid]::NewGuid().ToString('N')
        & $module {
            $script:AgentLaunchCapture = $null
            function script:Start-Process {
                [CmdletBinding()]
                param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru)
                $script:AgentLaunchCapture = @{
                    Arguments = $ArgumentList; WorkingDirectory = $WorkingDirectory; WindowStyle = $WindowStyle
                    KeyInherited = [Environment]::GetEnvironmentVariable($script:AgentTestKeyVariable) -eq 'synthetic-launch-key'
                }
                [Diagnostics.Process]::GetCurrentProcess()
            }
        }
        try {
            & $module {
                param($root, $keyVariable)
                $script:AgentTestKeyVariable = $keyVariable
                $process = Start-AgentHarnessTerminal -EncodedCommand 'synthetic-encoded-bootstrap' -WorkingDirectory $root -KeyVariable $keyVariable -ApiKey 'synthetic-launch-key'
                $process.Dispose()
            } $agentRoot $testKeyVariable
            $capture = & $module { $script:AgentLaunchCapture }
            Assert-Harness ($capture.WindowStyle -eq 'Normal' -and $capture.Arguments -contains '-NoExit' -and $capture.Arguments -notcontains '-NonInteractive') 'Visible child terminal remains interactive for approvals and output inspection'
            Assert-Harness ($capture.KeyInherited -and -not [Environment]::GetEnvironmentVariable($testKeyVariable)) 'Explicit key is inherited during launch and removed from the parent environment afterwards'
            Assert-Harness (($capture.Arguments -join ' ') -notlike '*synthetic-launch-key*') 'Credential is absent from terminal command-line arguments'
        }
        finally { & $module { Remove-Item Function:script:Start-Process } }
    }

    # Worker runtime reads this synthetic transport from disk; it never calls a live API.
    $syntheticChat = @'
function Invoke-AgentHarnessChat {
    param($Uri, $ApiKey, $Body, $TimeoutSec, $Log)
    if ($Uri -ne 'https://provider.invalid/child') { throw 'Unmocked child endpoint.' }
    if ($Body.tools.function.name -contains 'spawn_agent') { throw 'Recursive child spawning was exposed.' }
    if ($ApiKey -ne 'synthetic-child-key-for-environment-only') { throw 'Child key was not inherited.' }
    $taskText = [string](@($Body.messages | Where-Object role -eq user)[0].content)
    $isWiredChild = $taskText -in 'wired-child', 'wired-empty-child'
    if (-not $isWiredChild -and $Body.ContainsKey('tool_choice')) { throw 'Provider OmitToolChoice was not inherited.' }
    if ($isWiredChild -and -not $Body.ContainsKey('tool_choice')) { throw 'Default provider tool_choice was not preserved.' }
    if ($taskText -eq 'wired-child' -and -not $Body.messages[0].content.Contains('Synthetic inherited skill guidance.')) { throw 'Child skill options were not inherited.' }
    if ($taskText -eq 'hold-child') { [Threading.Thread]::Sleep(30000) }
    $calls = @()
    $text = 'Synthetic child completed.'
    if ($taskText -eq 'write-child' -and -not @($Body.messages | Where-Object role -eq tool).Count) {
        if ($Body.tools.function.name -notcontains 'write_file' -or $Body.tools.function.name -notcontains 'run_powershell') { throw 'Requested child write tools missing.' }
        $calls = @(@{ id = 'child_write'; type = 'function'; function = @{ name = 'write_file'; arguments = '{"path":"child-output.txt","content":"synthetic output"}' } })
        $text = ''
    }
    elseif ($taskText -ne 'write-child' -and ($Body.tools.function.name -contains 'write_file' -or $Body.tools.function.name -contains 'run_powershell')) { throw 'Default child is not read-only.' }
    @{
        choices = @(@{ finish_reason = $(if ($calls.Count) { 'tool_calls' } else { 'stop' }); message = @{ content = $text; tool_calls = $calls } })
        usage = @{ prompt_tokens = 5; completion_tokens = 2 }
    } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}
'@
    [IO.File]::WriteAllText($agentChatPath, $syntheticChat)
    & $module {
        function script:Start-AgentHarnessTerminal {
            param($EncodedCommand, $WorkingDirectory, $KeyVariable, $ApiKey)
            # Headless only in tests; use the real worker bootstrap and separate process.
            $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach ($argument in '-NoProfile', '-NonInteractive', '-EncodedCommand', $EncodedCommand) { $start.ArgumentList.Add($argument) }
            $start.WorkingDirectory = $WorkingDirectory
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            if ($KeyVariable) { $start.Environment[$KeyVariable] = $ApiKey }
            $process = [Diagnostics.Process]::Start($start)
            $script:AgentFixtureProcesses.Add(@{ Id = $process.Id; StartTicks = $process.StartTime.ToUniversalTime().Ticks })
            $process
        }
    }

    $denialContext = $agentContext.Clone(); $denialContext.YOLO = $false
    foreach ($reply in 'n', 'Use the parent instead.') {
        & $module { param($reply) $script:ConfirmationReplies.Enqueue($reply) } $reply
        $denied = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'read-child'; yolo = $true } -Context $denialContext 6>$null
        Assert-Harness ($denied.content -like 'ERROR: the user denied*' -and $denialContext.SubAgents.Count -eq 0) 'Denied or redirected launch starts no child and creates no task files'
    }
    Assert-Harness ($denialContext.ApprovalFeedback -eq 'Use the parent instead.') 'Launch approval guidance is preserved for parent replanning'

    $launched = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'read-child'; name = 'Synthetic reader' } -Context $agentContext
    Assert-Harness ($launched.content -notlike 'ERROR:*') "Synthetic child launch succeeds: $($launched.content)"
    $agent = ConvertFrom-Json -InputObject $launched.content -AsHashtable
    Assert-Harness ($agent.Id -cmatch '^[a-f0-9]{32}$' -and $agent.State -in 'starting', 'running', 'completed') 'Launch returns an ID asynchronously from a separate process'
    $expectedChildDirectory = Join-Path $agentRoot ".agents/children/$($agent.Id)"
    Assert-Harness ($agent.TaskFile -eq (Join-Path $expectedChildDirectory 'task.json') -and $agent.WorkStatusFile -eq (Join-Path $expectedChildDirectory 'WORK_STATUS.md')) 'Task and work-status paths use the local children directory'
    Assert-Harness (-not (Test-Path -LiteralPath (Join-Path $agentRoot '.agent-harness'))) 'New child launches create no old state directory'
    $taskJson = [IO.File]::ReadAllText($agent.TaskFile)
    $task = ConvertFrom-Json -InputObject $taskJson -AsHashtable
    Assert-Harness ($task.Options.YOLO -and -not $task.Options.AllowWrite -and $task.Options.NoShellTool -and $task.Options.NoSubAgents) 'Child inherits parent YOLO while defaulting to read-only and disabling recursion'
    Assert-Harness ($task.Options.Instructions.Contains('Synthetic parent instructions.') -and $task.Options.Instructions.Contains(".agents/children/$($agent.Id)/WORK_STATUS.md")) 'Child retains parent instructions and receives a distinct work-status path'
    Assert-Harness ($task.Options.WorkingDirectory -eq $agentRoot) 'Child keeps the parent working directory while state lives in its own folder'
    Assert-Harness ($task.Options.Temperature -eq 0.2 -and $task.Options.MaxIterations -eq 4 -and $task.Options.NoAgentsFile) 'Child inherits sampling, budget and AGENTS settings'
    Assert-Harness (-not $taskJson.Contains($agentContext.SubAgentApiKey) -and -not $task.Options.ContainsKey('ApiKey')) 'Task JSON contains no explicit API key or parent transcript'
    $completed = Invoke-SubAgentFixtureTool wait_agent @{ agent_id = $agent.Id; timeout_seconds = 30 } -Context $agentContext
    $completedStatus = ConvertFrom-Json -InputObject $completed.content -AsHashtable
    Assert-Harness ($completedStatus.State -eq 'completed' -and $completedStatus.Answer -eq 'Synthetic child completed.') "Child publishes its result through the standalone module without bootstrap execution: $($completedStatus.State)"
    $savedResult = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($completedStatus.ResultFile)) -AsHashtable
    Assert-Harness (-not $savedResult.ContainsKey('Messages') -and $savedResult.PromptTokens -eq 5) 'Saved child result contains answer and usage, not a raw transcript'

    $launched = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'read-child'; yolo = $false } -Context $agentContext
    $agent = ConvertFrom-Json -InputObject $launched.content -AsHashtable
    $task = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($agent.TaskFile)) -AsHashtable
    Assert-Harness (-not $task.Options.YOLO) 'Explicit false overrides a YOLO parent for the child'
    $null = Invoke-SubAgentFixtureTool wait_agent @{ agent_id = $agent.Id; timeout_seconds = 30 } -Context $agentContext

    & $module { $script:ConfirmationReplies.Enqueue('yes') }
    $launched = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'read-child'; yolo = $true } -Context $denialContext 6>$null
    $agent = ConvertFrom-Json -InputObject $launched.content -AsHashtable
    Assert-Harness ($agent.YOLO -and -not $denialContext.YOLO) 'A non-YOLO parent can explicitly approve a YOLO child'
    $null = Invoke-SubAgentFixtureTool wait_agent @{ agent_id = $agent.Id; timeout_seconds = 30 } -Context $agentContext

    $launched = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'write-child'; allow_write = $true } -Context $agentContext
    $agent = ConvertFrom-Json -InputObject $launched.content -AsHashtable
    $completed = Invoke-SubAgentFixtureTool wait_agent @{ agent_id = $agent.Id; timeout_seconds = 30 } -Context $agentContext
    $completedStatus = ConvertFrom-Json -InputObject $completed.content -AsHashtable
    Assert-Harness ($completedStatus.State -eq 'completed' -and [IO.File]::ReadAllText((Join-Path $agentRoot 'child-output.txt')).Trim() -eq 'synthetic output') 'YOLO is effective inside the real child harness and permits its approved write task'

    $agentContext.MaxSubAgents = 1
    $launched = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'hold-child' } -Context $agentContext
    $runningAgent = ConvertFrom-Json -InputObject $launched.content -AsHashtable
    $limited = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'read-child' } -Context $agentContext
    Assert-Harness ($limited.content -like 'ERROR:*limit*') 'Concurrent child budget is enforced before launch'
    $stillRunning = Invoke-SubAgentFixtureTool wait_agent @{ agent_id = $runningAgent.Id; timeout_seconds = 0 } -Context $agentContext
    Assert-Harness ((ConvertFrom-Json -InputObject $stillRunning.content).State -in 'starting', 'running') 'Zero-second wait returns active status immediately'
    & $module { $script:ConfirmationReplies.Enqueue('n') }
    $deniedStop = Invoke-SubAgentFixtureTool stop_agent @{ agent_id = $runningAgent.Id } -Context $denialContext 6>$null
    Assert-Harness ($deniedStop.content -like 'ERROR:*denied stopping*') 'Cancellation honors denial without killing the worker'
    $stopped = Invoke-SubAgentFixtureTool stop_agent @{ agent_id = $runningAgent.Id } -Context $agentContext
    Assert-Harness ((ConvertFrom-Json -InputObject $stopped.content).State -eq 'stopped') 'Stop kills the real synthetic worker process tree and records cancellation'
    $resumed = Invoke-SubAgentFixtureTool agent_status @{ agent_id = $runningAgent.Id } -Context @{ Root = $agentRoot; Quiet = $true }
    Assert-Harness ((ConvertFrom-Json -InputObject $resumed.content).State -eq 'stopped') 'Saved state can be inspected from a new parent context'

    $launched = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'hold-child' } -Context $agentContext
    $interruptedAgent = ConvertFrom-Json -InputObject $launched.content -AsHashtable
    $workerProcess = [Diagnostics.Process]::GetProcessById([int]$interruptedAgent.ProcessId)
    try { $workerProcess.Kill($true); $null = $workerProcess.WaitForExit(5000) } finally { $workerProcess.Dispose() }
    $interrupted = Invoke-SubAgentFixtureTool agent_status @{ agent_id = $interruptedAgent.Id } -Context $agentContext
    Assert-Harness ((ConvertFrom-Json -InputObject $interrupted.content).State -eq 'interrupted') 'Unexpected terminal closure is reported without pretending the task completed'

    $runtimeImportPath = Join-Path $fixture 'Private/AgentHarness/SubAgents/Import-AgentHarnessWorkerRuntime.ps1'
    $savedRuntimeImport = [IO.File]::ReadAllBytes($runtimeImportPath)
    try {
        [IO.File]::WriteAllText($runtimeImportPath, "function Import-AgentHarnessWorkerRuntime { param([string]`$ModuleRoot) throw 'Synthetic initialization failure.' }")
        $launched = Invoke-SubAgentFixtureTool spawn_agent @{ task = 'read-child' } -Context $agentContext
        $failedAgent = ConvertFrom-Json -InputObject $launched.content -AsHashtable
        $failed = Invoke-SubAgentFixtureTool wait_agent @{ agent_id = $failedAgent.Id; timeout_seconds = 30 } -Context $agentContext
        Assert-Harness ((ConvertFrom-Json -InputObject $failed.content).State -eq 'failed') 'Worker initialization failure publishes a terminal state instead of remaining running indefinitely'
    }
    finally { [IO.File]::WriteAllBytes($runtimeImportPath, $savedRuntimeImport) }

    if ($IsWindows) {
        $stateLink = Join-Path $fixture 'sub-agent-state-link'
        $null = New-Item -ItemType Junction -Path $stateLink -Target $agentRoot
        try {
            $linkedStatus = Invoke-SubAgentFixtureTool agent_status -Context @{ Root = $stateLink; Quiet = $true }
            Assert-Harness ($linkedStatus.content -like 'ERROR:*reparse points*') 'Sub-agent control state rejects symlink and junction ancestry'
        }
        finally { [IO.Directory]::Delete($stateLink) }
    }

    # Exercise public entry-point wiring, not just direct tool helpers.
    $parentOptions = $withBuiltins.Clone(); $parentOptions.WorkingDirectory = $agentRoot
    foreach ($preference in 'Continue', 'Stop') {
        foreach ($selection in @(
            @{ Name = 'omitted'; Options = @{ NoSkills = $false } }
            @{ Name = 'empty'; Options = @{ NoSkills = $false; Skill = @() } }
            @{ Name = 'disabled'; Options = @{ NoSkills = $true } }
        )) {
            $emptySkillOptions = $parentOptions.Clone(); $emptySkillOptions.GlobalSkillPath = ''
            foreach ($key in $selection.Options.Keys) { $emptySkillOptions[$key] = $selection.Options[$key] }
            $parentCall = New-HarnessCall spawn_agent '{"task":"wired-empty-child"}' 'empty_skill_spawn'
            Set-HarnessResponses @((New-HarnessResponse '' @($parentCall)), (New-HarnessResponse 'parent continued'))
            $parent = Invoke-AgentHarness 'delegate without selected skills' @emptySkillOptions -Model 'synthetic-child-model' -ChatUri 'https://provider.invalid/child' -ApiKey $agentContext.SubAgentApiKey -YOLO -PassThru -ErrorAction $preference
            $parentTool = @($parent.Messages | Where-Object role -eq tool)[0]
            $emptySkillChild = ConvertFrom-Json -InputObject $parentTool.content -AsHashtable
            $emptySkillTask = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($emptySkillChild.TaskFile)) -AsHashtable
            Assert-Harness ($emptySkillTask.Options.Skill -is [array] -and $emptySkillTask.Options.Skill.Count -eq 0) "$($selection.Name) skill selections persist as an empty JSON array under $preference"
            Assert-Harness ($emptySkillTask.Options.NoSkills -eq $selection.Options.NoSkills) "$($selection.Name) skill selections preserve discovery settings under $preference"
            $emptySkillCompletion = Invoke-SubAgentFixtureTool wait_agent @{ agent_id = $emptySkillChild.Id; timeout_seconds = 30 } -Context $agentContext -Preference $preference
            $emptySkillStatus = ConvertFrom-Json -InputObject $emptySkillCompletion.content -AsHashtable
            Assert-Harness ($emptySkillStatus.State -eq 'completed' -and $emptySkillStatus.Answer -eq 'Synthetic child completed.') "$($selection.Name) skill selections allow the real child worker to complete under $preference"
        }
    }
    $childSkills = Join-Path $agentRoot 'extra-skills/child-guidance'
    $null = New-Item -ItemType Directory -Path $childSkills -Force
    [IO.File]::WriteAllText((Join-Path $childSkills 'SKILL.md'), "---`nname: child-guidance`ndescription: Synthetic child skill.`n---`nSynthetic inherited skill guidance.")
    $parentOptions.NoSkills = $false; $parentOptions.GlobalSkillPath = ''
    $parentOptions.Skill = @('child-guidance'); $parentOptions.SkillPath = @('./extra-skills')
    $parentCall = New-HarnessCall spawn_agent '{"task":"wired-child"}' 'parent_spawn'
    Set-HarnessResponses @((New-HarnessResponse '' @($parentCall)), (New-HarnessResponse 'parent continued'))
    $parent = Invoke-AgentHarness 'delegate a synthetic task' @parentOptions -Model 'synthetic-child-model' -ChatUri 'https://provider.invalid/child' -ApiKey $agentContext.SubAgentApiKey -YOLO -PassThru
    $parentTool = @($parent.Messages | Where-Object role -eq tool)[0]
    $wiredChild = ConvertFrom-Json -InputObject $parentTool.content -AsHashtable
    $wiredTask = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($wiredChild.TaskFile)) -AsHashtable
    Assert-Harness ($parent.Answer -eq 'parent continued' -and $wiredTask.Options.YOLO -and $wiredTask.Options.Model -eq 'synthetic-child-model') 'Public YOLO/model/context are forwarded through the parent tool loop'
    Assert-Harness (-not $wiredTask.Options.NoSkills -and $wiredTask.Options.Skill -contains 'child-guidance' -and [IO.Path]::IsPathRooted($wiredTask.Options.SkillPath[0]) -and $wiredTask.Options.GlobalSkillPath -eq '') 'Child inherits explicit selections, normalized skill roots and disabled global root'
    $wiredCompletion = Invoke-SubAgentFixtureTool wait_agent @{ agent_id = $wiredChild.Id; timeout_seconds = 30 } -Context $agentContext
    Assert-Harness ((ConvertFrom-Json -InputObject $wiredCompletion.content).State -eq 'completed') 'Child launched through public entry point completes using inherited provider settings'
    Set-HarnessResponses @((New-HarnessResponse 'no delegation'))
    $null = Invoke-AgentHarness 'do not delegate' @parentOptions -NoSubAgents
    Assert-Harness (@((Get-HarnessRequests)[0].Body.tools.function.name | Where-Object { $_ -in 'spawn_agent', 'agent_status', 'wait_agent', 'stop_agent' }).Count -eq 0) 'Public NoSubAgents removes tools from provider requests'
    $inventory = Invoke-SubAgentFixtureTool agent_status -Context $agentContext
    Assert-Harness (@(ConvertFrom-Json -InputObject $inventory.content).Count -ge 6) 'Saved child inventory remains a JSON array with completed and interrupted jobs'
}
finally {
    $ErrorActionPreference = $savedAgentPreference
    [IO.File]::WriteAllBytes($agentChatPath, $savedAgentChatBytes)
    & $module {
        param($launcher)
        Set-Item Function:script:Start-AgentHarnessTerminal -Value $launcher
        foreach ($identity in $script:AgentFixtureProcesses) {
            $process = $null
            try {
                $process = [Diagnostics.Process]::GetProcessById($identity.Id)
                if (-not $process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq $identity.StartTicks) {
                    $process.Kill($true)
                    $null = $process.WaitForExit(5000)
                }
            }
            catch [ArgumentException] { }
            finally { if ($process) { $process.Dispose() } }
        }
    } $savedAgentTerminal
}
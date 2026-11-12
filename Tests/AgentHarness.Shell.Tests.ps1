# Dot-sourced inside the isolated harness fixture; no user configuration or network.
function Invoke-ShellFixtureTool {
    param([string]$Name, [hashtable]$Arguments, [hashtable]$Context, [string]$Preference = 'Stop')
    $json = ConvertTo-Json -InputObject $Arguments -Depth 10 -Compress
    & $module {
        param($name, $json, $context, $preference)
        $ErrorActionPreference = $preference
        Invoke-AgentHarnessToolCall -Call @{ id = 'shell_fixture'; function = @{ name = $name; arguments = $json } } `
            -ToolTable (Get-AgentHarnessBuiltinTools) -Context $context -MaxOutputChars ($context.MaxToolOutputChars ?? 8000)
    } $Name $json $Context $Preference
}

$shellContext = @{ Root = $fixture; YOLO = $true; Quiet = $true; NoPromptSound = $true; MaxToolOutputChars = 8000 }
$savedShellConfirmation = & $module { ${function:Confirm-AgentHarnessAction} }
try {
    $shellTools = & $module { Get-AgentHarnessShellTools }
    Assert-Harness ($shellTools.Count -eq 4 -and $shellTools.start_powershell.RequiresApproval -and $shellTools.run_powershell.RequiresApproval) 'Both shell launches require approval; lifecycle has four tools'
    foreach ($disabled in @(@{ AllowShell = $false }, @{ NoBuiltinTools = $true })) {
        $disabledNames = & $module { param($options) (Get-AgentHarnessToolTable @options).Keys } $disabled
        Assert-Harness (@($disabledNames | Where-Object { $_ -in 'run_powershell', 'start_powershell', 'poll_powershell', 'stop_powershell' }).Count -eq 0) 'Shell/builtin restrictions remove every shell lifecycle tool'
    }

    $sync = Invoke-ShellFixtureTool run_powershell @{ command = '[Console]::Write("short stdout"); [Console]::Error.Write("short stderr"); exit 9'; timeout_sec = 120 } $shellContext
    Assert-Harness ($sync.content -like 'exit code: 9*short stdout*short stderr*') 'Synchronous command preserves exit code and separated output with a configurable deadline'

    $started = Invoke-ShellFixtureTool start_powershell @{ command = '[Console]::Write("started"); [Threading.Thread]::Sleep(1500); [Console]::Error.Write("finished stderr"); exit 7'; timeout_sec = 120 } $shellContext
    $shellProcessId = [regex]::Match($started.content, '^process id: ([a-f0-9]{32})').Groups[1].Value
    Assert-Harness ($shellProcessId.Length -eq 32 -and $started.content.Contains('state: running') -and $started.content.Contains('deadline: 120 seconds')) 'Background start returns an ID while the command is running and accepts deadlines beyond 60 seconds'
    $process = $shellContext.ShellProcesses[$shellProcessId]
    Assert-Harness ($process.Wait(15000)) 'Background process completes within the fixture deadline'
    $polled = Invoke-ShellFixtureTool poll_powershell @{ process_id = $shellProcessId; wait_ms = 1000 } $shellContext
    Assert-Harness ($polled.content.Contains('state: exited') -and $polled.content.Contains('exit code: 7') -and $polled.content.Contains('started') -and $polled.content.Contains('finished stderr')) 'Polling reports completion, nonzero exit and both streams'
    $polledAgain = Invoke-ShellFixtureTool poll_powershell @{ process_id = $shellProcessId } $shellContext
    Assert-Harness ($polledAgain.content -ceq $polled.content) 'Polling completed work repeats its retained tail without replaying the command'
    $stoppedCompleted = Invoke-ShellFixtureTool stop_powershell @{ process_id = $shellProcessId } $shellContext
    Assert-Harness ($stoppedCompleted.content -ceq $polled.content) 'Stopping an already completed process preserves its result'

    $started = Invoke-ShellFixtureTool start_powershell @{ command = '[Console]::Write("cancel me"); [Threading.Thread]::Sleep(30000)'; timeout_sec = 120 } $shellContext
    $cancelId = [regex]::Match($started.content, '^process id: ([a-f0-9]{32})').Groups[1].Value
    $cancel = Invoke-ShellFixtureTool stop_powershell @{ process_id = $cancelId } $shellContext
    $null = $shellContext.ShellProcesses[$cancelId].Wait(10000)
    $cancel = Invoke-ShellFixtureTool stop_powershell @{ process_id = $cancelId } $shellContext
    Assert-Harness ($cancel.content.Contains('state: cancelled') -and $shellContext.ShellProcesses[$cancelId].Completed) 'Repeated cancellation stops the owned process and reaches a terminal state'

    $started = Invoke-ShellFixtureTool start_powershell @{ command = '[Threading.Thread]::Sleep(30000)'; timeout_sec = 1 } $shellContext
    $timeoutId = [regex]::Match($started.content, '^process id: ([a-f0-9]{32})').Groups[1].Value
    # No poll tool call: the independent watchdog must enforce the deadline.
    Assert-Harness ($shellContext.ShellProcesses[$timeoutId].Wait(10000)) 'Deadline terminates a background command without model polling'
    $timedOut = Invoke-ShellFixtureTool poll_powershell @{ process_id = $timeoutId } $shellContext
    Assert-Harness ($timedOut.content.Contains('state: timed_out') -and $timedOut.content.Contains('exit code:')) 'Deadline status is distinguished from cancellation and ordinary exit'
    $syncTimeout = Invoke-ShellFixtureTool run_powershell @{ command = '[Threading.Thread]::Sleep(30000)'; timeout_sec = 1 } $shellContext
    Assert-Harness ($syncTimeout.content -like 'ERROR: command timed out after 1s.*') 'Synchronous commands honor their configured deadline'

    $started = Invoke-ShellFixtureTool start_powershell @{ command = '[Console]::Write(("x" * 1000000) + "stdout-tail"); [Console]::Error.Write(("y" * 1000000) + "stderr-tail")'; timeout_sec = 30 } $shellContext
    $noisyId = [regex]::Match($started.content, '^process id: ([a-f0-9]{32})').Groups[1].Value
    Assert-Harness ($shellContext.ShellProcesses[$noisyId].Wait(15000)) 'Both oversized, unterminated streams drain without deadlock'
    $snapshot = $shellContext.ShellProcesses[$noisyId].Snapshot()
    Assert-Harness ($snapshot.Output.Length -le 65536 -and $snapshot.Error.Length -le 65536 -and $snapshot.OutputChars -eq 1000011 -and $snapshot.ErrorChars -eq 1000011) 'Capture memory is bounded independently of total stdout/stderr size'
    $noisy = Invoke-ShellFixtureTool poll_powershell @{ process_id = $noisyId } $shellContext
    Assert-Harness ($noisy.content.Length -le 8000 -and $noisy.content.Contains('truncated; showing last') -and $noisy.content.Contains('stdout-tail') -and $noisy.content.Contains('stderr-tail')) 'Bounded model output preserves both tails with explicit truncation'

    foreach ($preference in 'Continue', 'Stop') {
        foreach ($invalid in @(
            @{ Name = 'start_powershell'; Args = @{ command = ' '; timeout_sec = 10 } },
            @{ Name = 'start_powershell'; Args = @{ command = 'exit'; timeout_sec = 0 } },
            @{ Name = 'run_powershell'; Args = @{ command = 'exit'; timeout_sec = 86401 } },
            @{ Name = 'run_powershell'; Args = @{ command = 'exit'; timeout_sec = '10' } },
            @{ Name = 'run_powershell'; Args = @{ command = 'exit'; timeout_sec = 1.5 } },
            @{ Name = 'run_powershell'; Args = @{ command = 'exit'; Timeout_sec = 10 } },
            @{ Name = 'poll_powershell'; Args = @{ process_id = $shellProcessId; wait_ms = 1001 } },
            @{ Name = 'poll_powershell'; Args = @{ process_id = $shellProcessId; wait_ms = $true } },
            @{ Name = 'stop_powershell'; Args = @{ process_id = '../not-an-id' } },
            @{ Name = 'stop_powershell'; Args = @{ process_id = ('f' * 32) } },
            @{ Name = 'start_powershell'; Args = @{ command = 'exit'; unexpected = $true } }
        )) {
            $invalidResult = Invoke-ShellFixtureTool $invalid.Name $invalid.Args $shellContext $preference
            Assert-Harness ($invalidResult.content -like 'ERROR:*') "Invalid shell arguments return a tool error under $preference"
        }
    }
    $foreign = Invoke-ShellFixtureTool poll_powershell @{ process_id = $shellProcessId } @{ Root = $fixture; Quiet = $true }
    Assert-Harness ($foreign.content -like 'ERROR: Unknown shell process*') 'Process IDs cannot access another invocation registry'
    $small = Invoke-ShellFixtureTool start_powershell @{ command = 'exit' } @{ Root = $fixture; Quiet = $true; MaxToolOutputChars = 200; YOLO = $true }
    Assert-Harness ($small.content -like 'ERROR: start_powershell requires*') 'Start refuses an output limit that could hide the returned process ID'
    $fullContext = @{ Root = $fixture; YOLO = $true; Quiet = $true; ShellProcesses = [ordered]@{} }
    1..8 | ForEach-Object { $fullContext.ShellProcesses["fixture-$_"] = [pscustomobject]@{ Completed = $false } }
    $full = Invoke-ShellFixtureTool start_powershell @{ command = 'exit' } $fullContext
    Assert-Harness ($full.content -like 'ERROR: At most eight*') 'Capacity guard refuses a ninth active process before launch'

    & $module {
        $script:ShellApprovalDescriptions = [Collections.Generic.List[string]]::new()
        function script:Confirm-AgentHarnessAction {
            param($ctx, $description)
            $script:ShellApprovalDescriptions.Add($description)
            return $false
        }
    }
    $beforeDenied = $shellContext.ShellProcesses.Count
    $denied = Invoke-ShellFixtureTool start_powershell @{ command = '[IO.File]::WriteAllText("denied-shell.txt", "bad")'; timeout_sec = 300 } $shellContext
    Assert-Harness ($denied.content -eq 'ERROR: the user denied this command.' -and $shellContext.ShellProcesses.Count -eq $beforeDenied -and -not (Test-Path -LiteralPath (Join-Path $fixture 'denied-shell.txt'))) 'Denied background command creates no process or file'
    Assert-Harness ((& $module { $script:ShellApprovalDescriptions[0] }).Contains('deadline 300s')) 'Launch approval discloses the selected deadline'
    $null = Invoke-ShellFixtureTool poll_powershell @{ process_id = $shellProcessId } $shellContext
    $null = Invoke-ShellFixtureTool stop_powershell @{ process_id = $shellProcessId } $shellContext
    Assert-Harness ((& $module { $script:ShellApprovalDescriptions.Count }) -eq 1) 'Inspecting and cancelling owned work do not request duplicate approval'
}
finally {
    & $module { param($saved) Set-Item -LiteralPath Function:script:Confirm-AgentHarnessAction -Value $saved } $savedShellConfirmation
    & $module { param($ctx) Close-AgentHarnessShellProcesses -Context $ctx } $shellContext
}

# Real process-tree cancellation, using synthetic scripts and PID data only.
$treeContext = @{ Root = $fixture; YOLO = $true; Quiet = $true; NoPromptSound = $true }
$treePid = $null
try {
    [IO.File]::WriteAllText((Join-Path $fixture 'shell-child.ps1'), '[IO.File]::WriteAllText((Join-Path $PSScriptRoot "shell-child.pid"), [string]$PID); [Threading.Thread]::Sleep(30000)')
    [IO.File]::WriteAllText((Join-Path $fixture 'shell-parent.ps1'), '$s = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path); $s.UseShellExecute = $false; $s.CreateNoWindow = $true; foreach ($a in @("-NoProfile", "-File", (Join-Path $PSScriptRoot "shell-child.ps1"))) { $s.ArgumentList.Add($a) }; $p = [Diagnostics.Process]::Start($s); try { [Threading.Thread]::Sleep(30000) } finally { $p.Dispose() }')
    $started = Invoke-ShellFixtureTool start_powershell @{ command = '& ./shell-parent.ps1'; timeout_sec = 30 } $treeContext
    $treeId = [regex]::Match($started.content, '^process id: ([a-f0-9]{32})').Groups[1].Value
    $treeTimer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath (Join-Path $fixture 'shell-child.pid')) -and $treeTimer.Elapsed.TotalSeconds -lt 15) { [Threading.Thread]::Sleep(50) }
    Assert-Harness (Test-Path -LiteralPath (Join-Path $fixture 'shell-child.pid')) 'Synthetic descendant starts before testing process-tree cleanup'
    $treePid = [int][IO.File]::ReadAllText((Join-Path $fixture 'shell-child.pid'))
    $null = Invoke-ShellFixtureTool stop_powershell @{ process_id = $treeId } $treeContext
    $null = $treeContext.ShellProcesses[$treeId].Wait(10000)
    $descendant = Get-Process -Id $treePid -ErrorAction SilentlyContinue
    Assert-Harness ($null -eq $descendant -or $descendant.HasExited) 'Cancellation terminates the owned command descendant as well as its parent'
}
finally {
    & $module { param($ctx) Close-AgentHarnessShellProcesses -Context $ctx } $treeContext
    if ($treePid) { Stop-Process -Id $treePid -Force -ErrorAction SilentlyContinue }
}

# Exercise invocation-finally on both successful and failed mocked provider turns.
foreach ($finishMode in 'success', 'provider_failure', 'iteration_limit') {
    $shellCapture = @{}
    $captureShell = @{ capture_shell = @{ Script = {
        param($a, $ctx)
        $shellCapture.Context = $ctx
        $shellCapture.Process = @($ctx.ShellProcesses.Values)[0]
        'captured'
    }.GetNewClosure() } }
    $responses = @((New-HarnessResponse '' @(
        (New-HarnessCall start_powershell '{"command":"[Threading.Thread]::Sleep(30000)","timeout_sec":120}'),
        (New-HarnessCall capture_shell '{}')
    )))
    $responses += if ($finishMode -eq 'provider_failure') { New-HarnessApiError 401 } else { New-HarnessResponse 'done' }
    Set-HarnessResponses $responses
    $shellOptions = @{ Model = 'custom-model'; ChatUri = 'https://provider.invalid/chat'; WorkingDirectory = $fixture; Quiet = $true; YOLO = $true; NoAgentsFile = $true; NoCompletionPrompt = $true; NoModelRecovery = $true; NoPromptSound = $true; Tools = $captureShell }
    if ($finishMode -eq 'iteration_limit') { $shellOptions.MaxIterations = 1 }
    $providerCaught = $false
    try { $null = Invoke-AgentHarness 'Supervise synthetic work' @shellOptions 3>$null } catch { $providerCaught = $true }
    $owned = $shellCapture.Process
    $ownedContext = $shellCapture.Context
    Assert-Harness ($providerCaught -eq ($finishMode -eq 'provider_failure') -and $null -ne $owned -and $owned.Completed -and $ownedContext.ShellProcesses.Count -eq 0) "Invocation cleanup stops pending work and clears ownership ($finishMode)"
}
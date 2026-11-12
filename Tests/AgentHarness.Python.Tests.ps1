# Isolated discovery and execution fixtures. Never invoke installed uv/Python or download packages.
function Invoke-PythonFixtureTool {
    param([object]$Arguments, [string]$Preference = 'Stop')
    $json = ConvertTo-Json -InputObject $Arguments -Depth 10 -Compress
    & $module {
        param($json, $context, $preference)
        $ErrorActionPreference = $preference
        Invoke-AgentHarnessToolCall -Call @{ id = 'python_fixture'; function = @{ name = 'run_python'; arguments = $json } } `
            -ToolTable (Get-AgentHarnessBuiltinTools) -Context $context -MaxOutputChars 8000
    } $json $pythonContext $Preference
}

$pythonContext = @{ Root = $fixture; YOLO = $true; Quiet = $true; MaxToolOutputChars = 8000 }
$savedPythonNative = & $module { ${function:New-AgentHarnessNativeProcess} }
$savedPythonConfirmation = & $module { ${function:Confirm-AgentHarnessAction} }
$savedPythonEnvironment = [Environment]::GetEnvironmentVariable('SPI_AGENT_PYTHON')
$fakePythonPath = Join-Path $fixture 'synthetic python.exe'
[IO.File]::WriteAllText($fakePythonPath, 'Synthetic path fixture; never executed.')
try {
    [Environment]::SetEnvironmentVariable('SPI_AGENT_PYTHON', $null)
    & $module {
        param($native)
        $script:PythonRealNative = $native
        $script:PythonCandidates = @{}
        $script:PythonProbeStates = @{}
        $script:PythonLookups = [Collections.Generic.List[string]]::new()
        $script:PythonLaunches = [Collections.Generic.List[object]]::new()
        $script:PythonApprovals = [Collections.Generic.List[string]]::new()
        $script:PythonAllow = $true
        $script:PythonCommand = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); [Console]::InputEncoding = [Text.UTF8Encoding]::new($false); [Console]::Write([Console]::In.ReadToEnd()); [Console]::Error.Write("synthetic stderr"); exit 7'
        function script:Get-Command {
            param($Name, $CommandType, $ErrorAction)
            $script:PythonLookups.Add($Name)
            if ($script:PythonCandidates.ContainsKey($Name)) { [pscustomobject]@{ Source = $script:PythonCandidates[$Name] } }
        }
        function script:Confirm-AgentHarnessAction {
            param($ctx, $description)
            $script:PythonApprovals.Add($description)
            $script:PythonAllow
        }
        function script:New-AgentHarnessNativeProcess {
            param($Executable, [string[]]$ArgumentList, $WorkingDirectory, $TimeoutSec, $InputText = $null)
            $script:PythonLaunches.Add(@{ Executable = $Executable; Arguments = @($ArgumentList); InputText = $InputText; Directory = $WorkingDirectory })
            if ($ArgumentList -contains '-c') {
                $state = if ($script:PythonProbeStates.ContainsKey($Executable)) { $script:PythonProbeStates[$Executable] } else { 'ok' }
                if ($state -eq 'throw') { throw 'Synthetic broken runtime' }
                $probe = [pscustomobject]@{ ProbeState = $state; Disposed = $false }
                $probe | Add-Member ScriptMethod Wait { param($ms) $true }
                $probe | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
                $probe | Add-Member ScriptMethod Snapshot {
                    [pscustomobject]@{
                        State = if ($this.ProbeState -eq 'timeout') { 'timed_out' } else { 'exited' }
                        ExitCode = if ($this.ProbeState -eq 'error') { 1 } else { 0 }
                        CaptureIncomplete = $false
                        Output = if ($this.ProbeState -eq 'wrong') { 'UNSUPPORTED' } else { 'SPI_AGENT_PYTHON_3' }
                    }
                }
                return $probe
            }
            & $script:PythonRealNative -Executable (Get-Process -Id $PID).Path `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $script:PythonCommand) `
                -WorkingDirectory $WorkingDirectory -TimeoutSec $TimeoutSec -InputText $InputText
        }
    } $savedPythonNative

    $pythonTools = & $module { Get-AgentHarnessPythonTools }
    Assert-Harness ($pythonTools.Count -eq 1 -and $pythonTools.run_python.RequiresApproval) 'Python launches use the existing approval marker'
    Assert-Harness ($pythonTools.run_python.Parameters.additionalProperties -eq $false -and $pythonTools.run_python.Parameters.required -contains 'code') 'Python schema requires code and rejects unknown arguments'
    foreach ($options in @(@{ AllowShell = $false }, @{ NoBuiltinTools = $true })) {
        Assert-Harness (-not (& $module { param($options) (Get-AgentHarnessToolTable @options).Contains('run_python') } $options)) 'Shell/builtin restrictions disable Python execution'
    }

    & $module { $script:PythonCandidates = @{ uv = 'uv-fixture'; python = 'python-fixture'; python3 = 'python3-fixture' } }
    [Environment]::SetEnvironmentVariable('SPI_AGENT_PYTHON', $fakePythonPath)
    $runtime = & $module { param($root) Resolve-AgentHarnessPythonRuntime $root ([datetime]::UtcNow.AddSeconds(60)) } $fixture
    Assert-Harness ($runtime.Kind -eq 'uv' -and (& $module { $script:PythonLookups -join ',' }) -eq 'uv') 'Usable uv wins before Python and the environment fallback'
    $probe = & $module { $script:PythonLaunches[0] }
    Assert-Harness (($probe.Arguments -join '|') -like 'run|--no-config|--no-project|--python|3|python|-X|utf8|-u|-c|*' -and $null -eq $probe.InputText) 'uv discovery validates Python 3 without executing user code or syncing the project'

    foreach ($failure in 'error', 'wrong', 'timeout', 'throw') {
        & $module { param($failure) $script:PythonProbeStates = @{ 'uv-fixture' = $failure }; $script:PythonLookups.Clear() } $failure
        $runtime = & $module { param($root) Resolve-AgentHarnessPythonRuntime $root ([datetime]::UtcNow.AddSeconds(60)) } $fixture
        Assert-Harness ($runtime.Kind -eq 'python' -and (& $module { $script:PythonLookups -join ',' }) -eq 'uv,python') "uv $failure falls back to validated Python before code execution"
    }
    & $module { $script:PythonProbeStates = @{ 'uv-fixture' = 'error'; 'python-fixture' = 'wrong' } }
    $runtime = & $module { param($root) Resolve-AgentHarnessPythonRuntime $root ([datetime]::UtcNow.AddSeconds(60)) } $fixture
    Assert-Harness ($runtime.Kind -eq 'python3') 'Python3 is tried after a nonworking Python command'
    & $module { $script:PythonCandidates.Clear(); $script:PythonLookups.Clear() }
    $runtime = & $module { param($root) Resolve-AgentHarnessPythonRuntime $root ([datetime]::UtcNow.AddSeconds(60)) } $fixture
    Assert-Harness ($runtime.Kind -eq 'SPI_AGENT_PYTHON' -and $runtime.Executable -ceq $fakePythonPath -and (& $module { $script:PythonLookups -join ',' }) -eq 'uv,python,python3') 'Absolute environment executable is the final fallback and supports spaces'

    foreach ($invalidPath in @('', 'relative-python.exe', (Join-Path $fixture 'missing-python.exe'), $fixture)) {
        [Environment]::SetEnvironmentVariable('SPI_AGENT_PYTHON', $invalidPath)
        Assert-HarnessThrows { & $module { param($root) Resolve-AgentHarnessPythonRuntime $root ([datetime]::UtcNow.AddSeconds(60)) } $fixture } '*No usable Python 3 runtime*'
    }
    & $module { $script:PythonCandidates = @{ uv = 'uv-fixture' }; $script:PythonProbeStates.Clear() }
    Assert-HarnessThrows { & $module { param($root) Resolve-AgentHarnessPythonRuntime $root ([datetime]::UtcNow.AddSeconds(-1)) } $fixture } '*exhausted timeout_sec*'

    foreach ($preference in 'Continue', 'Stop') {
        foreach ($bad in @(
            @{}, @{ code = ' ' }, @{ code = 1 }, @{ code = 'x' * (1MB + 1) }, @{ code = 'x'; unexpected = $true },
            @{ Code = 'x' }, @{ code = 'x'; timeout_sec = 0 }, @{ code = 'x'; timeout_sec = 86401 },
            @{ code = 'x'; timeout_sec = '60' }, @{ code = 'x'; timeout_sec = 1.5 },
            @{ code = 'x'; packages = $null }, @{ code = 'x'; packages = 'requests' },
            @{ code = 'x'; packages = @('') }, @{ code = 'x'; packages = @(1) },
            @{ code = 'x'; packages = @('--help') }, @{ code = 'x'; packages = @("a`nb") },
            @{ code = 'x'; packages = @('x' * 513) }, @{ code = 'x'; packages = @('x') * 65 }
        )) {
            $before = & $module { $script:PythonLaunches.Count }
            $result = Invoke-PythonFixtureTool $bad $preference
            Assert-Harness ($result.content -like 'ERROR:*' -and (& $module { $script:PythonLaunches.Count }) -eq $before) "Invalid Python arguments do not launch under $preference"
        }
        foreach ($json in '[]', '[{}]', 'null', '"code"') {
            $result = & $module {
                param($json, $ctx, $preference)
                $ErrorActionPreference = $preference
                Invoke-AgentHarnessToolCall -Call @{ id = 'invalid_python'; function = @{ name = 'run_python'; arguments = $json } } -ToolTable (Get-AgentHarnessBuiltinTools) -Context $ctx
            } $json $pythonContext $preference
            Assert-Harness ($result.content -like 'ERROR: Tool arguments must be a JSON object.*') 'Python dispatch preserves JSON-object-only arguments'
        }
    }

    & $module { $script:PythonAllow = $false; $script:PythonLaunches.Clear(); $script:PythonLookups.Clear(); $script:PythonApprovals.Clear() }
    $denied = Invoke-PythonFixtureTool @{ code = 'print("denied")'; packages = @('requests>=2'); timeout_sec = 300 }
    Assert-Harness ($denied.content -eq 'ERROR: the user denied this command.' -and (& $module { $script:PythonLaunches.Count + $script:PythonLookups.Count }) -eq 0) 'Denied Python launches perform no discovery, downloads or execution'
    $description = & $module { $script:PythonApprovals[0] }
    Assert-Harness ($description.Contains('deadline 300s') -and $description.Contains('requests>=2') -and $description.Contains('print("denied")') -and $description.Contains('downloads allowed')) 'Approval discloses code, dependencies, deadline and downloads'
    & $module { $script:PythonAllow = $true; $script:PythonLaunches.Clear() }

    $unicodeCode = "# quotes ' `" `$() ;`nprint('नमस्ते 🐍')`n" + ('#padding' * 10000)
    $result = Invoke-PythonFixtureTool @{ code = $unicodeCode; packages = @('requests>=2', 'rich'); timeout_sec = 60 }
    $launch = & $module { $script:PythonLaunches[-1] }
    Assert-Harness ($launch.InputText -ceq $unicodeCode -and $launch.Directory -ceq $fixture -and ($launch.Arguments -join '|') -eq 'run|--no-config|--no-project|--python|3|--with|requests>=2|--with|rich|python|-X|utf8|-u|-') 'Multiline Unicode code travels verbatim through stdin with individually separated dependency arguments'
    Assert-Harness ($result.content.Contains('runtime: uv') -and $result.content.Contains('state: exited') -and $result.content.Contains('exit code: 7') -and $result.content.Contains('synthetic stderr') -and $result.content.Contains('truncated; showing last') -and $result.content.Length -le 8000) 'Native stdin and noisy capture remain bounded and preserve status/nonzero exit/separate stderr'
    Assert-Harness ((& $module { $script:PythonLaunches.Count }) -eq 2) 'Execution failure is returned without retrying the snippet under another runtime'
    $short = Invoke-PythonFixtureTool @{ code = "print('नमस्ते 🐍')"; packages = @() }
    Assert-Harness ($short.content.Contains("print('नमस्ते 🐍')")) 'UTF-8 stdin and stdout round-trip non-ASCII text'

    & $module { $script:PythonCandidates = @{ python = 'python-fixture' }; $script:PythonLaunches.Clear() }
    $result = Invoke-PythonFixtureTool @{ code = 'print(1)'; packages = @('requests') }
    Assert-Harness ($result.content -like 'ERROR: Package installation requires*' -and (& $module { $script:PythonLaunches.Count }) -eq 1) 'Direct Python refuses package installation before executing code'
    $result = Invoke-PythonFixtureTool @{ code = 'print(1)' }
    Assert-Harness ($result.content.Contains('runtime: python') -and (& $module { $script:PythonLaunches[-1].Arguments -join '|' }) -eq '-X|utf8|-u|-') 'Direct Python launches without uv arguments'

    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall run_python '{"code":"print(1)"}'))), (New-HarnessResponse 'Python result inspected'))
    $roundTrip = Invoke-AgentHarness 'Execute the synthetic Python fixture' -Model custom-model -ChatUri https://provider.invalid/chat -WorkingDirectory $fixture -Quiet -YOLO -NoSkills -NoAgentsFile -NoCompletionPrompt -NoPromptHistory -NoStream -PassThru
    $roundTripRequests = @(Get-HarnessRequests)
    Assert-Harness ($roundTrip.Answer -eq 'Python result inspected' -and $roundTripRequests[0].Body.tools.function.name -contains 'run_python') 'Provider advertises the Python tool and completes a mocked execution round trip'
    Assert-Harness (@($roundTrip.Messages | Where-Object role -eq tool)[0].content.Contains('runtime: python') -and $roundTripRequests[1].Body.messages[-1].content.Contains('exit code: 7')) 'Python failure and exit status reach the next provider turn'

    & $module { $script:PythonCommand = '[Threading.Thread]::Sleep(30000)' }
    $result = Invoke-PythonFixtureTool @{ code = 'synthetic sleeping input'; timeout_sec = 1 }
    Assert-Harness ($result.content.Contains('state: timed_out') -and $result.content.Contains('exit code:')) 'One-second Python execution deadline kills a blocking native child'
    & $module { $script:PythonCommand = 'exit 0' }
    $result = Invoke-PythonFixtureTool @{ code = 'x' * 1MB; timeout_sec = 10 }
    Assert-Harness ($result.content.Contains('state: exited')) 'Early child exit with a large pending stdin write completes without deadlock'
}
finally {
    [Environment]::SetEnvironmentVariable('SPI_AGENT_PYTHON', $savedPythonEnvironment)
    & $module {
        param($native, $confirmation)
        Set-Item -LiteralPath Function:script:New-AgentHarnessNativeProcess -Value $native
        Set-Item -LiteralPath Function:script:Confirm-AgentHarnessAction -Value $confirmation
        Remove-Item -LiteralPath Function:script:Get-Command
    } $savedPythonNative $savedPythonConfirmation
}
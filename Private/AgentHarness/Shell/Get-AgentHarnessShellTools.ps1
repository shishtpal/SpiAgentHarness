function Get-AgentHarnessShellTools {
    $command = @{ type = 'string'; minLength = 1; description = 'Raw PowerShell command text. Runs in a fresh no-profile, noninteractive process.' }
    $timeout = @{ type = 'integer'; minimum = 1; maximum = 86400; description = 'Process deadline in seconds. Default 60 for run, 1800 for start; independent of model requests.' }
    $id = @{ type = 'string'; pattern = '^[a-f0-9]{32}$'; description = 'Opaque process ID returned by start_powershell in this invocation.' }
    [ordered]@{
        run_powershell = @{
            Description = 'Execute raw PowerShell synchronously. Default timeout 60s; configure timeout_sec up to 86400. Requires approval unless YOLO. Returns exit code and bounded stdout/stderr tails. Prefer start_powershell for long builds/tests.'
            RequiresApproval = $true
            Parameters = @{ type = 'object'; additionalProperties = $false; properties = @{ command = $command; timeout_sec = $timeout }; required = @('command') }
            Script = { param($a, $ctx) Invoke-AgentHarnessShellTool -Operation run -Arguments $a -Context $ctx }
        }
        start_powershell = @{
            Description = 'Start a supervised PowerShell command and return its process ID immediately. Default deadline 1800s; configure timeout_sec up to 86400. Requires approval unless YOLO. At most eight active commands. Poll or stop with this invocation-scoped ID. All owned commands stop when the harness invocation ends.'
            RequiresApproval = $true
            Parameters = @{ type = 'object'; additionalProperties = $false; properties = @{ command = $command; timeout_sec = $timeout }; required = @('command') }
            Script = { param($a, $ctx) Invoke-AgentHarnessShellTool -Operation start -Arguments $a -Context $ctx }
        }
        poll_powershell = @{
            Description = 'Inspect an owned command: running/stopping/exited/timed_out/cancelled, exit code when available, and bounded stdout/stderr tails. Tails repeat on later polls; truncation is explicit. Optional wait_ms 0-1000, default 0. Does not execute or restart commands and requires no new approval.'
            Parameters = @{ type = 'object'; additionalProperties = $false; properties = @{ process_id = $id; wait_ms = @{ type = 'integer'; minimum = 0; maximum = 1000 } }; required = @('process_id') }
            Script = { param($a, $ctx) Invoke-AgentHarnessShellTool -Operation poll -Arguments $a -Context $ctx }
        }
        stop_powershell = @{
            Description = 'Cancel an owned command and its process tree, wait up to one second, and return status/output. Repeated stops are safe. Requires only an ID created by this invocation; no new approval. If stopping, poll until terminal status.'
            Parameters = @{ type = 'object'; additionalProperties = $false; properties = @{ process_id = $id }; required = @('process_id') }
            Script = { param($a, $ctx) Invoke-AgentHarnessShellTool -Operation stop -Arguments $a -Context $ctx }
        }
    }
}
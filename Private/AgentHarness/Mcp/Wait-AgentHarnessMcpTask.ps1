function Wait-AgentHarnessMcpTask {
    param([Threading.Tasks.Task]$Task, [Diagnostics.Stopwatch]$Timer, [int]$TimeoutSec)

    while (-not $Task.IsCompleted) {
        if ($Timer.Elapsed.TotalSeconds -ge $TimeoutSec) { throw [TimeoutException]::new('MCP request timed out; its outcome may be unknown. It was not retried.') }
        # Short waits keep PowerShell interruption responsive.
        $null = [Threading.Tasks.Task]::WhenAny($Task, [Threading.Tasks.Task]::Delay(50)).GetAwaiter().GetResult()
    }
    $Task.GetAwaiter().GetResult()
}
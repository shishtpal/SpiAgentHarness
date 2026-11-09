function Wait-AgentHarnessSubAgent {
    param([hashtable]$Arguments, [hashtable]$Context)

    $seconds = 30
    if ($Arguments.ContainsKey('timeout_seconds')) {
        if ($Arguments.timeout_seconds -isnot [long] -and $Arguments.timeout_seconds -isnot [int]) { throw 'timeout_seconds must be an integer from 0 to 60.' }
        $seconds = [int]$Arguments.timeout_seconds
        if ($seconds -lt 0 -or $seconds -gt 60) { throw 'timeout_seconds must be an integer from 0 to 60.' }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $status = Get-AgentHarnessSubAgent -Id $Arguments.agent_id -Context $Context
        if ($status.State -notin 'starting', 'running' -or $timer.Elapsed.TotalSeconds -ge $seconds) { return $status }
        [Threading.Thread]::Sleep(200)
    } while ($true)
}
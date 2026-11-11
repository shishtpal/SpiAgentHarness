function Write-AgentHarnessFailureContext {
    param(
        [object[]]$Messages, [hashtable]$Context, $Candidate,
        [ValidateSet('provider_failure', 'iteration_limit')][string]$StopReason
    )

    $ErrorActionPreference = 'Stop'
    try {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
        $path = '.agents/harness/checkpoints/' + $stamp + '-' + [guid]::NewGuid().ToString('N') + '.json'
        # Raw recovery is entirely local; never retry the failing provider to summarize.
        $full = Write-AgentHarnessContext -Path $path -Mode Raw -Messages $Messages -Context $Context `
            -Provider $Candidate.Provider -Model $Candidate.Id -StopReason $StopReason
    }
    catch {
        # Saving and reporting must not replace the original failure, even with WarningPreference=Stop.
        Write-Warning 'Recovery context could not be saved. Check .agents/harness/checkpoints, file permissions and the 64 MiB limit.' -WarningAction Continue
        return
    }
    Write-Warning "Recovery context saved: $full" -WarningAction Continue
    $full
}
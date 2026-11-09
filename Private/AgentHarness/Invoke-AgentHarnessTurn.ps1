function Invoke-AgentHarnessTurn {
    param(
        [hashtable]$State, [Collections.Generic.List[object]]$Messages, [object[]]$ToolSpecs,
        [string]$ChatUri, [string]$ApiKey, [int]$TimeoutSec, [Nullable[double]]$Temperature,
        [int]$MaxModelAttempts, [int]$Iteration, [scriptblock]$Log, [switch]$NoModelRecovery
    )

    while ($State.Candidates.Count) {
        $candidate = $State.Candidates[0]
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            $connection = Get-AgentHarnessProviderConfig -Provider $candidate.Provider -ChatUri $ChatUri
            $key = if ($ApiKey) { $ApiKey }
            elseif ($connection.KeyEnvVar) { [Environment]::GetEnvironmentVariable($connection.KeyEnvVar) }
            if (-not $key -and $connection.KeyEnvVar) {
                & $Log "   note: `$env:$($connection.KeyEnvVar) is not set; sending without Authorization" 'Yellow'
            }
            $body = @{ model = $candidate.Id; messages = $Messages }
            if ($ToolSpecs.Count) {
                $body['tools'] = $ToolSpecs
                if (-not $connection.OmitToolChoice) { $body['tool_choice'] = 'auto' }
            }
            if ($null -ne $Temperature) { $body['temperature'] = [double]$Temperature }
            & $Log "[turn $Iteration] -> [$($candidate.Provider)] $($candidate.Id)" 'Cyan'
            $response = Invoke-AgentHarnessChat -Uri $connection.ChatUri -ApiKey $key -Body $body -TimeoutSec $TimeoutSec -Log $Log
            $State.Locked = $true
            return [pscustomobject]@{
                Response = $response; Candidate = $candidate; ElapsedMilliseconds = $timer.ElapsedMilliseconds
            }
        }
        catch {
            $failure = $_
            $State.Attempts++
            & $Log "   failed: $($failure.Exception.Message)" 'Yellow'
            if (-not $State.Locked) {
                if ($failure.Exception.Data['Status'] -in 401, 403) {
                    for ($i = $State.Candidates.Count - 1; $i -ge 0; $i--) {
                        if ($State.Candidates[$i].Provider -eq $candidate.Provider) { $State.Candidates.RemoveAt($i) }
                    }
                }
                else { $State.Candidates.RemoveAt(0) }
            }
            if ($State.Locked -or -not $State.Candidates.Count -or $State.Attempts -ge $MaxModelAttempts) {
                if (-not $NoModelRecovery) {
                    $replacement = Select-AgentHarnessRecoveryModel -Candidate $candidate `
                        -Status ([int]$failure.Exception.Data['Status']) -ChatUri $ChatUri -ApiKey $ApiKey -All:([bool]$State.All)
                    if ($replacement) {
                        $State.Candidates.Clear()
                        $State.Candidates.Add($replacement)
                        $State.Locked = $false
                        $State.Attempts = 0
                        & $Log "   continuing with [$($replacement.Provider)] $($replacement.Id)..." 'Yellow'
                        continue
                    }
                }
                if ($State.Locked) { throw $failure }
                throw "No working model after $($State.Attempts) attempt(s). Last error: $($failure.Exception.Message)"
            }
            & $Log '   trying next model...' 'Yellow'
        }
        finally { $timer.Stop() }
    }
}
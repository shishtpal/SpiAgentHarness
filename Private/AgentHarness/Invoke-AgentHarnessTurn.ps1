function Invoke-AgentHarnessTurn {
    param(
        [hashtable]$State,
        [Collections.Generic.List[object]]$Messages,
        [object[]]$ToolSpecs,
        [string]$ChatUri,
        [string]$ApiKey,
        [int]$TimeoutSec,
        [Nullable[double]]$Temperature,
        [int]$MaxModelAttempts,
        [int]$Iteration,
        [scriptblock]$Log,
        [switch]$NoModelRecovery,
        [hashtable]$RequestHeaders,
        [hashtable]$CompactionContext,
        [switch]$NoStream,
        [scriptblock]$OnText
    )

    $compactionRetryUsed = $false
    $preparedResend = $false
    while ($State.Candidates.Count) {
        $candidate = $State.Candidates[0]
        $State.LastCandidate = $candidate
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            $connection = Get-AgentHarnessProviderConfig -Provider $candidate.Provider -ChatUri $ChatUri
            $key = if ($ApiKey) { $ApiKey }
            elseif ($connection.KeyEnvVar) { [Environment]::GetEnvironmentVariable($connection.KeyEnvVar) }
            if (-not $key -and $connection.KeyEnvVar) {
                & $Log "   note: `$env:$($connection.KeyEnvVar) is not set; sending without Authorization" 'Yellow'
            }
            if (-not $preparedResend -and $CompactionContext.AutoCompact.Enabled) {
                $null = Invoke-AgentHarnessCompaction -Messages $Messages -Context $CompactionContext `
                    -Provider $candidate.Provider -Model $candidate.Id -Log $Log
            }
            $preparedResend = $false

            # One-turn media injection: send originals to model, keep placeholders in $Messages.
            $requestMessages = $Messages
            if ($CompactionContext -and $CompactionContext.AutoCompact -and $CompactionContext.AutoCompact.PendingInjections -and $CompactionContext.AutoCompact.PendingInjections.Count) {
                $requestMessages = [Collections.Generic.List[object]]::new()
                foreach ($m in $Messages) {
                    $copy = @{}
                    if ($m -is [Collections.IDictionary]) {
                        foreach ($k in $m.Keys) { $copy[$k] = $m[$k] }
                    }
                    else {
                        foreach ($property in $m.PSObject.Properties) { $copy[$property.Name] = $property.Value }
                    }
                    $requestMessages.Add($copy)
                }
                foreach ($inj in @($CompactionContext.AutoCompact.PendingInjections)) {
                    $mi = [int]$inj.MessageIndex
                    if ($mi -lt 0 -or $mi -ge $requestMessages.Count) { continue }
                    $msgCopy = @{}
                    foreach ($k in $requestMessages[$mi].Keys) { $msgCopy[$k] = $requestMessages[$mi][$k] }
                    if ($null -eq $inj.PartIndex) {
                        $msgCopy.content = $inj.ContentPart
                    }
                    else {
                        $parts = [Collections.Generic.List[object]]::new()
                        foreach ($p in @($msgCopy.content)) { $parts.Add($p) }
                        $pi = [int]$inj.PartIndex
                        if ($pi -ge 0 -and $pi -lt $parts.Count) { $parts[$pi] = $inj.ContentPart }
                        $msgCopy.content = $parts.ToArray()
                    }
                    $requestMessages[$mi] = $msgCopy
                }
            }

            $body = @{ model = $candidate.Id; messages = $requestMessages }
            if ($ToolSpecs.Count) {
                $body['tools'] = $ToolSpecs
                if (-not $connection.OmitToolChoice) { $body['tool_choice'] = 'auto' }
            }
            if ($null -ne $Temperature) { $body['temperature'] = [double]$Temperature }
            & $Log "[turn $Iteration] -> [$($candidate.Provider)] $($candidate.Id)" 'Cyan'

            $response = Invoke-AgentHarnessChat -Uri $connection.ChatUri -ApiKey $key -Body $body -TimeoutSec $TimeoutSec -Log $Log -RequestHeaders $RequestHeaders -Stream:(-not $NoStream) -OnText $OnText

            $State.Locked = $true
            return [pscustomobject]@{
                Response = $response; Candidate = $candidate; ElapsedMilliseconds = $timer.ElapsedMilliseconds
            }
        }
        catch {
            $failure = $_
            # A truncated streamed attempt cannot enter compaction, fallback or recovery replay.
            if ($failure.Exception.Data['StreamStarted']) { throw }
            if (-not $compactionRetryUsed -and $CompactionContext.AutoCompact.Enabled -and
                -not $CompactionContext.AutoCompact.MeasureOnly -and
                (Invoke-AgentHarnessCompaction -Classify -Failure $failure)) {
                $compactionRetryUsed = $true
                $compaction = Invoke-AgentHarnessCompaction -Messages $Messages -Context $CompactionContext `
                    -Provider $candidate.Provider -Model $candidate.Id -Reason too_long -Log $Log
                if ($compaction.Changed -and $compaction.EstimatedAfter -lt $compaction.EstimatedBefore) {
                    $preparedResend = $true
                    continue
                }
            }
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
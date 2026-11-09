function Select-AgentHarnessRecoveryModel {
    param([object]$Candidate, [int]$Status, [string]$ChatUri, [string]$ApiKey, [switch]$All)

    $statusText = if ($Status) { "HTTP $Status" } else { 'request error' }
    $action = Show-InteractiveMenu -Options @('Choose another model', 'Retry current model', 'Stop') `
        -Title "[$($Candidate.Provider)] $($Candidate.Id) failed ($statusText). Continue this conversation?"
    if ($action -eq 'Retry current model') { return $Candidate }
    if ($action -ne 'Choose another model') { return }

    $models = @()
    if ($script:FreeModelProviders[$Candidate.Provider]) {
        $query = @{ All = [bool]$All }
        # Keep explicit endpoint/key overrides on their original provider.
        if ($ChatUri -or $ApiKey) { $query['Provider'] = $Candidate.Provider }
        $models = @(Get-FreeModels @query | Where-Object {
                $_.Provider -ne $Candidate.Provider -or $_.Id -ne $Candidate.Id
            })
    }
    Select-AgentHarnessModel -Models $models -AllowCustom -Provider $Candidate.Provider `
        -Title 'Choose a replacement model; the conversation and completed tool results will be retained'
}
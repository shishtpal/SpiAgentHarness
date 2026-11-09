function Get-AgentHarnessCandidates {
    param(
        [string]$Provider, [string]$Model, [string]$ModelFilter = '*',
        [string]$ChatUri, [switch]$Pick, [scriptblock]$Log, [switch]$All
    )

    if ($Model) {
        if (-not $ChatUri -and -not $Provider) {
            $listName = if ($All) { 'model catalogue' } else { 'free-model list' }
            & $Log "Looking up '$Model' in the ${listName}s..." 'DarkGray'
            $hit = Get-FreeModels -Name $Model -All:$All | Where-Object Id -eq $Model | Select-Object -First 1
            if (-not $hit) {
                throw "Model '$Model' is not in any $listName. Pass -Provider <name> (or -ChatUri) to use a custom model id."
            }
            $Provider = $hit.Provider
        }
        return [pscustomobject]@{
            Provider = ($Provider ? $Provider : 'custom'); Id = $Model; Name = $Model; Context = $null
        }
    }

    & $Log 'Selecting a model via Get-FreeModels...' 'DarkGray'
    $query = @{ Name = $ModelFilter; All = [bool]$All }
    if ($Provider) { $query['Provider'] = $Provider }
    $found = @(Get-FreeModels @query)
    if (-not $found.Count) { throw 'Get-FreeModels returned no models (check API keys, -Provider and -ModelFilter).' }

    if ($Pick) {
        $chosen = Select-AgentHarnessModel -Models $found
        if ($null -eq $chosen) { throw 'Model selection cancelled.' }
        $chosen
        $found | Where-Object { $_ -ne $chosen }
        return
    }
    $found
}
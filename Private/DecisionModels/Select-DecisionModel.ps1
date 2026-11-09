function Select-DecisionModel {
    param([string]$Provider, [string]$ModelFilter, [switch]$All)

    $models = @(Get-DecisionModels -Provider $Provider -Name $ModelFilter -All:$All)
    if (-not $models.Count) {
        throw 'No bundled decision models match. Use -All, change -ModelFilter, or pass an explicit -Model.'
    }
    $options = @($models | ForEach-Object { '{0} [{1}]' -f $_.Name, $_.Id })
    $selection = Show-InteractiveMenu -Title 'Select a decision model' -Options $options
    if ($null -eq $selection) { throw [OperationCanceledException]::new('Decision model selection cancelled.') }
    $index = [array]::IndexOf($options, $selection)
    if ($index -lt 0) { throw 'Invalid decision model selection.' }
    $models[$index].Id
}
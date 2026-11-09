function Select-AgentHarnessModel {
    param(
        [object[]]$Models, [string]$Title = 'Select an agent model',
        [switch]$AllowCustom, [string]$Provider
    )

    $options = @(for ($i = 0; $i -lt $Models.Count; $i++) {
            '{0}. [{1}] {2}' -f ($i + 1), $Models[$i].Provider, $Models[$i].Id
        })
    if ($AllowCustom) { $options += 'Enter a model ID for the current endpoint' }
    if (-not $options.Count) { return }
    $selection = Show-InteractiveMenu -Options $options -Title $Title
    if ($null -eq $selection) { return }
    $index = [array]::IndexOf($options, $selection)
    if ($index -lt 0) { throw 'Invalid model selection.' }
    if ($index -lt $Models.Count) { return $Models[$index] }

    $id = [string](Read-Host 'Model ID')
    $id = $id.Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    [pscustomobject]@{ Provider = $Provider; Id = $id; Name = $id; Context = $null }
}
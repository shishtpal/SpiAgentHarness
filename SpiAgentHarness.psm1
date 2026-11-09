# Load definitions before initializing the module-owned provider registry.
$publicFiles = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File | Sort-Object Name)
$initializer = Join-Path $PSScriptRoot 'Private/Initialize-FreeModelProviders.ps1'
$privateFiles = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File -Recurse | Where-Object FullName -ne $initializer | Sort-Object FullName)
foreach ($file in @($publicFiles + $privateFiles)) {
    . $file.FullName
}
. $initializer
Export-ModuleMember -Function $publicFiles.BaseName -Alias @()
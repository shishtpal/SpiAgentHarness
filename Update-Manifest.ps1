$ErrorActionPreference = 'Stop'
$publicFunctions = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File | Sort-Object BaseName | Select-Object -ExpandProperty BaseName
Update-ModuleManifest -Path (Join-Path $PSScriptRoot 'SpiAgentHarness.psd1') -FunctionsToExport $publicFunctions
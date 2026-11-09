#requires -Version 7.0
<#
.SYNOPSIS
    List bundled decision models without a network request.
.DESCRIPTION
    Defaults to free variants. Use -All to include paid models. The catalogue is
    a starter list, not a live availability or pricing check. Invoke-DecisionModel
    also accepts explicit compatible model IDs outside this list.
    ExperientialLabs includes Luna Decisions and Clef; use -All for these entries
    because account-specific free allowances are not assumed.
.EXAMPLE
    Get-DecisionModels -All | Format-Table Provider, Id, IsFree
#>
function Get-DecisionModels {
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()][string]$Provider = 'OpenRouter',
        [string]$Name = '*',
        [switch]$All
    )

    Get-DecisionModelCatalog -Provider $Provider | Where-Object {
        ($All -or $_.IsFree) -and ($_.Id -like $Name -or $_.Name -like $Name)
    }
}
<#
.SYNOPSIS
    List free models, or all models with -All, from registered providers.

.PARAMETER All
    Include every model returned by the selected providers, regardless of pricing.
    Provider and Name filters still apply. By default, only free models are listed.

.EXAMPLE
    Import-Module SpiAgentHarness
    Get-FreeModels                          # all providers
    Get-FreeModels -Provider Kilo,Nous      # subset
    Get-FreeModels | Format-Table -AutoSize
    Get-FreeModels -Name '*glm*'            # filter by id/name
    Get-FreeModels -All                    # include paid and unknown-price models
    Get-FreeModels -Provider Kilo -All -Name '*glm*'

.EXAMPLE
    # Add another provider later
    Register-FreeModelProvider -Name Groq `
        -Uri 'https://api.groq.com/openai/v1/models' `
        -KeyEnvVar 'GROQ_API_KEY' -RequireKey `
        -IsFree { param($m) $m.id -like '*:free' }
#>

# ---------------------------------------------------------------------------
# Main function
# ---------------------------------------------------------------------------
function Get-FreeModels {
    [CmdletBinding()]
    param(
        [string[]]$Provider = @($script:FreeModelProviders.Keys),

        # Wildcard filter applied to id or name
        [string]$Name = '*',

        [switch]$All
    )

    foreach ($pName in $Provider) {
        $cfg = $script:FreeModelProviders[$pName]
        if (-not $cfg) {
            Write-Warning "Unknown provider '$pName'. Known: $($script:FreeModelProviders.Keys -join ', ')"
            continue
        }

        $headers = @{}
        $key = if ($cfg.KeyEnvVar) { [Environment]::GetEnvironmentVariable($cfg.KeyEnvVar) }
        if ($key) {
            $headers['Authorization'] = "Bearer $key"
        }
        elseif ($cfg.RequireKey) {
            Write-Warning "[$pName] Skipped: set `$env:$($cfg.KeyEnvVar)."
            continue
        }

        try {
            $resp   = Invoke-RestMethod -Uri $cfg.Uri -Headers $headers -TimeoutSec 30
            $models = if ($cfg.GetModels.Ast.ParamBlock.Parameters.Count -ge 2) {
                & $cfg.GetModels $resp @{ Uri = $cfg.Uri; Headers = $headers }
            }
            else { & $cfg.GetModels $resp }
        }
        catch {
            Write-Warning "[$pName] Request failed: $($_.Exception.Message)"
            continue
        }

        foreach ($m in $models) {
            if (-not $All -and -not (& $cfg.IsFree $m)) { continue }

            $display = if ($m.PSObject.Properties['name']) { $m.name } else { $m.id }
            if ($m.id -notlike $Name -and $display -notlike $Name) { continue }

            [pscustomobject]@{
                Provider = $pName
                Id       = $m.id
                Name     = $display
                Context  = if ($m.PSObject.Properties['context_length']) { $m.context_length } else { $null }
            }
        }
    }
}
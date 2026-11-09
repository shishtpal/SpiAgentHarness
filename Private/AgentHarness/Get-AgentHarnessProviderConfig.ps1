function Get-AgentHarnessProviderConfig {
    # Single point of coupling with the free-model provider registry.
    param([string]$Provider, [string]$ChatUri)

    $cfg = $null
    if ($Provider -and $script:FreeModelProviders) { $cfg = $script:FreeModelProviders[$Provider] }
    if (-not $cfg -and -not $ChatUri) {
        $known = if ($script:FreeModelProviders) { $script:FreeModelProviders.Keys -join ', ' } else { '(registry not found)' }
        throw "Unknown provider '$Provider'. Known: $known. Register it with Register-FreeModelProvider or pass -ChatUri."
    }

    $uri = $ChatUri
    if (-not $uri) {
        $uri = if ($cfg.PSObject.Properties['ChatUri'] -and $cfg.ChatUri) { $cfg.ChatUri }
        else { $cfg.Uri -replace '/models/?$', '/chat/completions' }
        if ($uri -eq $cfg.Uri) {
            throw "Cannot derive a chat endpoint from '$($cfg.Uri)'. Pass -ChatUri."
        }
    }

    [pscustomobject]@{
        ChatUri        = $uri
        KeyEnvVar      = $(if ($cfg) { $cfg.KeyEnvVar } else { $null })
        OmitToolChoice = [bool]($cfg -and $cfg.PSObject.Properties['OmitToolChoice'] -and $cfg.OmitToolChoice)
    }
}
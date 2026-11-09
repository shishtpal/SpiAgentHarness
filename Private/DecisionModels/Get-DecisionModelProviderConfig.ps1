function Get-DecisionModelProviderConfig {
    param([string]$Provider, [string]$DecisionUri, [string]$ApiKey, [string]$KeyEnvVar)

    $config = $script:FreeModelProviders[$Provider]
    if (-not $DecisionUri -and $config -and $config.PSObject.Properties['DecisionUri']) {
        $DecisionUri = $config.DecisionUri
    }
    if ([string]::IsNullOrWhiteSpace($DecisionUri)) {
        throw "Provider '$Provider' has no Decisions endpoint. Register -DecisionUri or pass -DecisionUri explicitly."
    }
    $uri = $null
    if (-not [uri]::TryCreate($DecisionUri, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo) {
        throw 'DecisionUri must be an absolute HTTPS URL without embedded credentials.'
    }
    if (-not $KeyEnvVar -and $config) { $KeyEnvVar = $config.KeyEnvVar }
    if ([string]::IsNullOrWhiteSpace($ApiKey) -and $KeyEnvVar) {
        $ApiKey = [Environment]::GetEnvironmentVariable($KeyEnvVar)
    }
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        $hint = if ($KeyEnvVar) { "Set $KeyEnvVar or pass -ApiKey." } else { 'Pass -ApiKey.' }
        throw "A Decisions API key is required. $hint"
    }
    [pscustomobject]@{ Uri = $uri.AbsoluteUri; ApiKey = $ApiKey }
}
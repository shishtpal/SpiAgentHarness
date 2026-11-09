# Loaded after the public function files by SpiAgentHarness.psm1.
# ---------------------------------------------------------------------------
# Provider registry
# ---------------------------------------------------------------------------
if (-not $script:FreeModelProviders) {
    $script:FreeModelProviders = [ordered]@{}
}

# Default "is this model free?" test, used when a provider has no custom one.
# Matches ":free" / "-free" suffixes, or pricing with prompt and completion = 0.
$script:DefaultIsFree = {
    param($m)

    if ($m.id -like '*:free' -or $m.id -like '*-free') { return $true }

    $pricing = $m.PSObject.Properties['pricing']
    if ($pricing -and $pricing.Value) {
        $p = $pricing.Value
        $prompt = $p.PSObject.Properties['prompt']
        $completion = $p.PSObject.Properties['completion']
        if ($prompt -and $completion) {
            $a = 0.0; $b = 0.0
            if ([double]::TryParse([string]$prompt.Value, [ref]$a) -and
                [double]::TryParse([string]$completion.Value, [ref]$b)) {
                return ($a -eq 0 -and $b -eq 0)
            }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Built-in providers
# ---------------------------------------------------------------------------
Register-FreeModelProvider -Name OpenRouter `
    -Uri 'https://openrouter.ai/api/v1/models' `
    -DecisionUri 'https://openrouter.ai/api/alpha/decisions' `
    -KeyEnvVar 'OPENROUTER_API_KEY'            # key optional for listing

Register-FreeModelProvider -Name Kilo `
    -Uri 'https://api.kilo.ai/api/gateway/models' `
    -KeyEnvVar 'KILO_API_KEY'                  # free models work anonymously

Register-FreeModelProvider -Name Nous `
    -Uri 'https://inference-api.nousresearch.com/v1/models' `
    -KeyEnvVar 'NOUS_API_KEY' -RequireKey

Register-FreeModelProvider -Name OpenCode `
    -Uri 'https://opencode.ai/zen/v1/models' `
    -KeyEnvVar 'OPENCODE_API_KEY' `
    -IsFree {
    param($m)
    # Zen free models are mostly named "*-free"; "big-pickle" is a known exception.
    $m.id -like '*-free' -or $m.id -eq 'big-pickle' -or (& $script:DefaultIsFree $m)
}

# The integration catalogue exposes OpenRouter-style ids, including :free lanes.
# /v1/models uses a different pricing schema; use /api/v1/models for discovery.
Register-FreeModelProvider -Name ExperientialLabs `
    -Uri 'https://api.experientiallabs.ai/api/v1/models' `
    -DecisionUri 'https://api.experientiallabs.ai/v1/systemone' `
    -ChatUri 'https://api.experientiallabs.ai/v1/chat/completions' `
    -KeyEnvVar 'EXPLABS_API_KEY' -RequireKey

Register-FreeModelProvider -Name Nube `
    -Uri 'https://api.experientiallabs.ai/api/v1/models' `
    -ChatUri 'https://ai.nube-api.com/v1/chat/completions' `
    -KeyEnvVar 'NUBE_API_KEY' -RequireKey

# Cohere lists names instead of ids and paginates its chat-model catalogue.
# No pricing is returned; use -All for discovery rather than assuming models are free.
Register-FreeModelProvider -Name Cohere `
    -Uri 'https://api.cohere.com/v1/models?endpoint=chat&page_size=1000' `
    -ChatUri 'https://api.cohere.ai/compatibility/v1/chat/completions' `
    -KeyEnvVar 'COHERE_API_KEY' -RequireKey -OmitToolChoice `
    -GetModels { param($response, $context) Get-CohereModels -Response $response -Context $context }

# Use the chat-only catalogue to exclude FIM, edit and decision models.
# Keep pricing-based free detection; use -All to include paid/unknown-price models.
Register-FreeModelProvider -Name Inception `
    -Uri 'https://api.inceptionlabs.ai/v1/chat/completions/models' `
    -ChatUri 'https://api.inceptionlabs.ai/v1/chat/completions' `
    -KeyEnvVar 'INCEPTION_API_KEY' -RequireKey

# Register in module scope so completion can access the provider registry.
Register-ArgumentCompleter -CommandName Get-FreeModels, Invoke-AgentHarness -ParameterName Provider -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    $script:FreeModelProviders.Keys | Where-Object { $_ -like "$wordToComplete*" }
}

Register-ArgumentCompleter -CommandName Get-DecisionModels, Invoke-DecisionModel -ParameterName Provider -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    $script:FreeModelProviders.Values | Where-Object {
        $_.DecisionUri -and $_.Name -like "$wordToComplete*"
    } | ForEach-Object { $_.Name }
}

Register-ArgumentCompleter -CommandName Invoke-DecisionModel -ParameterName Model -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    $provider = if ($fakeBoundParameters.Provider) { $fakeBoundParameters.Provider } else { 'OpenRouter' }
    Get-DecisionModelCatalog -Provider $provider | Where-Object { $_.Id -like "$wordToComplete*" } |
        ForEach-Object { $_.Id }
}
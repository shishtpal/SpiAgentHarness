function Assert-AgentHarnessDecisionConfig {
    param([object]$Config)

    if ($Config -isnot [Collections.IDictionary] -or $Config.profiles -isnot [Collections.IDictionary] -or
        $Config.active_profile -isnot [string] -or -not $Config.profiles.Contains($Config.active_profile)) {
        throw 'Decision configuration requires profiles and a valid active_profile.'
    }
    foreach ($profile in $Config.profiles.Values) {
        if ($profile.protocol -cnotin 'openrouter', 'openai_decisions', 'systemone' -or
            $profile.model -isnot [string] -or [string]::IsNullOrWhiteSpace($profile.model) -or
            $profile.provider -isnot [string] -or [string]::IsNullOrWhiteSpace($profile.provider) -or
            $profile.key_env_var -isnot [string] -or $profile.key_env_var -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw 'Decision profile requires a supported protocol, model, provider, and key_env_var.'
        }
        $uri = $null
        if (-not [uri]::TryCreate([string]$profile.endpoint, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
            throw 'Decision profile endpoint must be HTTPS without credentials, query, or fragment.'
        }
        if ($profile.input_modalities -isnot [Collections.IList] -or $profile.input_modalities -cnotcontains 'text' -or
            @($profile.input_modalities | Where-Object { $_ -cnotin 'text', 'image' }).Count -or
            ($profile.protocol -eq 'systemone' -and $profile.input_modalities -ccontains 'image')) {
            throw 'Decision profile input_modalities do not match the protocol.'
        }
    }
    $request = $Config.request
    if (-not (Test-DecisionModelNumber $request.timeout_sec) -or $request.timeout_sec -lt 1 -or $request.timeout_sec -gt 3600 -or
        $request.timeout_sec % 1 -ne 0 -or -not (Test-DecisionModelNumber $request.max_retries) -or
        $request.max_retries -lt 0 -or $request.max_retries -gt 5 -or $request.max_retries % 1 -ne 0 -or
        $request.automatic_model_fallback -isnot [bool] -or $request.automatic_model_fallback) {
        throw 'Decision request requires an integer timeout (1-3600), retries (0-5), and automatic_model_fallback=false.'
    }
}
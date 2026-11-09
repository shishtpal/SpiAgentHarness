function Invoke-AgentHarnessDecision {
    # Shared service for all decision-dependent tools. Tool arguments cannot override routing or credentials.
    param([Collections.IDictionary]$Config, [object]$State, [object]$Questions, [string[]]$Attachment, [string]$Root)

    $ErrorActionPreference = 'Stop'
    $profile = $Config.profiles[$Config.active_profile]
    if ($Attachment.Count -and $profile.input_modalities -cnotcontains 'image') {
        throw 'The configured decision profile does not accept image input.'
    }
    $paths = @(foreach ($file in $Attachment) { Resolve-AgentHarnessPath -Root $Root -Path $file })
    $options = @{
        Provider = $profile.provider; Model = $profile.model; Protocol = $profile.protocol
        DecisionUri = $profile.endpoint; KeyEnvVar = $profile.key_env_var
        TimeoutSec = $Config.request.timeout_sec; MaxRetries = $Config.request.max_retries
        State = $State; Questions = $Questions; Quiet = $true
    }
    if ($paths.Count) { $options.Attachment = $paths }
    Invoke-DecisionModel @options
}
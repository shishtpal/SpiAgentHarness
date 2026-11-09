function Register-FreeModelProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Uri,
        [string]$KeyEnvVar,
        [switch]$RequireKey,
        [scriptblock]$IsFree = $script:DefaultIsFree,
        # Maps the raw response to models; optional second argument has Uri/Headers.
        [scriptblock]$GetModels = { param($r) if ($r.PSObject.Properties['data']) { $r.data } else { $r } },
        # Optional chat endpoint; otherwise the harness derives it from Uri.
        [string]$ChatUri,
        # Some compatible endpoints use automatic tool selection without this field.
        [switch]$OmitToolChoice,
        # Optional endpoint implementing the OpenRouter Decisions request schema.
        [string]$DecisionUri
    )

    $script:FreeModelProviders[$Name] = [pscustomobject]@{
        Name           = $Name
        Uri            = $Uri
        KeyEnvVar      = $KeyEnvVar
        RequireKey     = [bool]$RequireKey
        IsFree         = $IsFree
        GetModels      = $GetModels
        ChatUri        = $ChatUri
        OmitToolChoice = [bool]$OmitToolChoice
        DecisionUri    = $DecisionUri
    }
}
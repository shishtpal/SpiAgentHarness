function Resolve-DecisionModelProtocol {
    param([string]$Provider, [string]$Model, [string]$Protocol, [string]$DecisionUri)

    if (-not $Protocol) {
        if ($Provider -eq 'ExperientialLabs') {
            $Protocol = switch -Regex ($Model) {
                '^gpt-6-luna-decisions(:free)?$' { 'openai_decisions'; break }
                '^clef(:free)?$' { 'systemone'; break }
                default { throw 'Specify -Protocol for this Experiential decision model.' }
            }
        }
        else { $Protocol = 'openrouter' }
    }
    if (-not $DecisionUri -and $Provider -eq 'ExperientialLabs') {
        $DecisionUri = if ($Protocol -eq 'openai_decisions') { 'https://api.experientiallabs.ai/v1/decisions' }
        else { 'https://api.experientiallabs.ai/v1/systemone' }
    }
    [pscustomobject]@{ Protocol = $Protocol; DecisionUri = $DecisionUri }
}
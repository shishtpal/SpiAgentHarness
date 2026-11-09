function Get-DecisionModelCatalog {
    param([string]$Provider = 'OpenRouter')

    # Curated starter catalogue; no unverified live capability inference or prices.
    if ($Provider -eq 'ExperientialLabs') {
        foreach ($entry in @(@('gpt-6-luna-decisions', 'openai_decisions', @('text', 'image')), @('clef', 'systemone', @('text')))) {
            [pscustomobject]@{
                Provider = $Provider; Id = $entry[0]; Name = $entry[0]; IsFree = $false
                Protocol = $entry[1]; InputModalities = $entry[2]
                QuestionTypes = @('choice', 'noul', 'score'); CatalogSource = 'Bundled'
            }
        }
        return
    }
    if ($Provider -ne 'OpenRouter') { return }
    $models = @(
        @('perplexity/pplx-decider-flash-v1.2', 'Perplexity: PPLX Decider Flash v1.2'),
        @('liquid/d1-ultra', 'Liquid AI: d1-ultra'),
        @('typesafe/jev-1.14', 'TypeSafe: Jev 1.14'),
        @('cloudflare/clef-omni', 'Cloudflare: Clef Omni'),
        @('openai/gpt-6-luna-decisions', 'OpenAI: GPT-6 Luna Decisions'),
        @('inception/mercury-decide:free', 'Inception: Mercury Decide (free)')
    )
    foreach ($model in $models) {
        [pscustomobject]@{
            Provider      = 'OpenRouter'
            Id            = $model[0]
            Name          = $model[1]
            IsFree        = $model[0].EndsWith(':free', [StringComparison]::Ordinal)
            QuestionTypes = @('choice', 'noul', 'score')
            CatalogSource = 'Bundled'
        }
    }
}
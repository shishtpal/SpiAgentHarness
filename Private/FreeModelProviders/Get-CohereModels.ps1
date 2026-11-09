function Get-CohereModels {
    param([object]$Response, [hashtable]$Context)

    $seenTokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($null -ne $Response) {
        if (-not $Response.PSObject.Properties['models']) {
            throw 'Cohere model catalogue response contained no models field.'
        }
        foreach ($model in $Response.models) {
            if (-not $model.name -or $model.endpoints -notcontains 'chat') { continue }
            [pscustomobject]@{
                id             = $model.name
                name           = $model.name
                context_length = $model.context_length
            }
        }

        $token = $Response.next_page_token
        if ([string]::IsNullOrEmpty($token)) { break }
        if (-not $seenTokens.Add($token)) { throw 'Cohere model catalogue repeated a page token.' }
        $uri = $Context.Uri + '&page_token=' + [Uri]::EscapeDataString($token)
        $Response = Invoke-RestMethod -Uri $uri -Headers $Context.Headers -TimeoutSec 30 -ErrorAction Stop
    }
}
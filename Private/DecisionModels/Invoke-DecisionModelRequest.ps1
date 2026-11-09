function Invoke-DecisionModelRequest {
    param(
        [string]$Uri, [string]$ApiKey, [string]$Json,
        [int]$TimeoutSec, [int]$MaxRetries, [scriptblock]$Log
    )

    $headers = @{ Authorization = "Bearer $ApiKey" }
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try {
            $http = Invoke-WebRequest -Method Post -Uri $Uri -Headers $headers -Body $Json `
                -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec -ErrorAction Stop
            # Hashtable parsing preserves case-sensitive JSON keys, unlike PSCustomObject parsing.
            # Reject array roots before conversion can unwrap a one-item array into an object.
            if (-not ([string]$http.Content).TrimStart().StartsWith('{', [StringComparison]::Ordinal)) {
                throw 'Decisions endpoint returned a non-object JSON response.'
            }
            $response = ConvertFrom-Json -InputObject $http.Content -AsHashtable -ErrorAction Stop
            if ($response.Contains('error') -and $response.error) {
                $status = 0
                [void][int]::TryParse([string]$response.error.code, [ref]$status)
                $embeddedError = [Exception]::new('Decisions API returned an error object.')
                $embeddedError.Data['Status'] = $status
                throw $embeddedError
            }
            return $response
        }
        catch {
            $status = 0
            $retryAfter = $null
            if ($_.Exception.Data.Contains('Status')) { $status = [int]$_.Exception.Data['Status'] }
            elseif ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
                try {
                    $retry = $_.Exception.Response.Headers.RetryAfter
                    if ($retry.Delta) { $retryAfter = $retry.Delta.TotalSeconds }
                    elseif ($retry.Date) { $retryAfter = ($retry.Date - [DateTimeOffset]::UtcNow).TotalSeconds }
                }
                catch { $retryAfter = $null }
            }
            if (($status -eq 429 -or ($status -ge 500 -and $status -le 599)) -and $attempt -lt $MaxRetries) {
                $delay = if ($null -ne $retryAfter) { [int][Math]::Ceiling([Math]::Clamp($retryAfter, 0, 30)) }
                else { [int][Math]::Min([Math]::Pow(2, $attempt + 1), 30) }
                & $Log "HTTP $status; retrying decision request in ${delay}s." 'Yellow'
                Start-Sleep -Seconds $delay
                continue
            }
            # Upstream exceptions/bodies can echo credentials or state. Do not include them.
            $reason = switch ($status) {
                400 { 'Invalid request or unsupported question schema.' }
                401 { 'Authentication failed; check the configured API key.' }
                402 { 'Insufficient provider credits.' }
                403 { 'Access denied by the provider.' }
                404 { 'Model or Decisions endpoint not found.' }
                413 { 'Decision request is too large.' }
                429 { 'Rate limit exceeded.' }
                0 { 'Connection failed, timed out, or returned an invalid API response.' }
                default { 'The provider could not complete the decision request.' }
            }
            $failure = [Exception]::new("Decisions request failed (HTTP $status). $reason")
            $failure.Data['Status'] = $status
            throw $failure
        }
    }
}
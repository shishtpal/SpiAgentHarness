function Invoke-AgentHarnessChat {
    # POST one chat/completions request. Retries 429/5xx; throws with .Data['Status'] set.
    param(
        [string]$Uri, [string]$ApiKey, [hashtable]$Body,
        [int]$TimeoutSec = 120, [scriptblock]$Log, [hashtable]$RequestHeaders,
        [switch]$Stream, [scriptblock]$OnText
    )

    $headers = @{}
    if ($RequestHeaders) {
        foreach ($name in $RequestHeaders.Keys) { $headers[$name] = $RequestHeaders[$name] }
    }
    if ($ApiKey) { $headers['Authorization'] = "Bearer $ApiKey" }
    $requestBody = $Body.Clone()
    if ($Stream) {
        $requestBody.stream = $true
        $requestBody.stream_options = @{ include_usage = $true }
    }
    $json = ConvertTo-Json -InputObject $requestBody -Depth 30 -Compress
    $delay = 2

    for ($try = 1; $try -le 4; $try++) {
        try {
            $resp = Invoke-AgentHarnessChatRequest -Uri $Uri -Headers $headers -Json $json -TimeoutSec $TimeoutSec -Stream:$Stream -OnText $OnText

            # Some gateways return HTTP 200 with an error object
            if ($resp.PSObject.Properties['error'] -and $resp.error) {
                $m = if ($resp.error.PSObject.Properties['message']) { $resp.error.message }
                else { $resp.error | ConvertTo-Json -Compress }
                $code = 0
                [void][int]::TryParse([string]$resp.error.code, [ref]$code)
                $ex = [Exception]::new("API error: $m")
                $ex.Data['Status'] = $code
                throw $ex
            }
            if (-not $resp.choices -or -not $resp.choices[0].message) {
                throw [Exception]::new('Response contained no assistant message.')
            }
            return $resp
        }
        catch {
            $err = $_
            # Never replay an attempt whose provisional output may already be visible.
            if ($err.Exception.Data['StreamStarted']) { throw }
            $status = $null
            if ($err.Exception.Data.Contains('Status')) { $status = $err.Exception.Data['Status'] }
            elseif ($err.Exception.PSObject.Properties['Response'] -and $err.Exception.Response) {
                $status = [int]$err.Exception.Response.StatusCode
            }
            $detail = if ($err.ErrorDetails.Message) { $err.ErrorDetails.Message } else { $err.Exception.Message }

            if ($status -in 429, 500, 502, 503, 504 -and $try -lt 4) {
                if ($Log) { & $Log "   HTTP $status - retrying in ${delay}s" 'Yellow' }
                Start-Sleep -Seconds $delay
                $delay *= 2
                continue
            }
            $ex = [Exception]::new("HTTP $status : $detail")
            $ex.Data['Status'] = [int]($status ?? 0)
            throw $ex
        }
    }
}
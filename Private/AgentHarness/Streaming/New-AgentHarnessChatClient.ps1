function New-AgentHarnessChatClient {
    # Created only for an explicit chat request; this factory is the network test seam.
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    return $client
}
function ConvertTo-AgentHarnessMcpServerInfo {
    param([string]$Name, [hashtable]$Config, [string]$WorkingDirectory)

    $secrets = [Collections.Generic.List[string]]::new()
    foreach ($map in $Config.Environment, $Config.Headers) {
        if ($map -isnot [Collections.IDictionary]) { continue }
        foreach ($value in $map.Values) {
            $secrets.Add([string]$value)
            if ([string]$value -match '^(?:Bearer|Basic)\s+(.+)$') { $secrets.Add($Matches[1]) }
        }
    }
    $redaction = @{ Secrets = $secrets }
    $transport = if ($Config.Transport) { [string]$Config.Transport } elseif ($Config.Url) { 'http' } else { 'stdio' }
    $endpoint = [string]$Config.Command
    if ($transport -eq 'http') {
        $url = $null
        if ([uri]::TryCreate([string]$Config.Url, [UriKind]::Absolute, [ref]$url) -and $url.Scheme -in 'http', 'https') {
            $safeUrl = [UriBuilder]::new($url)
            $safeUrl.UserName = ''; $safeUrl.Password = ''; $safeUrl.Query = ''; $safeUrl.Fragment = ''
            $endpoint = $safeUrl.Uri.AbsoluteUri
        }
        else { $endpoint = '(invalid URL)' }
    }
    $allowed = [string[]]@()
    $autoApprove = [string[]]@()
    if ($Config.ContainsKey('AllowedTools')) { $allowed = [string[]]@($Config.AllowedTools) }
    if ($Config.ContainsKey('AutoApproveTools')) { $autoApprove = [string[]]@($Config.AutoApproveTools) }
    $info = [pscustomobject]@{
        PSTypeName = 'SpiAgentHarness.McpServer'
        Name = $Name
        Transport = $transport
        Endpoint = Protect-AgentHarnessMcpText -Text $endpoint -Connection $redaction
        WorkingDirectory = Protect-AgentHarnessMcpText -Text ($Config.WorkingDirectory ?? $WorkingDirectory) -Connection $redaction
        AllToolsAllowed = -not $Config.ContainsKey('AllowedTools')
        AllowedTools = $allowed
        AutoApproveTools = $autoApprove
    }
    $display = [Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]@('Name', 'Transport', 'Endpoint'))
    $info.PSObject.Members.Add([Management.Automation.PSMemberSet]::new('PSStandardMembers', [Management.Automation.PSMemberInfo[]]@($display)))
    $info
}
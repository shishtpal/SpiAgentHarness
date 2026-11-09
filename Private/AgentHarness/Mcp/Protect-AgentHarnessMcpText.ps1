function Protect-AgentHarnessMcpText {
    param([string]$Text, [hashtable]$Connection)

    foreach ($secret in $Connection.Secrets) {
        if (-not [string]::IsNullOrEmpty($secret)) { $Text = $Text.Replace($secret, '[REDACTED]') }
    }
    $Text
}
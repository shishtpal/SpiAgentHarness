function Limit-AgentHarnessText {
    param([string]$Text, [int]$Max = 300)
    if ($Text.Length -le $Max) { $Text } else { $Text.Substring(0, $Max) + '...' }
}
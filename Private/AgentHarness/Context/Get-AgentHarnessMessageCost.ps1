function Get-AgentHarnessMessageCost {
    param([object]$Message)

    [long]$cost = 0
    if ($Message.content -is [string]) { $cost += $Message.content.Length }
    else {
        foreach ($part in $Message.content) {
            switch -CaseSensitive ($part.type) {
                'text' { $cost += ([string]$part.text).Length }
                'image_url' { $cost += ([string]$part.image_url.url).Length }
                'video_url' { $cost += ([string]$part.video_url.url).Length }
                'file' { $cost += ([string]$part.file.file_data).Length }
                default { $cost += (ConvertTo-Json -InputObject $part -Depth 30 -Compress -WarningAction Stop).Length }
            }
        }
    }
    foreach ($call in $Message.tool_calls) { $cost += ([string]$call.function.arguments).Length }
    $cost
}
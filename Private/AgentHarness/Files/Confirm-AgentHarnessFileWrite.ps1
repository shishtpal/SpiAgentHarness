function Confirm-AgentHarnessFileWrite {
    param([hashtable]$Context, [string]$Path, [string]$Content, [int]$ByteCount, [string]$Hash)

    if ($Context.YOLO) { return $true }
    $counts = "UTF-16 chars: $($Content.Length); UTF-8 bytes: $ByteCount; SHA-256: $Hash; exact content (no added newline)."
    if ($Content.Length -le 16000) {
        return Confirm-AgentHarnessAction $Context "write ${Path}:`n$Content`n`n$counts"
    }
    $Context.ApprovalFeedback = $null
    $ranges = [Collections.Generic.List[object]]::new()
    for ($offset = 0; $offset -lt $Content.Length;) {
        $count = [Math]::Min(8000, $Content.Length - $offset)
        if ($offset + $count -lt $Content.Length -and [char]::IsHighSurrogate($Content[$offset + $count - 1])) { $count-- }
        $ranges.Add(@{ Offset = $offset; Count = $count })
        $offset += $count
    }
    $pages = $ranges.Count
    for ($index = 0; $index -lt $pages; $index++) {
        $page = $index + 1
        Write-AgentHarnessBlock -Title "Review write $Path (page $page/$pages)" `
            -Text $Content.Substring($ranges[$index].Offset, $ranges[$index].Count) -Color Yellow
        if ($page -lt $pages) {
            $reply = [string](Read-Host 'Enter for next page, or type no/guidance to cancel this write')
            Write-AgentHarnessPromptHistory -Context $Context -Type 'approval_reply' -Text $reply
            if ($reply.Length) {
                if ($reply.Trim() -notmatch '^(n|no)$') { $Context.ApprovalFeedback = $reply }
                return $false
            }
        }
    }
    Confirm-AgentHarnessAction $Context "write ${Path}: reviewed all $pages pages.`n$counts"
}
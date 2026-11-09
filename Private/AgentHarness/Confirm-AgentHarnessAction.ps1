function Confirm-AgentHarnessAction {
    param($Ctx, [string]$Description)
    $Ctx.ApprovalFeedback = $null
    if ($Ctx.YOLO) { return $true }
    Write-AgentHarnessBlock -Title 'Approval required' -Text $Description -Color Yellow
    if (-not $Ctx.NoPromptSound) {
        try { Invoke-Sound }
        catch { } # Audio must not prevent the user from approving or denying an action.
    }
    $reply = Read-Host 'Allow? [y/N, or type guidance to skip and redirect the agent]'
    $choice = ([string]$reply).Trim()
    if ($choice -match '^(y|yes)$') { return $true }
    if ($choice -and $choice -notmatch '^(n|no)$') {
        $Ctx.ApprovalFeedback = [string]$reply
    }
    return $false
}
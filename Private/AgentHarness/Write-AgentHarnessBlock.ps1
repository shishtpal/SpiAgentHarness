function Write-AgentHarnessBlock {
    param(
        [string]$Title, [string]$Text, [ConsoleColor]$Color = 'Cyan', [switch]$Quiet
    )

    if ($Quiet) { return }
    Write-Host ''
    Write-Host $Title -ForegroundColor $Color
    Write-Host ('-' * [Math]::Min(80, [Math]::Max(24, $Title.Length))) -ForegroundColor DarkGray
    # Keep original spacing and line breaks, particularly for Format-Table output.
    Write-Host $Text -ForegroundColor Gray
    Write-Host ''
}
function Read-InteractiveText {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Description,
        [scriptblock]$KeyReader
    )

    $readKey = if ($KeyReader) { $KeyReader } else { { [Console]::ReadKey($true) } }
    $text = [Text.StringBuilder]::new()
    Write-Host $Title -ForegroundColor Cyan
    Write-Host $Description
    Write-Host '[TYPE] Answer  [BACKSPACE] Erase  [ENTER] Submit nonblank answer  [ESC] Cancel' -ForegroundColor DarkGray
    Write-Host '> ' -NoNewline
    $cursorOriginal = $null
    try {
        try { $cursorOriginal = [Console]::CursorVisible; [Console]::CursorVisible = $true } catch { }
        while ($true) {
            $key = & $readKey
            if ($null -eq $key -or $key.Key -eq 'Escape') { Write-Host ''; return $null }
            switch ($key.Key) {
                'Enter' {
                    if (-not [string]::IsNullOrWhiteSpace($text.ToString())) {
                        Write-Host ''
                        return $text.ToString()
                    }
                }
                'Backspace' {
                    if ($text.Length -gt 0) {
                        $text.Length--
                        Write-Host "`b `b" -NoNewline
                    }
                }
                default {
                    if ($key.KeyChar -ne [char]0 -and -not [char]::IsControl($key.KeyChar)) {
                        $null = $text.Append($key.KeyChar)
                        Write-Host $key.KeyChar -NoNewline
                    }
                }
            }
        }
    }
    finally {
        if ($null -ne $cursorOriginal) {
            try { [Console]::CursorVisible = $cursorOriginal } catch { }
        }
    }
}
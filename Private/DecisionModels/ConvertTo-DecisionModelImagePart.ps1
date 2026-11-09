function ConvertTo-DecisionModelImagePart {
    # Paths resolve against the current PowerShell location, like -StateFile and -QuestionsFile.
    param([string]$Path, [long]$MaxBytes = [long]::MaxValue, [switch]$ValidateSignature)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Attachment paths cannot be blank.' }
    try {
        $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($file -isnot [IO.FileInfo]) { throw 'Not a filesystem file.' }
    }
    catch { throw 'Cannot read Attachment. Supply an existing, readable image file.' }

    $mimeTypes = @{
        '.png'  = 'image/png'
        '.jpg'  = 'image/jpeg'
        '.jpeg' = 'image/jpeg'
        '.gif'  = 'image/gif'
        '.webp' = 'image/webp'
    }
    $mimeType = $mimeTypes[$file.Extension.ToLowerInvariant()]
    if (-not $mimeType) { throw "Attachment must be a PNG, JPEG, GIF or WebP image: $($file.Name)" }

    if ($file.Length -le 0 -or $file.Length -gt $MaxBytes) { throw 'Attachment is empty or exceeds the image size limit.' }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ($ValidateSignature) {
        $signature = [BitConverter]::ToString($bytes, 0, [Math]::Min(12, $bytes.Length))
        $valid = switch ($mimeType) {
            'image/png' { $signature -like '89-50-4E-47-0D-0A-1A-0A*' }
            'image/jpeg' { $signature -like 'FF-D8-FF*' }
            'image/gif' { $signature -like '47-49-46-38-37-61*' -or $signature -like '47-49-46-38-39-61*' }
            'image/webp' { $signature -like '52-49-46-46-??-??-??-??-57-45-42-50*' }
        }
        if (-not $valid) { throw 'Attachment content does not match its image type.' }
    }
    @{ type = 'image_url'; image_url = @{ url = "data:${mimeType};base64,$([Convert]::ToBase64String($bytes))" } }
}
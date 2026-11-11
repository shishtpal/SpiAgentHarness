function ConvertTo-AgentHarnessAttachment {
    # Explicit user attachments may live outside the file tools' working directory.
    param(
        [string]$Path,
        [string]$WorkingDirectory,
        [switch]$PlaceholderMode
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Attachment paths cannot be blank.' }
    $fullPath = [IO.Path]::Combine($WorkingDirectory, $Path)
    $file = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($file -isnot [IO.FileInfo]) { throw "Attachment must be a local file: $Path" }
    $extension = $file.Extension.ToLowerInvariant()

    # Text attachments work with ordinary chat models and retain their filename.
    $textExtensions = @(
        '.txt', '.md', '.markdown', '.csv', '.tsv', '.json', '.jsonl', '.xml', '.yaml', '.yml',
        '.log', '.ini', '.toml', '.html', '.htm', '.css', '.js', '.ts', '.py', '.ps1', '.sql'
    )
    if ($extension -in $textExtensions) {
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        $text = [IO.File]::ReadAllText($file.FullName, $encoding)
        $part = @{ type = 'text'; text = "Attachment: $($file.Name)`n$text" }
        if ($PlaceholderMode) {
            return @{ Part = $part }
        }
        return $part
    }

    $mimeTypes = @{
        '.png'  = 'image/png'
        '.jpg'  = 'image/jpeg'
        '.jpeg' = 'image/jpeg'
        '.gif'  = 'image/gif'
        '.webp' = 'image/webp'
        '.bmp'  = 'image/bmp'
        '.tif'  = 'image/tiff'
        '.tiff' = 'image/tiff'
        '.svg'  = 'image/svg+xml'
        '.heic' = 'image/heic'
        '.avif' = 'image/avif'
        '.mp4'  = 'video/mp4'
        '.m4v'  = 'video/mp4'
        '.mpeg' = 'video/mpeg'
        '.mpg'  = 'video/mpeg'
        '.mov'  = 'video/quicktime'
        '.webm' = 'video/webm'
        '.avi'  = 'video/x-msvideo'
        '.mkv'  = 'video/x-matroska'
        '.wmv'  = 'video/x-ms-wmv'
        '.3gp'  = 'video/3gpp'
        '.pdf'  = 'application/pdf'
        '.doc'  = 'application/msword'
        '.docx' = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
        '.xls'  = 'application/vnd.ms-excel'
        '.xlsx' = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        '.ppt'  = 'application/vnd.ms-powerpoint'
        '.pptx' = 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
        '.zip'  = 'application/zip'
    }
    $mimeType = $mimeTypes[$extension]
    if (-not $mimeType) { $mimeType = 'application/octet-stream' }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $sizeMb = [math]::Round($bytes.Length / 1MB, 2)
    $dataUrl = "data:${mimeType};base64,$([Convert]::ToBase64String($bytes))"
    if ($mimeType.StartsWith('image/')) {
        $contentPart = @{ type = 'image_url'; image_url = @{ url = $dataUrl } }
        if ($PlaceholderMode) {
            $placeholder = "[image: $($file.Name) — $sizeMb MB, $mimeType]"
            return @{ Part = @{ type = 'text'; text = $placeholder }; ContentPart = $contentPart; Placeholder = $placeholder }
        }
        return $contentPart
    }
    if ($mimeType.StartsWith('video/')) {
        $contentPart = @{ type = 'video_url'; video_url = @{ url = $dataUrl } }
        if ($PlaceholderMode) {
            $placeholder = "[video: $($file.Name) — $sizeMb MB, $mimeType]"
            return @{ Part = @{ type = 'text'; text = $placeholder }; ContentPart = $contentPart; Placeholder = $placeholder }
        }
        return $contentPart
    }
    $contentPart = @{ type = 'file'; file = @{ filename = $file.Name; file_data = $dataUrl } }
    if ($PlaceholderMode) {
        $placeholder = "[file: $($file.Name) — $sizeMb MB, $mimeType]"
        return @{ Part = @{ type = 'text'; text = $placeholder }; ContentPart = $contentPart; Placeholder = $placeholder }
    }
    $contentPart
}
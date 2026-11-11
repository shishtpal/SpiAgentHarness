function Get-AgentHarnessClipboardImage {
    param([switch]$PlaceholderOnly)

    # Windows clipboard APIs require STA, even when the caller is running in MTA.
    if (-not $IsWindows) { throw 'Clipboard screenshots require Windows. Save the image and use @attach("path") on this platform.' }

    $runspace = [runspacefactory]::CreateRunspace()
    $reader = [powershell]::Create()
    try {
        $runspace.ApartmentState = [Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $reader.Runspace = $runspace
        [void]$reader.AddScript(@'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$image = [Windows.Forms.Clipboard]::GetImage()
if ($null -eq $image) { throw 'No image found in the clipboard. Copy a screenshot first, then submit @clipboard again.' }
$stream = $null
try {
    $stream = [IO.MemoryStream]::new()
    $image.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    [Convert]::ToBase64String($stream.ToArray())
}
finally {
    if ($stream) { $stream.Dispose() }
    $image.Dispose()
}
'@)
        $result = @($reader.Invoke())
        if ($reader.HadErrors) { throw "Cannot attach clipboard screenshot: $($reader.Streams.Error[0].Exception.Message)" }
        if ($result.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$result[0])) {
            throw 'No image data returned from the clipboard.'
        }
        $dataUrl = "data:image/png;base64,$($result[0])"
        $contentPart = @{ type = 'image_url'; image_url = @{ url = $dataUrl } }
        if ($PlaceholderOnly) {
            $bytes = [Convert]::FromBase64String([string]$result[0])
            $sizeMb = [math]::Round($bytes.Length / 1MB, 2)
            $placeholder = "[image: clipboard — $sizeMb MB, image/png]"
            return @{
                PlaceholderPart = @{ type = 'text'; text = $placeholder }
                ContentPart     = $contentPart
                Placeholder     = $placeholder
            }
        }
        $contentPart
    }
    finally {
        $reader.Dispose()
        $runspace.Dispose()
    }
}
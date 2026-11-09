<#
.SYNOPSIS
    Plays an alarm sound to draw attention to the console.
.DESCRIPTION
    Prefers Windows alarm WAVs, then ring tones. File playback is asynchronous.
    If playback fails, plays three pairs of alternating beeps.
.PARAMETER Duration
    Duration of each fallback tone in milliseconds (default: 300).
.PARAMETER Frequency
    Lower fallback tone frequency in Hz (default: 1200). The higher tone is 600 Hz higher.
.EXAMPLE
    Invoke-Sound
.EXAMPLE
    Invoke-Sound -Duration 500 -Frequency 1000
#>
function Invoke-Sound {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 10000)][int]$Duration = 300,
        [ValidateRange(37, 32767)][int]$Frequency = 1200
    )

    if ($IsWindows -and $env:SystemRoot) {
        $mediaDirectory = Join-Path $env:SystemRoot 'Media'
        $names = @(1..10 | ForEach-Object { 'Alarm{0:D2}.wav' -f $_ }) + @('Ring01.wav', 'Ring02.wav')
        foreach ($name in $names) {
            $path = Join-Path $mediaDirectory $name
            try {
                if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Invoke-SoundFile -Path $path)) {
                    return
                }
            }
            catch { } # Try another alarm file if this one cannot play.
        }
    }

    try { Invoke-SoundBeep -Duration $Duration -Frequency $Frequency | Out-Null }
    catch { } # Unavailable audio must not stop the caller.
}
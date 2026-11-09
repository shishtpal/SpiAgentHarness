function Invoke-SoundBeep {
    param([int]$Duration = 300, [int]$Frequency = 1200)

    $higherFrequency = [Math]::Min(32767, $Frequency + 600)
    try {
        for ($i = 0; $i -lt 3; $i++) {
            [Console]::Beep($Frequency, $Duration)
            [Console]::Beep($higherFrequency, $Duration)
        }
    }
    catch { } # Some platforms or devices do not support console beeps.
}
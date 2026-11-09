#requires -Version 7.0
# Run with: pwsh -NoProfile -File ./Tests/Invoke-Sound.Tests.ps1
# Check alarm selection without playing audible sounds or loading Initialize.ps1.
$ErrorActionPreference = 'Stop'
# Test dependencies must never auto-load a user-installed legacy module.
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$repo = Split-Path $PSScriptRoot -Parent
$checks = 0
$module = $null

function Assert-Sound {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}

function Set-SoundScenario {
    param([string[]]$Files = @(), [hashtable]$Success = @{}, [string[]]$Throws = @(), [switch]$BeepThrows)
    & $script:module {
        param($files, $success, $throws, $beepThrows)
        $script:ExistingFiles = $files
        $script:PlaybackSuccess = $success
        $script:PlaybackThrows = $throws
        $script:BeepThrows = $beepThrows
        $script:Attempts.Clear()
        $script:Beeps.Clear()
    } $Files $Success $Throws ([bool]$BeepThrows)
}

try {
    foreach ($relativePath in 'Private/Console/Invoke-Sound.ps1', 'Private/Sound/Invoke-SoundFile.ps1', 'Private/Sound/Invoke-SoundBeep.ps1') {
        $tokens = $null; $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $relativePath), [ref]$tokens, [ref]$parseErrors)
        Assert-Sound ($parseErrors.Count -eq 0) "Parse $relativePath"
    }
    $module = New-Module -Name SpiSoundTests -ScriptBlock {
        param($root)
        . (Join-Path $root 'Private/Console/Invoke-Sound.ps1')
        . (Join-Path $root 'Private/Sound/Invoke-SoundFile.ps1')
        . (Join-Path $root 'Private/Sound/Invoke-SoundBeep.ps1')
        Export-ModuleMember -Function Invoke-Sound
    } -ArgumentList $repo
    Import-Module $module

    # Compile the real native wrapper and verify missing files are rejected before native playback.
    $missingPath = Join-Path ([IO.Path]::GetTempPath()) ('SpiSoundMissing-' + [guid]::NewGuid().ToString('N') + '.wav')
    $first = & $module { param($path) Invoke-SoundFile -Path $path } $missingPath
    $second = & $module { param($path) Invoke-SoundFile -Path $path } $missingPath
    Assert-Sound ($first -eq $false -and $second -eq $false) 'Missing WAV fails silently on repeated calls without duplicate type errors'

    & $module {
        $script:Attempts = [Collections.Generic.List[string]]::new()
        $script:Beeps = [Collections.Generic.List[object]]::new()
        function script:Test-Path {
            param($LiteralPath, $PathType)
            $script:ExistingFiles -contains (Split-Path $LiteralPath -Leaf)
        }
        function script:Invoke-SoundFile {
            param($Path)
            $name = Split-Path $Path -Leaf
            $script:Attempts.Add($name)
            if ($script:PlaybackThrows -contains $name) { throw 'mock file playback unavailable' }
            [bool]$script:PlaybackSuccess[$name]
        }
        function script:Invoke-SoundBeep {
            param($Duration, $Frequency)
            $script:Beeps.Add([pscustomobject]@{ Duration = $Duration; Frequency = $Frequency })
            if ($script:BeepThrows) { throw 'mock beep unavailable' }
            'Mock audio return value must not leak to the pipeline.'
        }
    }

    if ($IsWindows) {
        Set-SoundScenario -Files @('Alarm01.wav', 'Ring01.wav') -Success @{ 'Alarm01.wav' = $true; 'Ring01.wav' = $true }
        $output = @(Invoke-Sound)
        Assert-Sound ((& $module { $script:Attempts -join ',' }) -eq 'Alarm01.wav') 'First Windows alarm takes priority over ringing or notification sounds'
        Assert-Sound ($output.Count -eq 0 -and (& $module { $script:Beeps.Count }) -eq 0) 'Successful alarm does not beep or emit pipeline output'

        Set-SoundScenario -Files @('Alarm01.wav', 'Alarm02.wav') -Success @{ 'Alarm02.wav' = $true }
        Invoke-Sound
        Assert-Sound ((& $module { $script:Attempts -join ',' }) -eq 'Alarm01.wav,Alarm02.wav' -and (& $module { $script:Beeps.Count }) -eq 0) 'False native playback result tries the next alarm'

        Set-SoundScenario -Files @('Alarm01.wav', 'Alarm02.wav') -Success @{ 'Alarm02.wav' = $true } -Throws @('Alarm01.wav')
        Invoke-Sound
        Assert-Sound ((& $module { $script:Attempts -join ',' }) -eq 'Alarm01.wav,Alarm02.wav') 'Playback exceptions do not prevent trying another alarm'

        Set-SoundScenario -Files @('Alarm10.wav', 'Ring01.wav') -Success @{ 'Alarm10.wav' = $true; 'Ring01.wav' = $true }
        Invoke-Sound
        Assert-Sound ((& $module { $script:Attempts -join ',' }) -eq 'Alarm10.wav') 'All numbered alarms are preferred before ring tones'

        Set-SoundScenario -Files @('Ring01.wav') -Success @{ 'Ring01.wav' = $true }
        Invoke-Sound
        Assert-Sound ((& $module { $script:Attempts -join ',' }) -eq 'Ring01.wav') 'Ring tone used when alarms are absent'

        Set-SoundScenario -Files @('Alarm01.wav', 'Ring01.wav', 'Ring02.wav')
        Invoke-Sound
        Assert-Sound ((& $module { $script:Attempts -join ',' }) -eq 'Alarm01.wav,Ring01.wav,Ring02.wav' -and (& $module { $script:Beeps.Count }) -eq 1) 'All failed WAV candidates lead to one fallback alarm'
    }

    Set-SoundScenario
    $output = @(Invoke-Sound)
    $beep = & $module { $script:Beeps[0] }
    Assert-Sound ($beep.Duration -eq 300 -and $beep.Frequency -eq 1200) 'Fallback uses stronger default tone settings'
    Assert-Sound ($output.Count -eq 0) 'Fallback emits no pipeline output'
    Set-SoundScenario
    Invoke-Sound -Duration 500 -Frequency 1000
    $beep = & $module { $script:Beeps[0] }
    Assert-Sound ($beep.Duration -eq 500 -and $beep.Frequency -eq 1000) 'Existing Duration and Frequency parameters reach the fallback'
    Set-SoundScenario -BeepThrows
    $output = @(Invoke-Sound)
    Assert-Sound ($output.Count -eq 0) 'Unavailable fallback audio does not throw or emit output'
    foreach ($invalid in @(@{ Duration = 0 }, @{ Duration = 10001 }, @{ Frequency = 36 }, @{ Frequency = 32768 })) {
        $thrown = $false
        try { Invoke-Sound @invalid } catch { $thrown = $_.Exception.Message -like '*Cannot validate argument*' }
        Assert-Sound $thrown 'Invalid audio settings are rejected'
    }
    Write-Host "Passed $checks sound checks. Audible playback was mocked; native checks used missing files."
}
finally {
    if ($module) { Remove-Module $module -Force }
}
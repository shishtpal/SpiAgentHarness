#requires -Version 7.0
# Run with: pwsh -NoProfile -File ./Tests/Read-InteractiveText.Tests.ps1
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$repo = Split-Path $PSScriptRoot -Parent
$checks = 0
$module = $null
function Assert-Text {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}
function New-TextKey {
    param([ConsoleKey]$Key = 'A', [char]$Char = [char]0)
    [ConsoleKeyInfo]::new($Char, $Key, $false, $false, $false)
}
function New-TextReader {
    param([ConsoleKeyInfo[]]$Keys)
    $queue = [Collections.Generic.Queue[ConsoleKeyInfo]]::new()
    foreach ($key in $Keys) { $queue.Enqueue($key) }
    { if ($queue.Count) { $queue.Dequeue() } else { $null } }.GetNewClosure()
}
try {
    $module = New-Module -Name SpiInteractiveTextTests -ScriptBlock {
        param($root)
        . (Join-Path $root 'Private/Console/Read-InteractiveText.ps1')
        . (Join-Path $root 'Private/Console/Test-InteractiveConsole.ps1')
        $script:Rendered = [Collections.Generic.List[string]]::new()
        function Write-Host { param($Object, $ForegroundColor, [switch]$NoNewline) $script:Rendered.Add([string]$Object) }
        Export-ModuleMember -Function Read-InteractiveText, Test-InteractiveConsole
    } -ArgumentList $repo
    Import-Module $module
    $keys = @((New-TextKey -Key Backspace), (New-TextKey -Key Enter), (New-TextKey -Key Spacebar -Char ' '),
        (New-TextKey -Key Enter), (New-TextKey -Char 'A'), (New-TextKey -Char 'x'), (New-TextKey -Key Backspace),
        (New-TextKey -Char 'b'), (New-TextKey -Key Enter))
    $answer = Read-InteractiveText -Title 'Name?' -Description 'For the header.' -KeyReader (New-TextReader $keys)
    Assert-Text ($answer -ceq ' Ab') 'Text input ignores blank submissions, edits with Backspace and preserves actual whitespace'
    $rendered = & $module { $script:Rendered -join "`n" }
    Assert-Text ($rendered.Contains('Name?') -and $rendered.Contains('For the header.') -and $rendered.Contains('[ESC]')) 'Title, description and keyboard hints render'
    $answer = Read-InteractiveText -Title 'Name?' -Description 'Context' -KeyReader (New-TextReader @((New-TextKey -Char 'A'), (New-TextKey -Key Escape)))
    Assert-Text ($null -eq $answer) 'Escape discards unsubmitted text and cancels'
    $answer = Read-InteractiveText -Title 'Name?' -Description 'Context' -KeyReader (New-TextReader @())
    Assert-Text ($null -eq $answer) 'Exhausted injected input cancels'
    $keys = @((New-TextKey -Key Tab -Char ([char]9)), (New-TextKey -Char ([char]0x03A9)), (New-TextKey -Key Enter))
    $answer = Read-InteractiveText -Title 'Unicode?' -Description 'Context' -KeyReader (New-TextReader $keys)
    Assert-Text ($answer -ceq [string][char]0x03A9) 'Unicode characters survive and control characters are ignored'
    $caught = $false
    try { Read-InteractiveText -Title 'Name?' -Description 'Context' -KeyReader { throw 'Synthetic key failure' } } catch { $caught = $_.Exception.Message -like '*Synthetic key failure*' }
    Assert-Text $caught 'Key reader exceptions propagate for tool error handling'
    $available = Test-InteractiveConsole
    Assert-Text ($available -is [bool]) 'Console availability is a Boolean'
    if ([Console]::IsInputRedirected) { Assert-Text (-not $available) 'Redirected input is unavailable without waiting for keys' }
    Write-Host "Passed $checks interactive text checks. Synthetic input only."
}
finally {
    if ($module) { Remove-Module $module -Force }
}
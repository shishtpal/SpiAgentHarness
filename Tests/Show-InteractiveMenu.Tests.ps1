#requires -Version 7.0
# Run with: pwsh -NoProfile -File ./Tests/Show-InteractiveMenu.Tests.ps1
$ErrorActionPreference = 'Stop'
# Test dependencies must never auto-load a user-installed legacy module.
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$repo = Split-Path $PSScriptRoot -Parent
$checks = 0
$module = $null

function Assert-Menu {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}

function New-Key {
    param(
        [char]$Char = [char]0,
        [System.ConsoleKey]$Key = [System.ConsoleKey]::Select,
        [bool]$Shift = $false,
        [bool]$Alt = $false,
        [bool]$Control = $false
    )
    [System.ConsoleKeyInfo]::new($Char, $Key, $Shift, $Alt, $Control)
}

function New-KeyReader {
    param([System.ConsoleKeyInfo[]]$Keys)
    $queue = [System.Collections.Generic.Queue[System.ConsoleKeyInfo]]::new()
    foreach ($k in $Keys) { $queue.Enqueue($k) }
    return {
        if ($queue.Count -gt 0) { $queue.Dequeue() } else { $null }
    }.GetNewClosure()
}

try {
    # 1. Parse check
    $targetPath = Join-Path $repo 'Private/Console/Show-InteractiveMenu.ps1'
    $tokens = $null; $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($targetPath, [ref]$tokens, [ref]$parseErrors)
    Assert-Menu ($parseErrors.Count -eq 0) "Parse Private/Console/Show-InteractiveMenu.ps1"

    # 2. Isolated module import (no Initialize.ps1)
    $module = New-Module -Name SpiShowInteractiveMenuTests -ScriptBlock {
        param($root)
        . (Join-Path $root 'Private/Console/Show-InteractiveMenu.ps1')
        Export-ModuleMember -Function Show-InteractiveMenu
    } -ArgumentList $repo
    Import-Module $module

    # Test: Empty options returns null
    $emptyResult = Show-InteractiveMenu -Options @()
    Assert-Menu ($null -eq $emptyResult) "Empty options array returns null"

    # Test: Single-select default choice (Enter on first item)
    $keys = @(New-Key -Key Enter -Char ([char]13))
    $choice = Show-InteractiveMenu -Options @('Apple', 'Banana', 'Cherry') -KeyReader (New-KeyReader $keys)
    Assert-Menu ($choice -eq 'Apple') "Single-select confirms first item by default"

    # Test: Single-select navigation with DownArrow
    $keys = @(
        (New-Key -Key DownArrow),
        (New-Key -Key DownArrow),
        (New-Key -Key Enter -Char ([char]13))
    )
    $choice = Show-InteractiveMenu -Options @('Apple', 'Banana', 'Cherry') -KeyReader (New-KeyReader $keys)
    Assert-Menu ($choice -eq 'Cherry') "Single-select navigates down to Cherry"

    # Test: Single-select navigation with UpArrow clamp
    $keys = @(
        (New-Key -Key DownArrow),
        (New-Key -Key UpArrow),
        (New-Key -Key UpArrow), # Clamped at 0
        (New-Key -Key Enter -Char ([char]13))
    )
    $choice = Show-InteractiveMenu -Options @('Apple', 'Banana', 'Cherry') -KeyReader (New-KeyReader $keys)
    Assert-Menu ($choice -eq 'Apple') "UpArrow navigates up and clamps at index 0"

    # Test: Escape cancels menu returning null
    $keys = @(New-Key -Key Escape -Char ([char]27))
    $choice = Show-InteractiveMenu -Options @('Apple', 'Banana') -KeyReader (New-KeyReader $keys)
    Assert-Menu ($null -eq $choice) "Escape cancels menu and returns null"

    # Test: Live filtering with typing characters
    # Options: Apple, Banana, Blackberry, Blueberry
    # Type 'b', 'l', 'u' -> matches Blueberry
    $keys = @(
        (New-Key -Key B -Char 'b'),
        (New-Key -Key L -Char 'l'),
        (New-Key -Key U -Char 'u'),
        (New-Key -Key Enter -Char ([char]13))
    )
    $choice = Show-InteractiveMenu -Options @('Apple', 'Banana', 'Blackberry', 'Blueberry') -Filter -KeyReader (New-KeyReader $keys)
    Assert-Menu ($choice -eq 'Blueberry') "Typing 'blu' filters list and selects Blueberry"

    # Test: Multi-token filtering (space separated)
    # Options: "1. [google] gemini-2.0-flash", "2. [google] gemini-1.5-pro", "3. [meta] llama-3"
    # Type 'g', 'e', 'm', ' ', 'p', 'r', 'o' -> matches "gemini-1.5-pro"
    $keys = @(
        (New-Key -Key G -Char 'g'),
        (New-Key -Key E -Char 'e'),
        (New-Key -Key M -Char 'm'),
        (New-Key -Key Spacebar -Char ' '),
        (New-Key -Key P -Char 'p'),
        (New-Key -Key R -Char 'r'),
        (New-Key -Key O -Char 'o'),
        (New-Key -Key Enter -Char ([char]13))
    )
    $options = @(
        '1. [google] gemini-2.0-flash',
        '2. [google] gemini-1.5-pro',
        '3. [meta] llama-3'
    )
    $choice = Show-InteractiveMenu -Options $options -Filter -KeyReader (New-KeyReader $keys)
    Assert-Menu ($choice -eq '2. [google] gemini-1.5-pro') "Multi-token search 'gem pro' matches gemini-1.5-pro"

    # Test: Backspace in filter
    # Type 'x', 'y', Backspace, 'b', 'a' -> matches Banana
    $keys = @(
        (New-Key -Key X -Char 'x'),
        (New-Key -Key Y -Char 'y'),
        (New-Key -Key Backspace -Char ([char]8)),
        (New-Key -Key Backspace -Char ([char]8)),
        (New-Key -Key B -Char 'b'),
        (New-Key -Key A -Char 'a'),
        (New-Key -Key Enter -Char ([char]13))
    )
    $choice = Show-InteractiveMenu -Options @('Apple', 'Banana', 'Cherry') -Filter -KeyReader (New-KeyReader $keys)
    Assert-Menu ($choice -eq 'Banana') "Backspace erases filter characters accurately"

    # Test: Escape clears filter first, then cancels on second Escape
    $keys = @(
        (New-Key -Key Z -Char 'z'),
        (New-Key -Key Escape -Char ([char]27)), # Clears 'z'
        (New-Key -Key DownArrow),               # Selects second item in restored list
        (New-Key -Key Enter -Char ([char]13))
    )
    $choice = Show-InteractiveMenu -Options @('First', 'Second') -Filter -KeyReader (New-KeyReader $keys)
    Assert-Menu ($choice -eq 'Second') "First Escape clears filter text while keeping menu open"

    # Test: Second Escape exits
    $keys = @(
        (New-Key -Key Z -Char 'z'),
        (New-Key -Key Escape -Char ([char]27)), # Clears 'z'
        (New-Key -Key Escape -Char ([char]27))  # Cancels menu
    )
    $choice = Show-InteractiveMenu -Options @('First', 'Second') -Filter -KeyReader (New-KeyReader $keys)
    Assert-Menu ($null -eq $choice) "Second Escape cancels menu when filter is clear"

    # Test: Filter with zero matches does not crash on Enter; Backspace recovers
    $keys = @(
        (New-Key -Key Z -Char 'z'),
        (New-Key -Key Z -Char 'z'),
        (New-Key -Key Enter -Char ([char]13)),  # No matches, ignored
        (New-Key -Key Backspace -Char ([char]8)),
        (New-Key -Key Backspace -Char ([char]8)),
        (New-Key -Key Enter -Char ([char]13))   # All restored, selects first
    )
    $choice = Show-InteractiveMenu -Options @('Alpha', 'Beta') -Filter -KeyReader (New-KeyReader $keys)
    Assert-Menu ($choice -eq 'Alpha') "Zero match filter ignores Enter and recovers upon Backspace"

    # Test: MultiSelect with filtering and selection order persistence
    # 1. Type 'c' -> matches Cherry
    # 2. Select Cherry with Spacebar
    # 3. Clear filter with Escape
    # 4. Type 'a' -> matches Apple
    # 5. Select Apple with Spacebar
    # 6. Enter -> returns @('Cherry', 'Apple') in checked order!
    $keys = @(
        (New-Key -Key C -Char 'c'),
        (New-Key -Key Spacebar -Char ' '),
        (New-Key -Key Escape -Char ([char]27)),
        (New-Key -Key A -Char 'a'),
        (New-Key -Key Spacebar -Char ' '),
        (New-Key -Key Enter -Char ([char]13))
    )
    $multiChoice = @(Show-InteractiveMenu -Options @('Apple', 'Banana', 'Cherry') -MultiSelect -Filter -KeyReader (New-KeyReader $keys))
    Assert-Menu ($multiChoice.Count -eq 2) "MultiSelect returns 2 items"
    Assert-Menu ($multiChoice[0] -eq 'Cherry' -and $multiChoice[1] -eq 'Apple') "MultiSelect retains cross-filter selections in exact order checked"

    # Test: MultiSelect uncheck toggles selection off
    $keys = @(
        (New-Key -Key Spacebar -Char ' '), # Select Apple
        (New-Key -Key Spacebar -Char ' '), # Deselect Apple
        (New-Key -Key DownArrow),          # Move to Banana
        (New-Key -Key Spacebar -Char ' '), # Select Banana
        (New-Key -Key Enter -Char ([char]13))
    )
    $multiChoice2 = @(Show-InteractiveMenu -Options @('Apple', 'Banana') -MultiSelect -KeyReader (New-KeyReader $keys))
    Assert-Menu ($multiChoice2.Count -eq 1 -and $multiChoice2[0] -eq 'Banana') "MultiSelect spacebar toggles checked state off and on"

    # Test: MultiSelect Tab key also toggles selection
    $keys = @(
        (New-Key -Key Tab -Char ([char]9)), # Select First
        (New-Key -Key Enter -Char ([char]13))
    )
    $multiChoiceTab = @(Show-InteractiveMenu -Options @('First', 'Second') -MultiSelect -KeyReader (New-KeyReader $keys))
    Assert-Menu ($multiChoiceTab.Count -eq 1 -and $multiChoiceTab[0] -eq 'First') "MultiSelect Tab key toggles selection"

    # Test: MultiSelect fallback to highlighted item if nothing checked
    $keys = @(
        (New-Key -Key DownArrow),
        (New-Key -Key Enter -Char ([char]13))
    )
    $multiFallback = @(Show-InteractiveMenu -Options @('First', 'Second') -MultiSelect -KeyReader (New-KeyReader $keys))
    Assert-Menu ($multiFallback.Count -eq 1 -and $multiFallback[0] -eq 'Second') "MultiSelect returns highlighted item when none checked"

    # Test: Explicit -Filter:$false disables typing
    $keys = @(
        (New-Key -Key B -Char 'b'),            # Ignored when Filter is explicitly $false
        (New-Key -Key Enter -Char ([char]13))  # Selects Apple (index 0)
    )
    $noFilterChoice = Show-InteractiveMenu -Options @('Apple', 'Banana') -Filter:$false -KeyReader (New-KeyReader $keys)
    Assert-Menu ($noFilterChoice -eq 'Apple') "Explicit -Filter:`$false disables character typing"

    # Test: Home and End keys
    $keys = @(
        (New-Key -Key End),
        (New-Key -Key Enter -Char ([char]13))
    )
    $endChoice = Show-InteractiveMenu -Options @('One', 'Two', 'Three') -KeyReader (New-KeyReader $keys)
    Assert-Menu ($endChoice -eq 'Three') "End key moves to last option"

    $keys = @(
        (New-Key -Key End),
        (New-Key -Key Home),
        (New-Key -Key Enter -Char ([char]13))
    )
    $homeChoice = Show-InteractiveMenu -Options @('One', 'Two', 'Three') -KeyReader (New-KeyReader $keys)
    Assert-Menu ($homeChoice -eq 'One') "Home key moves to first option"

    Write-Host "Passed $checks interactive menu checks."
}
finally {
    if ($module) { Remove-Module $module -Force }
}
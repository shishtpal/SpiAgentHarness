function Show-InteractiveMenu {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Options,
        [string]$Title = "Select an option",
        [switch]$MultiSelect,
        [switch]$Filter,
        [scriptblock]$KeyReader,
        [string]$Description,
        [string[]]$OptionDescriptions
    )

    if (-not $Options -or $Options.Count -eq 0) {
        return $null
    }
    if ($OptionDescriptions -and $OptionDescriptions.Count -ne $Options.Count) {
        throw 'OptionDescriptions must have one entry per option.'
    }

    $selectedIndex = 0
    $scrollOffset = 0
    $filterText = ""
    $allowFilter = $true
    if ($PSBoundParameters.ContainsKey('Filter') -and -not $Filter) {
        $allowFilter = $false
    }

    $selections = @{}
    # Tracks the order in which items were checked, so multi-select results are
    # returned in the exact order the user selected them.
    $selectionOrder = [System.Collections.Generic.List[int]]::new()
    if ($MultiSelect) {
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $selections[$i] = $false
        }
    }

    $readKey = if ($KeyReader) { $KeyReader } else { { [Console]::ReadKey($true) } }

    $cursorOriginal = $null
    try {
        $cursorOriginal = [Console]::CursorVisible
        [Console]::CursorVisible = $false
    }
    catch {}

    try {
        while ($true) {
            # Compute filtered indices
            $filteredIndices = if ([string]::IsNullOrWhiteSpace($filterText)) {
                @(0..($Options.Count - 1))
            }
            else {
                $tokens = $filterText.Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
                @(for ($i = 0; $i -lt $Options.Count; $i++) {
                    $opt = $Options[$i]
                    $matched = $true
                    foreach ($token in $tokens) {
                        if ($opt.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                            $matched = $false
                            break
                        }
                    }
                    if ($matched) { $i }
                })
            }

            # Clamp selection and scroll offsets within filtered bounds
            if ($filteredIndices.Count -eq 0) {
                $selectedIndex = 0
                $scrollOffset = 0
            }
            else {
                if ($selectedIndex -ge $filteredIndices.Count) {
                    $selectedIndex = [Math]::Max(0, $filteredIndices.Count - 1)
                }
                if ($selectedIndex -lt 0) {
                    $selectedIndex = 0
                }
            }

            $consoleHeight = try { [Console]::WindowHeight } catch { 0 }
            $pageSize = if ($consoleHeight -gt 12) { [Math]::Max(5, $consoleHeight - 8) } else { 20 }
            if ($Description -or $OptionDescriptions) {
                $pageSize = [Math]::Max(1, $pageSize - 5)
            }

            try { Clear-Host } catch {}
            Write-Host $Title -ForegroundColor Cyan
            if ($Description) { Write-Host $Description }

            # Action hints
            $helpParts = [System.Collections.Generic.List[string]]::new()
            $helpParts.Add("[UP/DOWN] Navigate")
            if ($MultiSelect) {
                $helpParts.Add("[SPACE] Select")
            }
            if ($allowFilter -and ($Filter -or $filterText.Length -gt 0)) {
                $helpParts.Add("[TYPE] Filter")
            }
            $helpParts.Add("[ENTER] Confirm")
            if ($filterText.Length -gt 0) {
                $helpParts.Add("[BACKSPACE] Erase")
                $helpParts.Add("[ESC] Clear")
            }
            else {
                $helpParts.Add("[ESC] Cancel")
            }
            Write-Host (" " + ($helpParts -join "  ") + "`n") -ForegroundColor DarkGray

            # Filter prompt line
            $showFilterPrompt = $allowFilter -and ($Filter -or $filterText.Length -gt 0)
            if ($showFilterPrompt) {
                Write-Host " Filter: " -NoNewline -ForegroundColor DarkCyan
                Write-Host $filterText -NoNewline -ForegroundColor Yellow
                Write-Host "_ " -NoNewline -ForegroundColor DarkGray
                Write-Host "($($filteredIndices.Count)/$($Options.Count))`n" -ForegroundColor DarkGray
            }

            if ($filteredIndices.Count -eq 0) {
                Write-Host "   (No matching options)`n" -ForegroundColor DarkGray
            }
            else {
                if ($selectedIndex -lt $scrollOffset) {
                    $scrollOffset = $selectedIndex
                }
                elseif ($selectedIndex -ge ($scrollOffset + $pageSize)) {
                    $scrollOffset = $selectedIndex - $pageSize + 1
                }
                $maxOffset = [Math]::Max(0, $filteredIndices.Count - $pageSize)
                if ($scrollOffset -gt $maxOffset) {
                    $scrollOffset = $maxOffset
                }

                $visibleEnd = [Math]::Min($filteredIndices.Count - 1, $scrollOffset + $pageSize - 1)

                for ($i = $scrollOffset; $i -le $visibleEnd; $i++) {
                    $optIndex = $filteredIndices[$i]
                    $prefix = ""
                    if ($MultiSelect) {
                        if ($selections[$optIndex]) { $prefix = "[x] " } else { $prefix = "[ ] " }
                    }

                    if ($i -eq $selectedIndex) {
                        Write-Host " > $prefix$($Options[$optIndex])" -ForegroundColor Black -BackgroundColor White
                    }
                    else {
                        Write-Host "   $prefix$($Options[$optIndex])"
                    }
                }

                if ($filteredIndices.Count -gt $pageSize) {
                    Write-Host "`n   (Showing $($scrollOffset + 1)-$($visibleEnd + 1) of $($filteredIndices.Count))" -ForegroundColor DarkGray
                }
                if ($OptionDescriptions) {
                    $optionDescription = $OptionDescriptions[$filteredIndices[$selectedIndex]]
                    if ($optionDescription) { Write-Host "`n   $optionDescription" -ForegroundColor DarkGray }
                }
            }

            $key = & $readKey
            if ($null -eq $key) {
                return $null
            }

            switch ($key.Key) {
                'UpArrow' {
                    if ($selectedIndex -gt 0) {
                        $selectedIndex--
                    }
                }
                'DownArrow' {
                    if ($selectedIndex -lt ($filteredIndices.Count - 1)) {
                        $selectedIndex++
                    }
                }
                'Home' {
                    $selectedIndex = 0
                }
                'End' {
                    if ($filteredIndices.Count -gt 0) {
                        $selectedIndex = $filteredIndices.Count - 1
                    }
                }
                'PageUp' {
                    $selectedIndex = [Math]::Max(0, $selectedIndex - $pageSize)
                }
                'PageDown' {
                    if ($filteredIndices.Count -gt 0) {
                        $selectedIndex = [Math]::Min($filteredIndices.Count - 1, $selectedIndex + $pageSize)
                    }
                }
                'Tab' {
                    if ($MultiSelect -and $filteredIndices.Count -gt 0) {
                        $optIndex = $filteredIndices[$selectedIndex]
                        if (-not $selections[$optIndex]) {
                            $selections[$optIndex] = $true
                            $selectionOrder.Add($optIndex)
                        }
                        else {
                            $selections[$optIndex] = $false
                            [void]$selectionOrder.Remove($optIndex)
                        }
                    }
                }
                'Spacebar' {
                    if ($MultiSelect) {
                        if ($filteredIndices.Count -gt 0) {
                            $optIndex = $filteredIndices[$selectedIndex]
                            if (-not $selections[$optIndex]) {
                                $selections[$optIndex] = $true
                                $selectionOrder.Add($optIndex)
                            }
                            else {
                                $selections[$optIndex] = $false
                                [void]$selectionOrder.Remove($optIndex)
                            }
                        }
                    }
                    elseif ($allowFilter) {
                        $filterText += ' '
                        $selectedIndex = 0
                    }
                }
                'Enter' {
                    if ($MultiSelect) {
                        if ($selectionOrder.Count -gt 0) {
                            # Return in the order the user checked the items.
                            $result = foreach ($idx in $selectionOrder) { $Options[$idx] }
                            return $result
                        }
                        elseif ($filteredIndices.Count -gt 0) {
                            # If nothing checked, return current highlighted item
                            return @($Options[$filteredIndices[$selectedIndex]])
                        }
                        else {
                            return @()
                        }
                    }
                    else {
                        if ($filteredIndices.Count -gt 0) {
                            return $Options[$filteredIndices[$selectedIndex]]
                        }
                    }
                }
                'Escape' {
                    if ($filterText.Length -gt 0) {
                        $filterText = ""
                        $selectedIndex = 0
                    }
                    else {
                        return $null
                    }
                }
                'Backspace' {
                    if ($allowFilter -and $filterText.Length -gt 0) {
                        $filterText = $filterText.Substring(0, $filterText.Length - 1)
                        $selectedIndex = 0
                    }
                }
                default {
                    if ($allowFilter -and $key.KeyChar -ne [char]0 -and -not [char]::IsControl($key.KeyChar)) {
                        $filterText += $key.KeyChar
                        $selectedIndex = 0
                    }
                }
            }
        }
    }
    finally {
        try {
            if ($null -ne $cursorOriginal) {
                [Console]::CursorVisible = $cursorOriginal
            }
            else {
                [Console]::CursorVisible = $true
            }
        }
        catch {}
    }
}
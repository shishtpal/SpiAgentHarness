function Update-AgentHarnessSkills {
    param([hashtable]$State)

    $ErrorActionPreference = 'Stop'
    if ($State.Disabled) { return }
    $found = [Collections.Generic.List[object]]::new()
    foreach ($root in $State.Roots) {
        if (-not (Test-Path -LiteralPath $root.Path -PathType Container)) {
            if ($root.Required) { throw "Configured skill directory is missing: $($root.Path)" }
            continue
        }
        try {
            $directory = Resolve-AgentHarnessSkillPath -Root $root.Path
            $children = @(Get-ChildItem -LiteralPath $directory.FullName -Directory -Force -ErrorAction Stop | Sort-Object Name)
            if ($children.Count -gt 256) { Write-Warning "Only the first 256 skill folders are scanned in $($root.Path)." }
            foreach ($child in ($children | Select-Object -First 256)) {
                # Do not probe through a link, even to check for SKILL.md.
                try {
                    $null = Resolve-AgentHarnessSkillPath -Root $root.Path -Path $child.Name
                    if (-not (Test-Path -LiteralPath (Join-Path $child.FullName 'SKILL.md') -PathType Leaf)) { continue }
                    $skill = Read-AgentHarnessSkill -Directory $child.FullName
                    $found.Add(@{ Skill = $skill; Priority = $root.Priority })
                }
                catch { Write-Warning "Skipping invalid skill folder '$($child.FullName)': $($_.Exception.Message)" }
            }
        }
        catch {
            if ($root.Required) { throw }
            Write-Warning "Skipping skill root '$($root.Path)': $($_.Exception.Message)"
        }
    }
    $catalog = [ordered]@{}
    $catalogChars = 2
    foreach ($group in ($found | Group-Object { $_.Skill.Name } | Sort-Object Name)) {
        $priority = ($group.Group | Measure-Object Priority -Maximum).Maximum
        $winners = @($group.Group | Where-Object Priority -eq $priority)
        if ($winners.Count -ne 1) {
            Write-Warning "Ambiguous skill '$($group.Name)' at the same priority; excluded until the duplicate is removed."
            continue
        }
        if ($catalog.Count -ge 256) { Write-Warning 'Skill catalog limit of 256 reached; remaining names are excluded.'; break }
        $skill = $winners[0].Skill
        # Keep metadata only. Bodies are reread and validated when actually loaded.
        $entry = [pscustomobject]@{ Name = $skill.Name; Description = $skill.Description; Directory = $skill.Directory }
        $entryChars = (ConvertTo-Json -InputObject $entry -Compress).Length + 1
        if ($catalogChars + $entryChars -gt 65536) { Write-Warning "Skill '$($skill.Name)' excluded because the catalog exceeds 65536 characters."; continue }
        $catalog[$skill.Name] = $entry
        $catalogChars += $entryChars
    }
    $explicitParts = [Collections.Generic.List[string]]::new()
    foreach ($name in $State.Explicit) {
        if (-not $catalog.Contains($name)) { throw "Requested skill '$name' is unavailable or invalid." }
        $skill = Read-AgentHarnessSkill -Directory $catalog[$name].Directory
        $explicitParts.Add("Skill '$name' from $($skill.Directory):`n$($skill.Body)")
    }
    $explicitText = $explicitParts -join "`n`n"
    if ($explicitText.Length -gt 65536) { throw 'Explicit skill instructions exceed 65536 characters; load them in pages instead.' }
    # Commit a complete refresh only after explicit selections have validated.
    $State.Catalog = $catalog
    $State.ExplicitText = $explicitText
    $State.Loaded = @{}
}
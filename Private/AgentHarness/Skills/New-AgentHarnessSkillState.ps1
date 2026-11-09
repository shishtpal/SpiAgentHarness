function New-AgentHarnessSkillState {
    param([string]$WorkingDirectory, [string[]]$SkillPath, [string[]]$Skill, [switch]$Disabled,
        [Alias('UserSkillPath')][AllowEmptyString()][string]$GlobalSkillPath)

    $ErrorActionPreference = 'Stop'
    foreach ($name in $Skill) {
        if ($name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $name.Length -gt 64) { throw 'Skill selections must be valid lowercase skill names.' }
    }
    if ($Disabled -and $Skill.Count) { throw '-Skill cannot be combined with -NoSkills or -NoBuiltinTools.' }
    $state = @{
        Disabled = [bool]$Disabled; Roots = @(); Catalog = [ordered]@{}
        Explicit = @($Skill | Select-Object -Unique); Loaded = @{}; ExplicitText = ''
    }
    if ($Disabled) { return $state }
    if (-not $PSBoundParameters.ContainsKey('GlobalSkillPath')) { $GlobalSkillPath = Get-AgentHarnessDefaultSkillPath }
    $roots = [Collections.Generic.List[object]]::new()
    if ($GlobalSkillPath) { $roots.Add(@{ Path = [IO.Path]::GetFullPath($GlobalSkillPath, $WorkingDirectory); Priority = 0; Required = $false }) }
    $roots.Add(@{ Path = [IO.Path]::GetFullPath('.agents/skills', $WorkingDirectory); Priority = 1; Required = $false })
    foreach ($path in $SkillPath) {
        if ([string]::IsNullOrWhiteSpace($path)) { throw 'SkillPath entries cannot be blank.' }
        $roots.Add(@{ Path = [IO.Path]::GetFullPath($path, $WorkingDirectory); Priority = 2; Required = $true })
    }
    # A repeated root is scanned once, at its highest configured priority.
    $state.Roots = @($roots | Sort-Object Priority -Descending | Group-Object Path -CaseSensitive:(-not $IsWindows) | ForEach-Object { $_.Group[0] })
    Update-AgentHarnessSkills -State $state
    $state
}
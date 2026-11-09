function Invoke-AgentHarnessSkillTool {
    param([string]$Operation, [hashtable]$Arguments, [hashtable]$Context)

    $ErrorActionPreference = 'Stop'
    $state = $Context.SkillState
    if (-not $state -or $state.Disabled) { throw 'Folder skills are disabled for this invocation.' }
    $allowed = switch ($Operation) {
        'list_skills' { @('offset', 'max_chars') }
        'refresh_skills' { @('offset', 'max_chars') }
        'load_skill' { @('name', 'offset', 'max_chars') }
        'read_skill_resource' { @('name', 'path', 'offset', 'max_chars') }
        default { throw 'Unknown skill operation.' }
    }
    foreach ($key in $Arguments.Keys) { if ($key -cnotin $allowed) { throw "Unknown skill argument: $key" } }
    foreach ($key in 'offset', 'max_chars') {
        if ($Arguments.ContainsKey($key) -and ($Arguments[$key] -isnot [int] -and $Arguments[$key] -isnot [long])) { throw "$key must be an integer." }
    }
    $offset = if ($Arguments.ContainsKey('offset')) { $Arguments.offset } else { 0 }
    $max = if ($Arguments.ContainsKey('max_chars')) { $Arguments.max_chars } else { 4000 }
    if ($offset -lt 0 -or $offset -gt 1MB -or $max -lt 1 -or $max -gt 16000) { throw 'offset must be 0..1048576 and max_chars 1..16000.' }
    if ($Operation -eq 'refresh_skills') {
        if ($offset -ne 0) { throw 'Use list_skills for subsequent catalog pages after a refresh.' }
        Update-AgentHarnessSkills -State $state
        $Context.SkillPromptDirty = $true
    }
    if ($Operation -in 'list_skills', 'refresh_skills') {
        $text = ConvertTo-Json -InputObject @($state.Catalog.Values | Select-Object Name, Description, Directory) -Depth 4 -Compress
    }
    else {
        if ($Arguments.name -isnot [string] -or -not $state.Catalog.Contains($Arguments.name)) { throw 'Unknown or missing skill name; use list_skills.' }
        $entry = $state.Catalog[$Arguments.name]
        if ($entry.Name -cne $Arguments.name) { throw 'Skill names are case-sensitive.' }
        # Revalidate metadata and paths on every read, including after folder edits.
        $skill = Read-AgentHarnessSkill -Directory $entry.Directory
        if ($skill.Name -cne $entry.Name) { throw 'Skill name changed; refresh the catalog before loading it.' }
        if ($Operation -eq 'load_skill') {
            $text = $skill.Body
        }
        else {
            if ($Arguments.path -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments.path) -or [IO.Path]::IsPathRooted($Arguments.path)) {
                throw 'path must be a nonblank path relative to the skill directory.'
            }
            $text = Read-AgentHarnessSkillText -Root $entry.Directory -Path $Arguments.path
        }
    }
    if ($offset -gt $text.Length) { throw 'offset is past the end; restart at offset 0 if the file changed.' }
    $count = [int][Math]::Min($max, $text.Length - $offset)
    $next = if ($offset + $count -lt $text.Length) { [string]($offset + $count) } else { 'end' }
    if ($Operation -eq 'load_skill') { $state.Loaded[$Arguments.name] = $true }
    "offset=$offset; next_offset=$next; total_chars=$($text.Length)`n" + $text.Substring([int]$offset, $count)
}
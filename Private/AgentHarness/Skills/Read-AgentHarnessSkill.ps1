function Read-AgentHarnessSkill {
    param([string]$Directory)

    $ErrorActionPreference = 'Stop'
    $text = Read-AgentHarnessSkillText -Root $Directory -Path 'SKILL.md'
    $match = [regex]::Match($text, '\A---\r?\n(?<header>[\s\S]*?)\r?\n---(?:\r?\n|\z)')
    if (-not $match.Success) { throw 'SKILL.md requires delimited YAML frontmatter.' }
    $lines = $match.Groups['header'].Value -split '\r?\n'
    $values = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') { continue }
        if ($line -match '^\s') { continue } # Unused nested metadata is not evaluated.
        if ($line -notmatch '^(?<key>[a-zA-Z][a-zA-Z0-9_-]*):(?:\s+(?<value>.*))?$') { throw 'Unsupported YAML frontmatter syntax.' }
        $key = $Matches.key
        $value = ([string]$Matches.value).Trim()
        if ($key -cnotin 'name', 'description') { continue }
        if ($values.ContainsKey($key)) { throw "Duplicate skill field: $key" }
        if ($value -match '^[>|]-?$') {
            $fold = $value.StartsWith('>')
            $block = [Collections.Generic.List[string]]::new()
            while ($i + 1 -lt $lines.Count -and ($lines[$i + 1] -match '^  ' -or [string]::IsNullOrWhiteSpace($lines[$i + 1]))) {
                $i++
                $block.Add($lines[$i].Trim())
            }
            $value = $block -join $(if ($fold) { ' ' } else { "`n" })
        }
        elseif ($value.StartsWith('"')) {
            try {
                $value = ConvertFrom-Json -InputObject $value -NoEnumerate -ErrorAction Stop
                if ($value -isnot [string]) { throw 'Not a string.' }
            }
            catch { throw 'Double-quoted skill fields must use JSON-compatible string escapes.' }
        }
        elseif ($value.StartsWith("'")) {
            if ($value -notmatch "^'(?:[^']|'')*'$") { throw 'Invalid single-quoted skill field.' }
            $value = $value.Substring(1, $value.Length - 2).Replace("''", "'")
        }
        else {
            $value = $value -replace '\s+#.*$', ''
            if ($value -match '^[\[\{!&*|>]' -or $value -match ':\s' -or $value -in 'null', '~') {
                throw 'Use a quoted string for this skill field.'
            }
        }
        $values[$key] = $value.Trim()
    }
    if ($values.name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $values.name.Length -gt 64) {
        throw 'Skill name must be 1..64 lowercase letters, digits and single hyphens.'
    }
    if ([string]::IsNullOrWhiteSpace($values.description) -or $values.description.Length -gt 1024) {
        throw 'Skill description must contain 1..1024 characters.'
    }
    if ([string]::IsNullOrWhiteSpace($text.Substring($match.Length))) { throw 'Skill instructions cannot be blank.' }
    [pscustomobject]@{
        Name = $values.name; Description = ($values.description -replace '\s+', ' ')
        Directory = [IO.Path]::GetFullPath($Directory); Body = $text.Substring($match.Length)
    }
}
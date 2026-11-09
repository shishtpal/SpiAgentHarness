function Read-AgentHarnessSkillText {
    param([string]$Root, [string]$Path)

    $ErrorActionPreference = 'Stop'
    $item = Resolve-AgentHarnessSkillPath -Root $Root -Path $Path
    if ($item -isnot [IO.FileInfo]) { throw 'A skill read requires an existing text file.' }
    if ($item.Length -gt 1MB) { throw 'Skill files must be at most 1 MiB.' }
    # Reject invalid UTF-8 and binary data instead of silently replacing bytes.
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -gt 1MB) { throw 'Skill files must be at most 1 MiB.' }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF) }
    catch { throw 'Skill files must contain valid UTF-8 text.' }
    if ($text.Contains([char]0)) { throw 'Skill files must contain UTF-8 text without NUL characters.' }
    $text
}
function Get-AgentHarnessDefaultSkillPath {
    param([string]$ModuleRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')))

    $ErrorActionPreference = 'Stop'
    $candidate = [IO.Path]::GetFullPath($ModuleRoot)
    $comparison = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $seen = [Collections.Generic.HashSet[string]]::new($comparison)
    for ($hop = 0; $hop -lt 32; $hop++) {
        if (-not $seen.Add($candidate)) { throw 'Module directory links contain a cycle.' }
        $current = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if ($current -isnot [IO.DirectoryInfo]) { throw 'The module root must be an existing directory.' }
        $redirected = $false
        while ($null -ne $current) {
            if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                # PowerShell's Target property works on the minimum supported 7.0;
                # FileSystemInfo.ResolveLinkTarget requires a newer .NET runtime.
                $targets = @($current.Target)
                if ($current.LinkType -notin 'Junction', 'SymbolicLink' -or $targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace($targets[0])) {
                    throw 'The module directory contains an unsupported reparse point.'
                }
                $suffix = [IO.Path]::GetRelativePath($current.FullName, $candidate)
                $target = [IO.Path]::GetFullPath([string]$targets[0], $current.Parent.FullName)
                $candidate = [IO.Path]::GetFullPath($suffix, $target)
                $redirected = $true
                break
            }
            $current = $current.Parent
        }
        if (-not $redirected) {
            # Resolve the trusted installation only. The skill root and resources
            # still pass the ordinary checks that reject links and path escapes.
            return [IO.Path]::GetFullPath('.agents/skills', $candidate)
        }
    }
    throw 'The module directory exceeds the limit of 32 link resolutions.'
}
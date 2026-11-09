function Resolve-AgentHarnessSkillPath {
    param([string]$Root, [string]$Path = '.')

    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A nonblank skill path is required.' }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $fullPath = [IO.Path]::GetFullPath($Path, $rootPath)
    $relative = [IO.Path]::GetRelativePath($rootPath, $fullPath)
    if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('../') -or $relative.StartsWith('..\')) {
        throw 'Skill path escapes its configured directory.'
    }
    if ($IsWindows -and $relative.Contains(':')) { throw 'Skill paths cannot use alternate data streams.' }
    if ([IO.Path]::GetFileName($fullPath) -ieq 'Initialize.ps1') { throw 'This sensitive file is excluded from skill reads.' }
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    $current = $item
    while ($null -ne $current) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Skill paths cannot follow symbolic links, junctions or other reparse points.'
        }
        $current = if ($current -is [IO.FileInfo]) { $current.Directory } else { $current.Parent }
    }
    $item
}
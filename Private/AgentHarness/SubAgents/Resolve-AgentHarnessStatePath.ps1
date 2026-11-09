function Resolve-AgentHarnessStatePath {
    param([string]$Root, [string]$Path)

    $full = Resolve-AgentHarnessPath -Root $Root -Path $Path
    # State files are control data. Refuse existing links anywhere in their ancestry.
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Sub-agent state paths cannot contain symbolic links, junctions or reparse points.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
    $full
}
function Format-AgentHarnessEditPreview {
    param([string]$Path, [object[]]$Edits)

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("edit ${Path} (exact replacements, applied in order)")
    foreach ($edit in $Edits) {
        $lines.Add("@@ edit $($edit.Number), line $($edit.Line), column $($edit.Column) @@")
        foreach ($side in 'old_text', 'new_text') {
            $value = [string]$edit.$side
            $prefix = if ($side -eq 'old_text') { '-' } else { '+' }
            foreach ($line in [regex]::Split($value, '\r\n|\r|\n')) { $lines.Add($prefix + $line) }
            # Make newline-only edits and trailing-newline changes visible too.
            $crlf = [regex]::Matches($value, '\r\n').Count
            $lf = [regex]::Matches($value, '(?<!\r)\n').Count
            $cr = [regex]::Matches($value, '\r(?!\n)').Count
            $ends = $value.EndsWith("`n") -or $value.EndsWith("`r")
            $lines.Add("\ ${side}: CRLF=$crlf, LF=$lf, CR=$cr; ends with newline=$ends")
        }
    }
    $lines -join "`n"
}
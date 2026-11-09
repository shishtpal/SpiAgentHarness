function Invoke-AgentHarnessEditFile {
    param([hashtable]$Arguments, [hashtable]$Context)

    $ErrorActionPreference = 'Stop'
    if ($Arguments.path -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments.path)) {
        throw 'edit_file path must be a nonblank string.'
    }
    if ($Arguments.edits -isnot [array] -or $Arguments.edits.Count -lt 1 -or $Arguments.edits.Count -gt 100) {
        throw 'edit_file edits must be an array containing 1 to 100 edits.'
    }
    foreach ($key in $Arguments.Keys) {
        if ($key -cnotin 'path', 'edits') { throw "Unknown edit_file argument: $key" }
    }
    foreach ($edit in $Arguments.edits) {
        if ($edit -isnot [hashtable] -or $edit.old_text -isnot [string] -or $edit.old_text.Length -eq 0 -or $edit.new_text -isnot [string]) {
            throw 'Each edit must be an object with nonempty string old_text and string new_text (which may be empty).'
        }
        foreach ($key in $edit.Keys) {
            if ($key -cnotin 'old_text', 'new_text') { throw "Unknown edit field: $key" }
        }
        if ($edit.new_text -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') {
            throw 'new_text cannot contain control characters other than tab and newlines.'
        }
        if ($edit.old_text.Length -gt 1MB -or $edit.new_text.Length -gt 1MB) {
            throw 'edit_file edit strings cannot exceed 1,048,576 characters.'
        }
    }

    $file = Resolve-AgentHarnessEditPath -Root $Context.Root -Path $Arguments.path
    $original = Read-AgentHarnessEditFile -Path $file
    $candidate = $original.Text
    $previewEdits = [Collections.Generic.List[object]]::new()
    $number = 0
    foreach ($edit in $Arguments.edits) {
        $number++
        $index = $candidate.IndexOf($edit.old_text, [StringComparison]::Ordinal)
        if ($index -lt 0) { throw "Edit ${number}: old_text was not found. Read the file again and use exact text, including line endings." }
        # Count overlapping matches as ambiguous as well (e.g. 'aa' within 'aaa').
        if ($candidate.IndexOf($edit.old_text, $index + 1, [StringComparison]::Ordinal) -ge 0) {
            throw "Edit ${number}: old_text matches more than once. Include more surrounding text to make it unique."
        }
        $before = $candidate.Substring(0, $index)
        $breaks = [regex]::Matches($before, '\r\n|\r|\n')
        $lineStart = if ($breaks.Count) { $breaks[$breaks.Count - 1].Index + $breaks[$breaks.Count - 1].Length } else { 0 }
        $previewEdits.Add(@{
            Number = $number; Line = $breaks.Count + 1; Column = $index - $lineStart + 1
            old_text = $edit.old_text; new_text = $edit.new_text
        })
        $candidate = $before + $edit.new_text + $candidate.Substring($index + $edit.old_text.Length)
        if ($original.Encoding.GetByteCount($candidate) + $original.Encoding.GetPreamble().Length -gt 1MB) {
            throw "Edit ${number}: resulting file exceeds the 1 MiB limit."
        }
    }
    if ($candidate.Equals($original.Text, [StringComparison]::Ordinal)) { return "No changes to $($Arguments.path)." }

    $preview = Format-AgentHarnessEditPreview -Path $Arguments.path -Edits $previewEdits.ToArray()
    if (-not (Confirm-AgentHarnessAction $Context $preview)) { return 'ERROR: the user denied this edit.' }

    $temporary = $null
    $temporaryCreated = $false
    try {
        $null = Resolve-AgentHarnessEditPath -Root $Context.Root -Path $Arguments.path
        $current = Read-AgentHarnessEditFile -Path $file
        if ([Convert]::ToBase64String($current.Bytes) -cne [Convert]::ToBase64String($original.Bytes)) {
            throw 'File changed since the edit was prepared. Read it again before editing.'
        }
        $temporary = [IO.Path]::Combine([IO.Path]::GetDirectoryName($file), ('.agentharness-' + [guid]::NewGuid().ToString('N') + '.tmp'))
        # Copy preserves source permissions, including Unix mode on PowerShell 7.0.
        [IO.File]::Copy($file, $temporary, $false)
        $temporaryCreated = $true
        $bytes = [byte[]]($original.Encoding.GetPreamble() + $original.Encoding.GetBytes($candidate))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.SetLength(0)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        # Recheck after staging as well; never fall back to an in-place overwrite.
        $null = Resolve-AgentHarnessEditPath -Root $Context.Root -Path $Arguments.path
        $current = Read-AgentHarnessEditFile -Path $file
        if ([Convert]::ToBase64String($current.Bytes) -cne [Convert]::ToBase64String($original.Bytes)) {
            throw 'File changed since the edit was prepared. Read it again before editing.'
        }
        [IO.File]::Replace($temporary, $file, [NullString]::Value)
    }
    finally {
        if ($temporaryCreated -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    'Applied {0} edit(s) to {1} ({2} bytes).' -f $Arguments.edits.Count, $Arguments.path, $bytes.Length
}
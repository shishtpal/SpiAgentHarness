function Read-DecisionModelJsonFile {
    param([string]$LiteralPath, [string]$Name)

    try {
        $file = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
        if ($file -isnot [IO.FileInfo]) { throw 'Not a filesystem file.' }
        $json = [IO.File]::ReadAllText($file.FullName)
    }
    catch { throw "Cannot read $Name. Supply an existing, readable filesystem file." }
    try {
        if ([string]::IsNullOrWhiteSpace($json)) { throw 'Empty JSON.' }
        $value = ConvertFrom-Json -InputObject $json -AsHashtable -NoEnumerate -ErrorAction Stop
    }
    # Parser errors can quote the file contents. Keep them out of displayed errors.
    catch { throw "$Name must contain valid JSON." }
    # Preserve empty and singleton arrays for the normal request validators.
    return ,$value
}
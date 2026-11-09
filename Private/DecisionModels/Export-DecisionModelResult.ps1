function Export-DecisionModelResult {
    param([object]$Result, [string]$LiteralPath)

    # Summary is derived from Answers, and RawResponse repeats the other fields.
    $data = [ordered]@{
        SavedAt             = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        RequestedModel      = $Result.RequestedModel
        Model               = $Result.Model
        Provider            = $Result.Provider
        ServedBy            = $Result.ServedBy
        Id                  = $Result.Id
        ElapsedMilliseconds = $Result.ElapsedMilliseconds
        Usage               = $Result.Usage
        Answers             = $Result.Answers
    }
    $json = ConvertTo-Json -InputObject $data -Depth 100
    [IO.File]::WriteAllText($LiteralPath, $json, [Text.UTF8Encoding]::new($false))
}
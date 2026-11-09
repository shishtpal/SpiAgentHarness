function Test-DecisionModelNumber {
    param([AllowNull()][object]$Value, [switch]$Probability)

    if ($Value -isnot [byte] -and $Value -isnot [sbyte] -and $Value -isnot [int16] -and
        $Value -isnot [uint16] -and $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64] -and $Value -isnot [single] -and
        $Value -isnot [double] -and $Value -isnot [decimal]) { return $false }
    $number = [double]$Value
    -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and
        (-not $Probability -or ($number -ge 0 -and $number -le 1))
}
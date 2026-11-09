function Assert-AgentHarnessScreenCandidates {
    param([hashtable]$Arguments, [Collections.IDictionary]$Config)

    $snapshot = $Arguments.snapshot
    # ConvertFrom-Json can materialize ISO timestamps as DateTime on supported PowerShell versions.
    if ($snapshot.captured_at -is [DateTime]) {
        if ($snapshot.captured_at.Kind -eq [DateTimeKind]::Unspecified) { throw 'Snapshot captured_at must include a timezone.' }
        $snapshot.captured_at = $snapshot.captured_at.ToString('o')
    }
    elseif ($snapshot.captured_at -is [DateTimeOffset]) { $snapshot.captured_at = $snapshot.captured_at.ToString('o') }
    $captured = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$snapshot.captured_at, [ref]$captured) -or
        $snapshot.captured_at -notmatch '(Z|[+-]\d{2}:\d{2})$') { throw 'Snapshot captured_at must include a timezone.' }
    if ([string]::IsNullOrWhiteSpace($Arguments.goal) -or [string]::IsNullOrWhiteSpace($snapshot.id) -or
        [string]::IsNullOrWhiteSpace($snapshot.source)) { throw 'Goal and snapshot identifiers cannot be blank.' }
    if ($Arguments.candidates.Count -gt $Config.selection.max_candidates) { throw 'Too many screen candidates for the configured limit.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in $Arguments.candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.id) -or -not $ids.Add($candidate.id) -or
            $candidate.id -ceq $Config.selection.abstain_choice_id) { throw 'Candidate IDs must be unique and cannot use the abstain ID.' }
        if ([string]::IsNullOrWhiteSpace($candidate.description) -or
            ($candidate.Contains('locator') -and [string]::IsNullOrWhiteSpace($candidate.locator))) { throw 'Candidate descriptions and locators cannot be blank.' }
        if ($candidate.bounds) {
            $b = $candidate.bounds
            if ($b.x + $b.width -gt $snapshot.width -or $b.y + $b.height -gt $snapshot.height) {
                throw 'Candidate bounds extend beyond the snapshot dimensions.'
            }
        }
    }
}
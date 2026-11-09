function Invoke-AgentHarnessScreenDecision {
    param([hashtable]$Arguments, [hashtable]$Context, [Collections.IDictionary]$Definition)

    $config = $Definition.config
    Assert-AgentHarnessScreenCandidates -Arguments $Arguments -Config $config
    $criteria = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($candidate in $Arguments.candidates) { $criteria.Add($candidate.id, $candidate.description) }
    $none = $config.selection.abstain_choice_id
    $criteria.Add($none, 'No appropriate target, or insufficient evidence to select one.')
    $questions = @{ target = @{ type = 'choice'; instructions = $config.selection.question; criteria = $criteria } }
    $state = @{ goal = $Arguments.goal; snapshot = $Arguments.snapshot; candidates = $Arguments.candidates }
    $attachments = @()
    if ($Arguments.snapshot.screenshot_path) { $attachments = @($Arguments.snapshot.screenshot_path) }
    $result = [ordered]@{
        status = 'abstained'; snapshot_id = $Arguments.snapshot.id; target = $null
        choice_probability = $null; probability_margin = $null; reason_code = 'no_suitable_target'
        provider = $null; model = $null; request_id = $null
        usage = $null; elapsed_milliseconds = 0
        requires_target_revalidation = $true; coordinate_space = $Arguments.snapshot.coordinate_space
        source = $Arguments.snapshot.source; captured_at = $Arguments.snapshot.captured_at
        requires_coordinate_transform = ($Arguments.snapshot.coordinate_space -eq 'screenshot_pixels')
    }
    $captured = [DateTimeOffset]::Parse($Arguments.snapshot.captured_at)
    $age = ([DateTimeOffset]::UtcNow - $captured).TotalSeconds
    if ($age -lt -5) { throw 'Snapshot capture time is in the future.' }
    if ($age -gt $config.snapshot.max_age_sec) {
        $result.status = 'stale_snapshot'; $result.reason_code = 'snapshot_expired'; return $result
    }
    $response = & $Context.DecisionState.Invoke $Definition $state $questions $attachments $Context.Root
    $answer = $response.Answers['target']
    $result.provider = $response.Provider; $result.model = $response.Model; $result.request_id = $response.Id
    $result.usage = $response.Usage; $result.elapsed_milliseconds = $response.ElapsedMilliseconds
    if (([DateTimeOffset]::UtcNow - $captured).TotalSeconds -gt $config.snapshot.max_age_sec) {
        $result.status = 'stale_snapshot'; $result.reason_code = 'snapshot_expired'; return $result
    }
    if ($answer.type -ceq 'refusal') { $result.status = 'refused'; $result.reason_code = 'model_refused'; return $result }
    if ($null -eq $answer.probabilities) { $result.reason_code = 'probabilities_unavailable'; return $result }
    $p = [double]$answer.probabilities[$answer.choice]
    $alternative = 0.0
    foreach ($id in $answer.probabilities.Keys) {
        if ($id -cne $answer.choice) { $alternative = [Math]::Max($alternative, [double]$answer.probabilities[$id]) }
    }
    $result.choice_probability = $p
    $result.probability_margin = $p - $alternative
    if ($answer.choice -ceq $none) { return $result }
    if ($p -lt $config.selection.min_choice_probability -or $result.probability_margin -lt $config.selection.min_probability_margin) {
        $result.reason_code = 'insufficient_probability'; return $result
    }
    $result.target = @($Arguments.candidates | Where-Object { $_.id -ceq $answer.choice })[0]
    $result.status = 'selected'
    $result.reason_code = 'target_selected'
    $result
}
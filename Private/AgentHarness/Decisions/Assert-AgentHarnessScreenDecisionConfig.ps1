function Assert-AgentHarnessScreenDecisionConfig {
    param([Collections.IDictionary]$Config)

    $selection = $Config.selection
    if ($selection.question -isnot [string] -or [string]::IsNullOrWhiteSpace($selection.question) -or
        $selection.abstain_choice_id -isnot [string] -or [string]::IsNullOrWhiteSpace($selection.abstain_choice_id) -or
        -not (Test-DecisionModelNumber $selection.max_candidates) -or $selection.max_candidates -lt 1 -or
        $selection.max_candidates -gt 63 -or $selection.max_candidates % 1 -ne 0 -or
        -not (Test-DecisionModelNumber $selection.min_choice_probability -Probability) -or
        -not (Test-DecisionModelNumber $selection.min_probability_margin -Probability) -or
        $selection.missing_probability_behavior -cne 'abstain') {
        throw 'Invalid screen decision selection policy.'
    }
    if ($Config.execution.perform_click -isnot [bool] -or $Config.execution.perform_click -or
        $Config.snapshot.require_target_revalidation_before_click -isnot [bool] -or -not $Config.snapshot.require_target_revalidation_before_click) {
        throw 'Screen decisions require perform_click=false and target revalidation before execution.'
    }
    if (-not (Test-DecisionModelNumber $Config.snapshot.max_age_sec) -or $Config.snapshot.max_age_sec -lt 1 -or $Config.snapshot.max_age_sec -gt 3600) {
        throw 'Screen snapshot max_age_sec must be between 1 and 3600.'
    }
}
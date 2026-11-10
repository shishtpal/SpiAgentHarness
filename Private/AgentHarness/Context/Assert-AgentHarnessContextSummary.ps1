function Assert-AgentHarnessContextSummary {
    param($Summary)

    if ($Summary -isnot [Collections.IDictionary]) { throw 'Context summary must be a JSON object.' }
    foreach ($field in 'goal', 'constraints', 'decisions', 'completed_work', 'verification', 'unfinished_work', 'next_steps') {
        if ($Summary[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($Summary[$field])) {
            throw 'Context summary requires nonempty goal, constraints, decisions, completed_work, verification, unfinished_work and next_steps strings.'
        }
    }
}
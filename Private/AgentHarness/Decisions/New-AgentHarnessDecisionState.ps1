function New-AgentHarnessDecisionState {
    param([object[]]$Definition, [string[]]$Path, [hashtable]$Handlers, [string]$Root)

    $registry = @{
        screen_target = { param($a, $ctx, $d) Invoke-AgentHarnessScreenDecision -Arguments $a -Context $ctx -Definition $d }
        questions = { param($a, $ctx, $d) Invoke-AgentHarnessQuestionDecision -Arguments $a -Context $ctx -Definition $d }
    }
    if ($Handlers) {
        foreach ($name in $Handlers.Keys) {
            if ($Handlers[$name] -isnot [scriptblock]) { throw 'Decision tool handlers must be scriptblocks.' }
            $registry[$name] = $Handlers[$name]
        }
    }
    $packages = [Collections.Generic.List[object]]::new()
    foreach ($item in $Definition) { $packages.Add($item) }
    foreach ($file in $Path) {
        try {
            $fullPath = [IO.Path]::GetFullPath($file, $Root)
            $text = [IO.File]::ReadAllText($fullPath)
            if (-not $text.TrimStart().StartsWith('{')) { throw 'Expected an object.' }
            $packages.Add((ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate -ErrorAction Stop))
        }
        catch { throw 'Cannot load decision tool configuration. Supply a readable JSON object file.' }
    }
    $definitions = [ordered]@{}
    foreach ($item in $packages) {
        # Copy caller-owned configuration; handlers never mutate it.
        $copy = ConvertTo-Json -InputObject $item -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop
        $d = ConvertFrom-Json -InputObject $copy -AsHashtable -NoEnumerate -ErrorAction Stop
        if ($d -isnot [Collections.IDictionary] -or $d.format_version -ne 1 -or $d.tool.type -cne 'function') {
            throw 'Unsupported decision tool configuration format.'
        }
        $name = $d.tool.function.name
        if ($name -isnot [string] -or $name -cnotmatch '^[A-Za-z_][A-Za-z0-9_]{0,63}$' -or $definitions.Contains($name)) {
            throw 'Decision tool names must be unique function names of at most 64 characters.'
        }
        if (-not $registry.ContainsKey([string]$d.handler)) { throw 'Unknown decision tool handler. Register it with -DecisionToolHandlers.' }
        if ($d.tool.function.description -isnot [string] -or $d.tool.function.parameters.type -cne 'object') {
            throw 'Decision tools require a description and an object parameter schema.'
        }
        Assert-AgentHarnessDecisionConfig -Config $d.config
        if ($d.handler -eq 'screen_target') { Assert-AgentHarnessScreenDecisionConfig -Config $d.config }
        $definitions[$name] = @{ Definition = $d; Handler = $registry[$d.handler] }
    }
    @{
        Definitions = $definitions
        Invoke = {
            param($definition, $state, $questions, $attachments, $root)
            Invoke-AgentHarnessDecision -Config $definition.config -State $state -Questions $questions -Attachment $attachments -Root $root
        }
    }
}
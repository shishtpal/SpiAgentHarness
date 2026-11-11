function Invoke-AgentHarnessToolCall {
    param(
        [hashtable]$Call, [Collections.IDictionary]$ToolTable, [hashtable]$Context,
        [int]$MaxOutputChars = 8000
    )

    $name = [string]$Call.function.name
    $arguments = $Call.function.arguments
    $tool = $ToolTable[$name]
    # Built-in approval prompts already display the full action; avoid showing it twice.
    if (-not ($tool.RequiresApproval -and -not $Context.YOLO)) {
        $displayArguments = Format-AgentHarnessToolArguments $arguments
        if ($tool.McpBinding) { $displayArguments = Protect-AgentHarnessMcpText -Text $displayArguments -Connection $tool.McpBinding.Connection }
        Write-AgentHarnessBlock -Title "Tool: $name" -Text $displayArguments `
            -Color Magenta -Quiet:$Context.Quiet
    }
    if (-not $tool) {
        $result = "ERROR: unknown tool '$name'. Available: $($ToolTable.Keys -join ', ')"
    }
    else {
        try {
            # Keep ordinary cmdlet errors inside the tool result as well as thrown exceptions.
            $ErrorActionPreference = 'Stop'
            $parsed = ConvertFrom-Json -InputObject $arguments -AsHashtable -NoEnumerate -ErrorAction Stop
            if ($parsed -isnot [hashtable]) { throw 'Tool arguments must be a JSON object.' }
            # External scriptblocks can retain their caller's Continue preference.
            $raw = @(& $tool.Script $parsed $Context 2>&1)
            $toolError = $raw | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | Select-Object -First 1
            if ($toolError) { throw $toolError }
            # Detect multimodal results: a single hashtable with a ContentParts key.
            $multimodal = $null
            if ($raw.Count -eq 1 -and $raw[0] -is [hashtable] -and $raw[0].ContainsKey('ContentParts')) {
                $multimodal = @($raw[0].ContentParts)
            }
            $result = if ($null -ne $multimodal) {
                # Use the text parts for display and character-limit accounting.
                (@($multimodal | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join "`n")
            }
            elseif ($raw.Count -eq 1 -and $raw[0] -is [string]) { $raw[0] }
            else { ($raw | Out-String -Width 200).Trim("`r", "`n") }

            # Stage multimodal media for on-demand injection; keep only placeholder text in messages.
            if ($null -ne $multimodal -and $Context) {
                $textInfo = (@($multimodal | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join "`n").Trim()
                $mediaParts = @($multimodal | Where-Object { $_.type -ne 'text' })
                $placeholder = $null
                if ($mediaParts.Count -eq 1 -and $mediaParts[0].type -eq 'image_url') {
                    $m = [regex]::Match($textInfo, '^Image:\s*(.+?)\s*\((\d+)\s*bytes,\s*([^)]+)\)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    if ($m.Success) {
                        $sizeMb = [math]::Round(([double]$m.Groups[2].Value / 1MB), 2)
                        $placeholder = "[image: $($m.Groups[1].Value) — $sizeMb MB, $($m.Groups[3].Value.Trim())]"
                    }
                }
                if (-not $placeholder -and $mediaParts.Count -gt 0) {
                    $first = $mediaParts[0]
                    $label = switch ($first.type) { 'image_url' { 'image' } 'video_url' { 'video' } 'file' { 'file' } default { 'media' } }
                    $pathHint = if ($textInfo) { ($textInfo -split "`n")[0] } else { 'attachment' }
                    $placeholder = "[$label`: $pathHint]"
                }
                if ($placeholder) {
                    $Context['_PendingToolMedia'] = @{
                        ContentPart = @($multimodal)
                        Placeholder = $placeholder
                    }
                    $result = $placeholder
                }
            }
        }
        catch { $result = "ERROR: $($_.Exception.Message)"; $multimodal = $null }
    }

    if ([string]::IsNullOrEmpty($result)) { $result = '(no output)' }
    if ($result.Length -gt $MaxOutputChars) {
        if ($tool.OutputMustFit) {
            $result = if ($tool.OutputLimitMessage) { $tool.OutputLimitMessage }
            elseif ($tool.DecisionTool) { 'ERROR: Decision result exceeds MaxToolOutputChars; increase the invocation output limit. No complete decision was returned.' }
            else { 'ERROR: Skill page exceeds MaxToolOutputChars; retry with a smaller max_chars or increase the invocation output limit. No complete page was returned.' }
        }
        else { $result = $result.Substring(0, $MaxOutputChars) + "`n...[truncated $($result.Length - $MaxOutputChars) chars]" }
    }
    $color = if ($result -like 'ERROR:*' -or $result -match '^exit code: (?!0\b)-?\d+') { 'Red' } else { 'Cyan' }
    Write-AgentHarnessBlock -Title ("Result: {0} ({1:N0} chars)" -f $name, $result.Length) `
        -Text $result -Color $color -Quiet:$Context.Quiet
    @{ role = 'tool'; tool_call_id = $Call.id; name = $name; content = $result }
}
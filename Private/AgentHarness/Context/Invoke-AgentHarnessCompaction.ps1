function New-AgentHarnessCompactionState {
    param(
        [bool]$Enabled,
        [int]$Budget = 131072,
        [string]$ArchiveRoot = '.agents/harness/compaction',
        [bool]$MeasureOnly
    )

    @{
        Enabled = $Enabled; Budget = $Budget; ArchiveRoot = $ArchiveRoot; MeasureOnly = $MeasureOnly
        ToolSpecCharacters = 0L; PromptTokens = 0L; CompletionTokens = 0L
        Index = 0; Compactions = 0; CompactedSpans = 0; CompactedMedia = 0
        ArchivePaths = [Collections.Generic.List[string]]::new()
        Manifest = [Collections.Generic.List[object]]::new()
        ProtectedMessages = [Collections.Generic.List[object]]::new()
        RetiredMessages = [Collections.Generic.HashSet[object]]::new()
        Notices = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        PendingInjections = [Collections.Generic.List[object]]::new()
    }
}

function Write-AgentHarnessCompactionNotice {
    param([hashtable]$State, [string]$Key, [string]$Text)

    if ($State.Notices.Add($Key)) { Write-Warning $Text }
}

function Get-AgentHarnessCompactionSpans {
    param([Collections.Generic.List[object]]$Messages)

    # Check protocol pairing without imposing the context loader's completed-answer requirement.
    $spans = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Messages.Count; $i++) {
        $message = $Messages[$i]
        if ($message.role -eq 'tool') { throw 'Orphan tool result.' }
        if (-not $message.tool_calls.Count) { continue }
        if ($message.role -ne 'assistant') { throw 'Invalid tool-call role.' }
        $pending = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        foreach ($call in $message.tool_calls) {
            if ([string]::IsNullOrWhiteSpace($call.id) -or $pending.ContainsKey($call.id)) { throw 'Invalid tool-call ID.' }
            $pending.Add($call.id, $call.function.name)
        }
        $indexes = [Collections.Generic.List[int]]::new()
        while ($pending.Count) {
            $i++
            if ($i -ge $Messages.Count) { throw 'Unresolved tool calls.' }
            $result = $Messages[$i]
            if ($result.role -ne 'tool' -or -not $result.tool_call_id -or -not $pending.ContainsKey($result.tool_call_id)) { throw 'Invalid tool result.' }
            if ($result.name -and $result.name -cne $pending[$result.tool_call_id]) { throw 'Tool result name mismatch.' }
            $null = $pending.Remove($result.tool_call_id)
            $indexes.Add($i)
        }
        $spans.Add($indexes.ToArray())
    }
    , $spans
}

function Invoke-AgentHarnessCompaction {
    param(
        [Collections.Generic.List[object]]$Messages, [hashtable]$Context,
        [string]$Provider, [string]$Model, [ValidateSet('budget', 'too_long')][string]$Reason = 'budget',
        [scriptblock]$Log, [switch]$Classify, [Management.Automation.ErrorRecord]$Failure
    )

    if ($Classify) {
        $status = [int]$Failure.Exception.Data['Status']
        return ($status -ge 400 -and $status -lt 500 -and
            $Failure.Exception.Message -match '(?i)context length|context window|too long|maximum context|token limit|too many tokens')
    }
    $outcome = [pscustomobject]@{ Changed = $false; EstimatedBefore = 0L; EstimatedAfter = 0L; ArchivePath = $null }
    $state = $Context.AutoCompact
    if (-not $state -or -not $state.Enabled) { return $outcome }
    $ErrorActionPreference = 'Stop'
    try {
        [long]$before = $state.ToolSpecCharacters
        foreach ($message in $Messages) { $before += Get-AgentHarnessMessageCost $message }
        $outcome.EstimatedBefore = $before; $outcome.EstimatedAfter = $before
        if ($Reason -eq 'budget' -and $before -le $state.Budget) { return $outcome }
        if ($state.MeasureOnly) {
            Write-AgentHarnessCompactionNotice $state 'measure' 'AutoCompact measurement only: request exceeds the estimated budget; messages are unchanged.'
            return $outcome
        }

        $spans = Get-AgentHarnessCompactionSpans $Messages
        $directory = Join-Path $state.ArchiveRoot $Context.ContextSessionId
        do {
            $nextIndex = $state.Index + 1
            $path = Resolve-AgentHarnessStatePath -Root $Context.Root -Path (Join-Path $directory ('{0:D4}.json' -f $nextIndex))
            if (-not (Test-Path -LiteralPath $path)) { break }
            $state.Index = $nextIndex
        } while ($true)
        $candidates = [Collections.Generic.List[object]]::new()
        foreach ($span in $spans) {
            $replacements = [Collections.Generic.List[object]]::new()
            [long]$savings = 0
            foreach ($index in $span) {
                $message = $Messages[$index]
                if ($state.RetiredMessages.Contains($message) -or ($message.content -is [string] -and
                        $message.content -match '^\[compacted tool output: [^\r\n]+, \d+ chars, archived as [^\r\n]+#\d+(?:, exit code -?\d+)?\]$')) { continue }
                $cost = Get-AgentHarnessMessageCost $message
                $name = $message.name
                if (-not $name) {
                    $callMessage = $Messages[$span[0] - 1]
                    $name = ($callMessage.tool_calls | Where-Object { $_.id -ceq $message.tool_call_id }).function.name
                }
                $exit = if ($message.content -is [string] -and $message.content -match '^exit code: (-?\d+)') { ', exit code ' + $Matches[1] } else { '' }
                $pointer = '[compacted tool output: {0}, {1} chars, archived as {2}#{3}{4}]' -f $name, $cost, $path, $index, $exit
                $replacement = @{ role = 'tool'; tool_call_id = $message.tool_call_id; name = $name; content = $pointer }
                $saved = $cost - (Get-AgentHarnessMessageCost $replacement)
                if ($saved -le 0) { continue }
                $replacements.Add(@{ Index = $index; Message = $replacement })
                $savings += $saved
            }
            if ($savings -gt 0) { $candidates.Add(@{ Savings = $savings; Replacements = $replacements; Media = 0; Span = 1 }) }
        }
        for ($i = 0; $i -lt $Messages.Count; $i++) {
            $message = $Messages[$i]
            if ($message.role -ne 'user' -or $message.content -is [string] -or $state.ProtectedMessages.Contains($message)) { continue }
            for ($j = 0; $j -lt $message.content.Count; $j++) {
                $part = $message.content[$j]
                if ($part.type -cnotin 'image_url', 'video_url', 'file') { continue }
                $cost = Get-AgentHarnessMessageCost @{ content = @($part) }
                $label = if ($part.type -ceq 'file') { $part.file.filename } else { $part.type }
                $placeholder = @{ type = 'text'; text = ('[attachment content replaced during compaction: {0}, {1} chars, archived as {2}#{3}]' -f $label, $cost, $path, $i) }
                $saved = $cost - $placeholder.text.Length
                if ($saved -gt 0) { $candidates.Add(@{ Savings = $saved; Index = $i; Part = $j; Value = $placeholder; Media = 1; Span = 0 }) }
            }
        }
        [long]$floor = $before
        foreach ($candidate in $candidates) { $floor -= $candidate.Savings }
        if ($floor -gt $state.Budget) {
            Write-AgentHarnessCompactionNotice $state 'floor' 'AutoCompact: protected content and retained metadata exceed the estimated budget; sending best effort.'
        }
        if (-not $candidates.Count) { return $outcome }
        [long]$target = [Math]::Max(0, $state.Budget - [Math]::Max(4000, [Math]::Ceiling($state.Budget * 0.1)))
        if ($Reason -eq 'too_long') { $target = [Math]::Min($target, [Math]::Max(0, $before - [Math]::Max(4000, [Math]::Ceiling($before * 0.1)))) }
        $target = [Math]::Max($target, $floor)
        $selected = [Collections.Generic.List[object]]::new()
        [long]$after = $before
        foreach ($candidate in $candidates) {
            if ($after -le $target) { break }
            $selected.Add($candidate); $after -= $candidate.Savings
        }
        if (-not $selected.Count) { return $outcome }

        # Prepare copies and verify before disk writes; publish only after both atomic writes succeed.
        $proposed = [Collections.Generic.List[object]]::new()
        $proposed.AddRange($Messages.ToArray())
        $mediaMessages = [Collections.Generic.HashSet[int]]::new()
        $spanCount = 0; $mediaCount = 0
        foreach ($candidate in $selected) {
            $spanCount += $candidate.Span; $mediaCount += $candidate.Media
            if ($candidate.Media) {
                $index = $candidate.Index
                if ($mediaMessages.Add($index)) {
                    $copy = @{}
                    if ($Messages[$index] -is [Collections.IDictionary]) {
                        foreach ($key in $Messages[$index].Keys) { $copy[$key] = $Messages[$index][$key] }
                    }
                    else { foreach ($property in $Messages[$index].PSObject.Properties) { $copy[$property.Name] = $property.Value } }
                    $copy.content = @($Messages[$index].content)
                    $proposed[$index] = $copy
                }
                $proposed[$index].content[$candidate.Part] = $candidate.Value
            }
            else { foreach ($replacement in $candidate.Replacements) { $proposed[$replacement.Index] = $replacement.Message } }
        }
        $null = Get-AgentHarnessCompactionSpans $proposed
        [long]$verified = $state.ToolSpecCharacters
        foreach ($message in $proposed) { $verified += Get-AgentHarnessMessageCost $message }
        if ($verified -ne $after -or $verified -ge $before) { throw 'Compaction did not reduce message cost.' }
        $snapshot = New-AgentHarnessTranscript -Messages $Messages.ToArray() -Context $Context -Provider $Provider -Model $Model -Index $nextIndex -Reason $Reason -EstimatedBefore $before
        $archive = Write-AgentHarnessTranscript -Path $path -Value $snapshot -Context $Context
        $state.Index = $nextIndex # Reserve even if manifest writing fails.
        $entry = @{ index = $nextIndex; file = [IO.Path]::GetFileName($path); trigger = $Reason; estimatedBefore = $before; estimatedAfter = $after; createdAt = $snapshot.createdAt }
        $entries = @($state.Manifest.ToArray()) + @($entry)
        $null = Write-AgentHarnessTranscript -Path (Join-Path $directory 'manifest.json') -Value @{ format = 'SpiAgentHarness.TranscriptManifest'; version = 1; archives = $entries } -Context $Context -Replace
        $state.Manifest.Add($entry); $state.ArchivePaths.Add($archive)
        for ($i = 0; $i -lt $Messages.Count; $i++) {
            if (-not [object]::ReferenceEquals($Messages[$i], $proposed[$i])) {
                $Messages[$i] = $proposed[$i]
                if ($Messages[$i].role -eq 'tool') { $null = $state.RetiredMessages.Add($Messages[$i]) }
            }
        }
        $state.Compactions++; $state.CompactedSpans += $spanCount; $state.CompactedMedia += $mediaCount
        $outcome.Changed = $true; $outcome.EstimatedAfter = $after; $outcome.ArchivePath = $archive
        foreach ($index in $mediaMessages) { Write-Warning "AutoCompact replaced historical attachment content in message $index; original content is archived." }
        if ($after -gt $state.Budget) { Write-AgentHarnessCompactionNotice $state 'exhausted' 'AutoCompact exhausted eligible savings; request remains above the estimated budget.' }
        if ($Log) { & $Log "   compacted $spanCount tool spans and $mediaCount media parts ($($Messages.Count) messages archived): ~$before -> ~$after chars" 'DarkGray' }
    }
    catch {
        # Paths, tool payloads and provider bodies can contain sensitive data; never echo the exception.
        Write-AgentHarnessCompactionNotice $state 'failure' 'AutoCompact could not safely archive and compact this request; continuing with current messages. Check the archive path, permissions and 64 MiB limit.'
    }
    $outcome
}
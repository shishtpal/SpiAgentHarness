# Included by Invoke-AgentHarness.Tests.ps1; synthetic content and offline transports only.
$compactRoot = Join-Path $fixture 'compact-fixture'
$null = New-Item -ItemType Directory -Path $compactRoot
$compactOptions = $basic.Clone()
$compactOptions.WorkingDirectory = $compactRoot
$compactOptions.NoAgentsFile = $true
$compactOptions.NoPromptHistory = $true
$compactOptions.NoPromptSound = $true
$compactOptions.NoCompletionPrompt = $true
$compactOptions.NoSubAgents = $true

function New-CompactFixtureHistory {
    param([int]$Spans = 15, [int]$Size = 8000)
    $items = [Collections.Generic.List[object]]::new()
    $items.Add(@{ role = 'system'; content = 'Synthetic system instructions.' })
    $items.Add(@{ role = 'user'; content = "Keep this instruction verbatim: नमस्ते`nsecond line" })
    for ($i = 0; $i -lt $Spans; $i++) {
        $items.Add(@{ role = 'assistant'; content = "Commentary $i"; tool_calls = @((New-HarnessCall echo '{}' "compact_$i")) })
        $items.Add(@{ role = 'tool'; name = 'echo'; tool_call_id = "compact_$i"; content = ('x' * $Size) })
    }
    , $items
}
function New-CompactFixtureContext {
    param([int]$Budget = 48000, [bool]$MeasureOnly = $false, [string]$ArchiveRoot = '.agents/harness/compaction')
    & $module {
        param($root, $budget, $measureOnly, $archiveRoot)
        @{ Root = $root; ContextSessionId = [guid]::NewGuid().ToString('N'); AutoCompact = (New-AgentHarnessCompactionState -Enabled $true -Budget $budget -ArchiveRoot $archiveRoot -MeasureOnly $measureOnly) }
    } $compactRoot $Budget $MeasureOnly $ArchiveRoot
}
function Invoke-CompactFixture {
    [CmdletBinding()]
    param($Messages, $Context, [string]$Reason = 'budget', [string]$Preference = 'Stop')
    & $module {
        param($messages, $context, $reason, $preference)
        $ErrorActionPreference = $preference
        Invoke-AgentHarnessCompaction -Messages $messages -Context $context -Reason $reason -Provider TestA -Model synthetic
    } $Messages $Context $Reason $Preference
}
function Get-CompactFixtureCost {
    param($Messages)
    & $module { param($messages) [long]$total = 0; foreach ($m in $messages) { $total += Get-AgentHarnessMessageCost $m }; $total } $Messages
}
function New-CompactFixtureError {
    param([string]$Text = 'maximum context length exceeded', [int]$Status = 400)
    $exception = [Exception]::new($Text); $exception.Data['Status'] = $Status; $exception
}

# Finite retirement, preservation, archive-first, pairing and idempotence.
$compactMessages = New-CompactFixtureHistory
$compactOriginal = ConvertTo-Json -InputObject $compactMessages.ToArray() -Depth 30 -Compress
$compactRaw = [Collections.Generic.List[object]]::new(); $compactRaw.AddRange($compactMessages.ToArray())
$compactContext = New-CompactFixtureContext
$compactContext.AutoCompact.ToolSpecCharacters = 1000
$compacted = Invoke-CompactFixture $compactMessages $compactContext
Assert-Harness ($compacted.Changed -and $compacted.EstimatedAfter -le 43200 -and $compactContext.AutoCompact.CompactedSpans -gt 3) 'One pass retires more than three spans until the target'
Assert-Harness ($compactMessages[0].content -ceq 'Synthetic system instructions.' -and $compactMessages[1].content -ceq $compactRaw[1].content) 'System and Unicode user instructions survive unchanged'
Assert-Harness ((ConvertTo-Json -InputObject $compactRaw.ToArray() -Depth 30 -Compress) -ceq $compactOriginal) 'Replacement never mutates shared raw history'
$compactArchive = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($compacted.ArchivePath)) -AsHashtable -NoEnumerate
Assert-Harness ($compactArchive.format -ceq 'SpiAgentHarness.Transcript' -and $compactArchive.messages[-1].role -eq 'tool') 'Pre-pass archive accepts completed tool batches without a final answer'
Assert-Harness ((ConvertTo-Json -InputObject $compactArchive.messages -Depth 30 -Compress) -ceq $compactOriginal) 'Archive contains the exact original pre-retirement payloads'
foreach ($i in 0..14) {
    $toolIndex = 3 + $i * 2
    Assert-Harness ($compactMessages[$toolIndex].tool_call_id -ceq $compactMessages[$toolIndex - 1].tool_calls[0].id -and $compactMessages[$toolIndex].name -ceq 'echo') 'Every replacement preserves its matching call ID and name'
}
$compactManifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path ([IO.Path]::GetDirectoryName($compacted.ArchivePath)) 'manifest.json'))) -AsHashtable -NoEnumerate
Assert-Harness ($compactManifest.archives -is [array] -and $compactManifest.archives.Count -eq 1 -and $compactManifest.archives[0].estimatedAfter -eq $compacted.EstimatedAfter) 'Atomic manifest preserves a singleton entries array'
Assert-Harness ([IO.File]::ReadAllBytes($compacted.ArchivePath)[0] -eq 123 -and @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($compacted.ArchivePath)) -Filter '*.tmp').Count -eq 0) 'Transcript is UTF-8 without BOM and leaves no temporary file'
$compactAfter = ConvertTo-Json -InputObject $compactMessages.ToArray() -Depth 30 -Compress
$unchanged = Invoke-CompactFixture $compactMessages $compactContext
Assert-Harness (-not $unchanged.Changed -and $compactContext.AutoCompact.Compactions -eq 1 -and (ConvertTo-Json -InputObject $compactMessages.ToArray() -Depth 30 -Compress) -ceq $compactAfter) 'A below-budget turn preserves surviving history and writes no further archive'
$newCall = New-HarnessCall echo '{}' 'new_breach'
$compactMessages.Add(@{ role = 'assistant'; content = ''; tool_calls = @($newCall) })
$compactMessages.Add(@{ role = 'tool'; name = 'echo'; tool_call_id = 'new_breach'; content = 'y' * 48000 })
$again = Invoke-CompactFixture $compactMessages $compactContext
Assert-Harness ($again.Changed -and $again.EstimatedAfter -lt $again.EstimatedBefore -and $compactContext.AutoCompact.Compactions -eq 2) 'New content can trigger another strictly decreasing pass'
Assert-HarnessThrows { Invoke-AgentHarness 'reject transcript' @compactOptions -ContextPath $compacted.ArchivePath } '*Transcript archives cannot be loaded*'

# A multi-call span stays complete; sufficient tool savings leave historical media intact.
$multiMessages = New-CompactFixtureHistory -Spans 0
$multiMessages[1].content = @(@{ type = 'text'; text = 'Keep user text' }, @{ type = 'image_url'; image_url = @{ url = 'data:image/png;base64,' + ('m' * 9000) } })
$multiMessages.Add(@{ role = 'assistant'; content = $null; tool_calls = @((New-HarnessCall echo '{}' 'multi_one'), (New-HarnessCall other '{}' 'multi_two')) })
$multiMessages.Add(@{ role = 'tool'; tool_call_id = 'multi_one'; content = ('exit code: 7' + ('e' * 25000)) })
$multiMessages.Add(@{ role = 'tool'; tool_call_id = 'multi_two'; name = 'other'; content = @(@{ type = 'text'; text = 'Multimodal evidence' }, @{ type = 'video_url'; video_url = @{ url = 'data:video/mp4;base64,' + ('v' * 25000) } }) })
$multiContext = New-CompactFixtureContext -Budget 30000
$multiResult = Invoke-CompactFixture $multiMessages $multiContext
Assert-Harness ($multiResult.Changed -and $multiContext.AutoCompact.CompactedSpans -eq 1 -and $multiContext.AutoCompact.CompactedMedia -eq 0 -and $multiMessages[1].content[1].type -ceq 'image_url') 'A multi-call span retires together without replacing media when tool savings suffice'
Assert-Harness ($multiMessages[3].name -ceq 'echo' -and $multiMessages[3].content -like '*, exit code 7]' -and $multiMessages[4].name -ceq 'other' -and $multiMessages[4].content -is [string]) 'Multi-call pointers retain matching names, exit code and multimodal payload provenance'

# Supported and unknown content-part metering.
foreach ($part in @(
    @{ type = 'text'; text = 'a' * 1000 },
    @{ type = 'image_url'; image_url = @{ url = 'a' * 1000 } },
    @{ type = 'video_url'; video_url = @{ url = 'a' * 1000 } },
    @{ type = 'file'; file = @{ filename = 'synthetic.bin'; file_data = 'a' * 1000 } }
)) {
    $partCost = & $module { param($p) Get-AgentHarnessMessageCost @{ content = @($p); tool_calls = @(@{ function = @{ arguments = '{}' } }) } } $part
    Assert-Harness ($partCost -eq 1002) "Cost includes $($part.type) and call arguments"
}
$unknownCost = & $module { Get-AgentHarnessMessageCost @{ content = @(@{ type = 'unknown'; payload = 'z' * 1000 }) } }
Assert-Harness ($unknownCost -gt 1000) 'Unknown content is metered by serialized size'

# Historical media may dominate user content; current prompt remains protected after guidance.
$mediaMessages = New-CompactFixtureHistory -Spans 0
$historicalMedia = @(
    @{ type = 'text'; text = 'Historical text remains verbatim.' },
    @{ type = 'video_url'; video_url = @{ url = 'data:video/mp4;base64,' + ('a' * 9000) } },
    @{ type = 'file'; file = @{ filename = 'evidence.pdf'; file_data = 'data:application/pdf;base64,' + ('b' * 9000) } },
    @{ type = 'unknown'; payload = 'protected unknown' }
)
$mediaMessages[1] = @{ role = 'user'; content = $historicalMedia }
$currentMedia = @{ role = 'user'; content = @(@{ type = 'text'; text = 'Current task' }, @{ type = 'image_url'; image_url = @{ url = 'data:image/png;base64,' + ('c' * 5000) } }) }
$guidance = @{ role = 'user'; content = 'Approval guidance remains intact.' }
$mediaMessages.Add($currentMedia); $mediaMessages.Add($guidance)
$mediaContext = New-CompactFixtureContext -Budget 4000
$mediaContext.AutoCompact.ProtectedMessages.Add($currentMedia); $mediaContext.AutoCompact.ProtectedMessages.Add($guidance)
$mediaBefore = ConvertTo-Json -InputObject $historicalMedia -Depth 20 -Compress
$mediaWarnings = @()
$mediaResult = Invoke-CompactFixture $mediaMessages $mediaContext -WarningVariable mediaWarnings 3>$null
Assert-Harness ($mediaResult.Changed -and $mediaContext.AutoCompact.CompactedMedia -eq 2) 'Large historical media remains eligible even when protected content exceeds budget'
Assert-Harness ($mediaMessages[1].content[0].text -ceq $historicalMedia[0].text -and $mediaMessages[1].content[3].type -ceq 'unknown') 'Text and unknown user parts are preserved'
Assert-Harness ($mediaMessages[1].content[1].text -like '*video_url*' -and $mediaMessages[1].content[2].text -like '*evidence.pdf*') 'Media pointers retain filename or media type'
Assert-Harness ((ConvertTo-Json -InputObject $historicalMedia -Depth 20 -Compress) -ceq $mediaBefore -and [object]::ReferenceEquals($mediaMessages[2], $currentMedia) -and [object]::ReferenceEquals($mediaMessages[3], $guidance)) 'Media replacement copies arrays and protects the actual task prompt and guidance'
$noOpMedia = Invoke-CompactFixture $mediaMessages $mediaContext 3>$null
Assert-Harness (-not $noOpMedia.Changed -and $mediaContext.AutoCompact.Compactions -eq 1) 'Exhausted budget-4000 input terminates without rearchiving placeholders'

foreach ($preference in 'Continue', 'Stop') {
    $immutable = New-CompactFixtureHistory -Spans 0
    $immutable[1].content = 'i' * 9000
    $immutableContext = New-CompactFixtureContext -Budget 4000
    $warnings = @()
    $first = Invoke-CompactFixture $immutable $immutableContext -Preference $preference -WarningVariable warnings 3>$null
    $second = Invoke-CompactFixture $immutable $immutableContext -Preference $preference -WarningVariable +warnings 3>$null
    Assert-Harness (-not $first.Changed -and -not $second.Changed -and $warnings.Count -eq 1 -and $immutable[1].content.Length -eq 9000) "Immutable-only overflow warns once under $preference"
    $blocked = New-CompactFixtureHistory -Spans 1
    $blockedContext = New-CompactFixtureContext -Budget 4000 -ArchiveRoot '../escape'
    $failed = Invoke-CompactFixture $blocked $blockedContext -Preference $preference 3>$null
    Assert-Harness (-not $failed.Changed -and $blocked[3].content.Length -eq 8000 -and $blockedContext.AutoCompact.ArchivePaths.Count -eq 0) "Archive failure leaves payload unchanged under $preference"
}
$small = New-CompactFixtureHistory -Spans 1 -Size 1
$smallContext = New-CompactFixtureContext -Budget 4000
$smallContext.AutoCompact.ToolSpecCharacters = 10000
$smallResult = Invoke-CompactFixture $small $smallContext 3>$null
Assert-Harness (-not $smallResult.Changed -and $small[3].content -ceq 'x') 'Large schema floor and non-saving pointers do not rewrite tiny tool results'
$malformed = New-CompactFixtureHistory -Spans 1
$malformed[3].tool_call_id = 'orphan'
$invalidResult = Invoke-CompactFixture $malformed (New-CompactFixtureContext -Budget 4000) 3>$null
Assert-Harness (-not $invalidResult.Changed -and $malformed[3].content.Length -eq 8000) 'Invalid pairing aborts before archive and mutation'

# Manifest failure reserves the transcript index and publishes nothing.
$manifestContext = New-CompactFixtureContext -Budget 4000
$manifestMessages = New-CompactFixtureHistory -Spans 1
$manifestDirectory = Join-Path $compactRoot ('.agents/harness/compaction/' + $manifestContext.ContextSessionId)
$null = New-Item -ItemType Directory -Path (Join-Path $manifestDirectory 'manifest.json') -Force
$failedManifest = Invoke-CompactFixture $manifestMessages $manifestContext 3>$null
Assert-Harness (-not $failedManifest.Changed -and $manifestMessages[3].content.Length -eq 8000 -and (Test-Path -LiteralPath (Join-Path $manifestDirectory '0001.json'))) 'Manifest failure leaves messages intact and an orphan transcript recoverable'
[IO.Directory]::Delete((Join-Path $manifestDirectory 'manifest.json'))
$retriedManifest = Invoke-CompactFixture $manifestMessages $manifestContext
Assert-Harness ($retriedManifest.Changed -and $retriedManifest.ArchivePath.EndsWith('0002.json') -and (Test-Path -LiteralPath (Join-Path $manifestDirectory '0001.json'))) 'Retry never overwrites the reserved orphan transcript'

# Exercise the real byte bound with synthetic text, without writing the oversized payload to disk.
$oversizedMessages = New-CompactFixtureHistory -Spans 1 -Size (64MB)
$oversizedContext = New-CompactFixtureContext -Budget 4000
$oversized = Invoke-CompactFixture $oversizedMessages $oversizedContext 3>$null
Assert-Harness (-not $oversized.Changed -and $oversizedMessages[3].content.Length -eq 64MB -and $oversizedContext.AutoCompact.ArchivePaths.Count -eq 0) 'Oversized serialized transcript aborts before retirement'
$oversizedMessages = $null

if ($IsWindows) {
    $linkTarget = Join-Path $compactRoot 'link-target'; $null = New-Item -ItemType Directory -Path $linkTarget
    $linkPath = Join-Path $compactRoot 'linked'; $null = New-Item -ItemType Junction -Path $linkPath -Target $linkTarget
    try {
        $linkedMessages = New-CompactFixtureHistory -Spans 1
        $linked = Invoke-CompactFixture $linkedMessages (New-CompactFixtureContext -Budget 4000 -ArchiveRoot 'linked') 3>$null
        Assert-Harness (-not $linked.Changed -and $linkedMessages[3].content.Length -eq 8000 -and @(Get-ChildItem -LiteralPath $linkTarget).Count -eq 0) 'Reparse-point archive root is refused before replacement or writes'
    }
    finally { [IO.Directory]::Delete($linkPath) }
}

# Public API: preflight applies before the first request, saves still use original raw history.
$initialHistory = New-CompactFixtureHistory -Spans 2
$initialHistory.Add(@{ role = 'assistant'; content = 'Historical final answer' })
Set-HarnessResponses @((New-HarnessResponse 'initial complete'))
$publicCompact = Invoke-AgentHarness 'Current prompt' @compactOptions -History $initialHistory.ToArray() -AutoCompact -AutoCompactBudget 12000 -PassThru -SaveContextPath 'explicit-raw.json'
$initialRequest = @(Get-HarnessRequests)[0]
$explicitRaw = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($publicCompact.ContextPath)) -AsHashtable -NoEnumerate
Assert-Harness ($publicCompact.Compactions -eq 1 -and @($initialRequest.Body.messages | Where-Object { $_.role -eq 'tool' -and $_.content -like '[[]compacted tool output:*' }).Count -eq 2) 'Initial History is compacted before the first provider request'
Assert-Harness ($explicitRaw.messages[3].content.Length -eq 8000 -and $publicCompact.RawMessages[3].content.Length -eq 8000) 'SaveContextPath still exports original raw payloads after compaction'
Set-HarnessResponses @((New-HarnessResponse 'resumed complete'))
$publicResume = Invoke-AgentHarness 'Resume prompt' @compactOptions -ContextPath $publicCompact.ContextPath -AutoCompact -AutoCompactBudget 12000 -PassThru
Assert-Harness ($publicResume.Compactions -eq 1 -and $publicResume.ContextArchivePaths.Count -eq 1) 'ContextPath receives the same initial-request preflight'
Set-HarnessResponses @((New-HarnessResponse 'unchanged baseline'))
$baseline = Invoke-AgentHarness 'Current prompt' @compactOptions -History $initialHistory.ToArray() -PassThru
$baselineBody = @(Get-HarnessRequests)[0].Body | ConvertTo-Json -Depth 30 -Compress
Set-HarnessResponses @((New-HarnessResponse 'measurement answer'))
$measureWarnings = @()
$measured = Invoke-AgentHarness 'Current prompt' @compactOptions -History $initialHistory.ToArray() -AutoCompact -AutoCompactBudget 4000 -NoAutoCompactArchive -PassThru -WarningVariable measureWarnings 3>$null
$measuredBody = @(Get-HarnessRequests)[0].Body | ConvertTo-Json -Depth 30 -Compress
Assert-Harness ($baselineBody -ceq $measuredBody -and $measured.Compactions -eq 0 -and $measured.ContextArchivePaths.Count -eq 0 -and $measureWarnings.Count -eq 1) 'Measurement-only preserves the disabled request body and counters'
Assert-Harness ($baseline.Compactions -eq 0 -and $baseline.RawMessages[3].content.Length -eq 8000) 'Disabled compaction preserves original payloads'
$measurementContext = New-CompactFixtureContext -Budget 4000 -MeasureOnly $true
$measurementMessages = New-CompactFixtureHistory -Spans 1
$measurementWarnings = @()
$null = Invoke-CompactFixture $measurementMessages $measurementContext -WarningVariable measurementWarnings 3>$null
$null = Invoke-CompactFixture $measurementMessages $measurementContext -WarningVariable +measurementWarnings 3>$null
Assert-Harness ($measurementWarnings.Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $compactRoot ('.agents/harness/compaction/' + $measurementContext.ContextSessionId))) -and $measurementMessages[3].content.Length -eq 8000) 'Repeated measurement writes no session directory and warns only once'
Set-HarnessResponses @((New-HarnessResponse 'explicit measurement save'))
$measurementSave = Invoke-AgentHarness 'Current prompt' @compactOptions -History $initialHistory.ToArray() -AutoCompact -NoAutoCompactArchive -SaveContextPath 'measurement-raw.json' -PassThru
Assert-Harness ((Test-Path -LiteralPath $measurementSave.ContextPath) -and $measurementSave.ContextArchivePaths.Count -eq 0 -and $measurementSave.RawMessages[3].content.Length -eq 8000) 'Measurement-only mode still permits independent explicit raw saves'
foreach ($parameters in @(@{ AutoCompactBudget = 4000 }, @{ AutoCompactArchivePath = 'archives' }, @{ NoAutoCompactArchive = $true })) {
    Assert-HarnessThrows { Invoke-AgentHarness 'invalid' @compactOptions @parameters } '*requires AutoCompact*'
}
Assert-HarnessThrows { Invoke-AgentHarness 'invalid' @compactOptions -AutoCompact -NoAutoCompactArchive -AutoCompactArchivePath 'archives' } '*either NoAutoCompactArchive or AutoCompactArchivePath*'

# Observe real recovery menu invocation while keeping all interaction synthetic.
$savedCompactMenu = & $module { ${function:Show-InteractiveMenu} }
try {
    & $module {
        $script:CompactMenuCount = 0
        $script:CompactMenuChoices = [Collections.Generic.Queue[string]]::new()
        function script:Show-InteractiveMenu {
            param($Options, $Title)
            $script:CompactMenuCount++
            if ($script:CompactMenuChoices.Count) { return $script:CompactMenuChoices.Dequeue() }
            'Stop'
        }
    }
    $recoveryOptions = $compactOptions.Clone(); $recoveryOptions.NoModelRecovery = $false
    Set-HarnessResponses @((New-CompactFixtureError), (New-HarnessResponse 'forced complete'))
    $forcedPublic = Invoke-AgentHarness 'Current prompt' @compactOptions -History $initialHistory.ToArray() -AutoCompact -AutoCompactBudget 100000 -PassThru
    $forcedRequests = @(Get-HarnessRequests)
    Assert-Harness ($forcedRequests.Count -eq 2 -and $forcedPublic.Iterations -eq 1 -and $forcedPublic.PromptTokens -eq 10 -and $forcedPublic.Compactions -eq 1) 'Below-budget rejection forces one reduction resend without iteration or usage inflation'
    Assert-Harness ($forcedRequests[0].Body.model -ceq $forcedRequests[1].Body.model -and $forcedRequests[0].Body.messages[3].content.Length -gt $forcedRequests[1].Body.messages[3].content.Length) 'Forced resend uses same candidate with strictly smaller payload'
    foreach ($mode in 'disabled', 'measure', 'no-savings', 'archive-failure', 'unmatched') {
        & $module { $script:CompactMenuCount = 0 }
        $options = $recoveryOptions.Clone()
        $history = $initialHistory.ToArray()
        $errorText = 'context length exceeded'
        switch ($mode) {
            measure { $options.AutoCompact = $true; $options.NoAutoCompactArchive = $true }
            'no-savings' { $options.AutoCompact = $true; $history = @() }
            'archive-failure' { $options.AutoCompact = $true; $options.AutoCompactArchivePath = '../escape' }
            unmatched { $options.AutoCompact = $true; $errorText = 'invalid request field' }
        }
        Set-HarnessResponses @((New-CompactFixtureError $errorText))
        Assert-HarnessThrows { Invoke-AgentHarness 'Current prompt' @options -History $history 3>$null } '*No working model*'
        Assert-Harness (@(Get-HarnessRequests).Count -eq 1 -and (& $module { $script:CompactMenuCount }) -eq 1) "$mode uses existing recovery without identical compaction resend"
    }
    & $module { $script:CompactMenuCount = 0; $script:CompactMenuChoices.Enqueue('Retry current model') }
    Set-HarnessResponses @((New-CompactFixtureError), (New-CompactFixtureError), (New-CompactFixtureError))
    Assert-HarnessThrows { Invoke-AgentHarness 'Current prompt' @recoveryOptions -History $initialHistory.ToArray() -AutoCompact -AutoCompactBudget 100000 } '*No working model*'
    Assert-Harness (@(Get-HarnessRequests).Count -eq 3 -and (& $module { $script:CompactMenuCount }) -eq 2) 'Second rejection uses recovery; its candidate retry cannot reset the forced resend guard'
    $http200 = @{ error = @{ code = 400; message = 'too many tokens' } } | ConvertTo-Json | ConvertFrom-Json
    Set-HarnessResponses @($http200, (New-HarnessResponse 'numeric error recovered'))
    $numericResult = Invoke-AgentHarness 'Current prompt' @compactOptions -History $initialHistory.ToArray() -AutoCompact -AutoCompactBudget 100000 -PassThru
    Assert-Harness ($numericResult.Compactions -eq 1 -and @(Get-HarnessRequests).Count -eq 2) 'Numeric 4xx carried in HTTP 200 error object reaches the backstop'

    # Locked request after a tool batch: execute a tool exactly once despite the resend.
    & $module { $script:CompactToolExecutions = 0 }
    $roundTripTools = @{ compact_echo = @{ Script = { param($a, $ctx) & (Get-Module SpiAgentHarness) { $script:CompactToolExecutions++ }; 't' * 8000 } } }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall compact_echo))), (New-CompactFixtureError), (New-HarnessResponse 'locked recovered'))
    $locked = Invoke-AgentHarness 'Use tool' @compactOptions -Tools $roundTripTools -AutoCompact -AutoCompactBudget 100000 -PassThru
    Assert-Harness ($locked.Iterations -eq 2 -and $locked.PromptTokens -eq 20 -and $locked.CompletionTokens -eq 4 -and (& $module { $script:CompactToolExecutions }) -eq 1) 'Locked backstop resends without replaying tools or charging an iteration'

    # Inspect recovery state at the transport boundary, before the first successful response.
    $savedCompactChat = & $module { ${function:Invoke-AgentHarnessChat} }
    try {
        & $module {
            $script:CompactStateSnapshots = [Collections.Generic.List[object]]::new()
            function script:Invoke-AgentHarnessChat {
                param($Uri, $ApiKey, $Body, $TimeoutSec, $Log, $RequestHeaders)
                $state = $script:CompactObservedState
                $script:CompactStateSnapshots.Add(@{ Model = $Body.model; Attempts = $state.Attempts; Locked = $state.Locked; Candidates = $state.Candidates.Count })
                if ($script:CompactStateSnapshots.Count -le 2) {
                    $errorObject = [Exception]::new('context window exceeded'); $errorObject.Data['Status'] = 400; throw $errorObject
                }
                [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'replacement complete' } }) }
            }
        }
        $observedContext = New-CompactFixtureContext -Budget 100000
        $observedMessages = New-CompactFixtureHistory -Spans 3
        $observedState = @{ Attempts = 0; Locked = $false; Candidates = [Collections.Generic.List[object]]::new(); All = $false }
        $observedState.Candidates.Add([pscustomobject]@{ Provider = 'TestA'; Id = 'initial-model' })
        $observedState.Candidates.Add([pscustomobject]@{ Provider = 'TestA'; Id = 'replacement-model' })
        $observedTurn = & $module {
            param($state, $messages, $context)
            $script:CompactObservedState = $state
            Invoke-AgentHarnessTurn -State $state -Messages $messages -ToolSpecs @() -TimeoutSec 10 -MaxModelAttempts 3 -Iteration 1 -Log {} -NoModelRecovery -CompactionContext $context
        } $observedState $observedMessages $observedContext
        $observedSnapshots = & $module { $script:CompactStateSnapshots.ToArray() }
        Assert-Harness ($observedSnapshots.Count -eq 3 -and $observedSnapshots[1].Attempts -eq 0 -and -not $observedSnapshots[1].Locked -and $observedSnapshots[1].Candidates -eq 2 -and $observedSnapshots[1].Model -ceq 'initial-model') 'Intercepted rejection preserves attempts, lock and candidate list before resend'
        Assert-Harness ($observedTurn.Candidate.Id -ceq 'replacement-model' -and $observedSnapshots[2].Attempts -eq 1 -and $observedContext.AutoCompact.Compactions -eq 1) 'Second rejection mutates recovery state once and next candidate cannot reset compaction guard'
    }
    finally { & $module { param($saved) Set-Item Function:script:Invoke-AgentHarnessChat -Value $saved } $savedCompactChat }
}
finally {
    & $module { param($saved) Set-Item Function:script:Show-InteractiveMenu -Value $saved } $savedCompactMenu
}

# Session isolation and private options forwarding without launching real terminals.
$capturedOptions = @{}
$captureTools = @{ capture = @{} }
$captureTools.capture.Script = { param($a, $ctx) $capturedOptions.Value = $ctx.SubAgentOptions.Clone(); 'captured' }.GetNewClosure()
foreach ($measurement in $false, $true) {
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall capture))), (New-HarnessResponse 'captured'))
    $null = Invoke-AgentHarness 'Capture policy' @compactOptions -Tools $captureTools -AutoCompact -AutoCompactBudget 100000 -NoAutoCompactArchive:$measurement
    Assert-Harness ($capturedOptions.Value.AutoCompact -and $capturedOptions.Value.AutoCompactBudget -eq 100000) 'Enabled child options inherit compaction policy'
    Assert-Harness (($measurement -and $capturedOptions.Value.NoAutoCompactArchive -and -not $capturedOptions.Value.ContainsKey('AutoCompactArchivePath')) -or
        (-not $measurement -and $capturedOptions.Value.AutoCompactArchivePath -eq '.agents/harness/compaction')) 'Child options preserve measurement mode or unresolved archive root'
}
$isolatedOne = New-CompactFixtureContext -Budget 4000 -ArchiveRoot 'shared-archive-root'
$isolatedTwo = New-CompactFixtureContext -Budget 4000 -ArchiveRoot 'shared-archive-root'
$one = Invoke-CompactFixture (New-CompactFixtureHistory -Spans 1) $isolatedOne
$two = Invoke-CompactFixture (New-CompactFixtureHistory -Spans 1) $isolatedTwo
Assert-Harness ($one.Changed -and $two.Changed -and [IO.Path]::GetDirectoryName($one.ArchivePath) -cne [IO.Path]::GetDirectoryName($two.ArchivePath)) 'Invocations sharing an archive root keep independent session directories'

# One-turn attachments remain placeholders during continuation without needing media compaction.
$savedCompactHost = & $module { ${function:Read-Host} }
try {
    & $module {
        $script:CompactReplies = [Collections.Generic.Queue[string]]::new()
        function script:Read-Host { param($Prompt) if ($script:CompactReplies.Count) { $script:CompactReplies.Dequeue() } else { 'exit' } }
    }
    $continuationImage = Join-Path $compactRoot 'synthetic.png'
    [IO.File]::WriteAllBytes($continuationImage, [byte[]]::new(9000))
    $continueOptions = $compactOptions.Clone(); $continueOptions.NoCompletionPrompt = $false
    $continueBudget = $initialRequest.Body.messages[0].content.Length + 16000
    & $module { $script:CompactReplies.Enqueue(('Continue instructions ' + ('c' * 10000))); $script:CompactReplies.Enqueue('exit') }
    Set-HarnessResponses @((New-HarnessResponse 'first task complete'), (New-HarnessResponse 'continuation complete'))
    $continuedCompact = Invoke-AgentHarness 'First media task' @continueOptions -Attachments $continuationImage -AutoCompact -AutoCompactBudget $continueBudget -PassThru 3>$null 6>$null
    $continuedRequests = @(Get-HarnessRequests)
    Assert-Harness ($continuedRequests.Count -eq 2 -and $continuedRequests[0].Body.messages[1].content[1].type -ceq 'image_url' -and $continuedRequests[1].Body.messages[1].content[1].text -like '`[image: synthetic.png*') 'Continuation retains the placeholder after the original media was sent once'
    Assert-Harness ($continuedCompact.RawMessages[1].content[1].text -like '`[image: synthetic.png*' -and $continuedCompact.CompactedMedia -eq 0 -and $continuedCompact.Compactions -eq 0) 'One-turn media leaves placeholders in raw history without creating compaction archives'

    # A skill-prompt refresh and guidance are both visible to the one preflight.
    $refreshTools = @{ refresh = @{ Script = {
        param($a, $ctx)
        [IO.File]::WriteAllText((Join-Path $ctx.Root 'AGENTS.md'), ('Synthetic refreshed instructions ' + ('s' * 16000)))
        $ctx.SkillPromptDirty = $true
        $ctx.ApprovalFeedback = 'Synthetic approval guidance'
        't' * 8000
    } } }
    $refreshOptions = $compactOptions.Clone(); $refreshOptions.NoAgentsFile = $false
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall refresh))), (New-HarnessResponse 'refreshed complete'))
    $refreshed = Invoke-AgentHarness 'Refresh instructions' @refreshOptions -Tools $refreshTools -AutoCompact -AutoCompactBudget ($continueBudget - 4000) -PassThru 3>$null
    $refreshedRequest = @(Get-HarnessRequests)[1]
    Assert-Harness ($refreshed.Compactions -eq 1 -and $refreshedRequest.Body.messages[0].content.Contains('Synthetic refreshed instructions') -and $refreshedRequest.Body.messages[-1].content -ceq 'Synthetic approval guidance') 'Single preflight includes refreshed system prompt and appended approval guidance'
    Assert-Harness ($refreshedRequest.Body.messages[-2].content -like '[[]compacted tool output:*') 'System growth triggers retirement after all results and guidance are appended'
}
finally {
    if (Test-Path -LiteralPath (Join-Path $compactRoot 'AGENTS.md')) { [IO.File]::Delete((Join-Path $compactRoot 'AGENTS.md')) }
    & $module { param($saved) if ($saved) { Set-Item Function:script:Read-Host -Value $saved } else { Remove-Item Function:script:Read-Host -ErrorAction SilentlyContinue } } $savedCompactHost
}
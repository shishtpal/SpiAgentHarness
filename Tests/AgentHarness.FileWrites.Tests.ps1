# Synthetic file writes through real handlers, plus mocked completed provider responses.
$writeRoot = Join-Path $fixture 'file-write-tests'
$null = New-Item -ItemType Directory -Path $writeRoot -Force
$fileContext = @{ Root = $writeRoot; Quiet = $true; YOLO = $true; NoPromptSound = $true }

function Invoke-FileFixtureTool {
    param([string]$Name, [object]$Arguments, [hashtable]$Context = $fileContext, [string]$Preference = 'Stop', [int]$OutputLimit = 8000)
    & $module {
        param($name, $arguments, $context, $preference, $limit)
        $ErrorActionPreference = $preference
        $table = Get-AgentHarnessBuiltinTools -AllowSkills:$false -AllowShell:$false -AllowSubAgents:$false
        $call = @{ id = 'synthetic_write'; function = @{ name = $name; arguments = (ConvertTo-Json -InputObject $arguments -Compress -Depth 20) } }
        Invoke-AgentHarnessToolCall -Call $call -ToolTable $table -Context $context -MaxOutputChars $limit
    } $Name $Arguments $Context $Preference $OutputLimit
}

function Get-FileFixtureJson {
    param([string]$Name, [hashtable]$Arguments, [hashtable]$Context = $fileContext)
    $result = Invoke-FileFixtureTool $Name $Arguments $Context
    Assert-Harness ($result.content -notlike 'ERROR:*') "$Name succeeds: $($result.content)"
    ConvertFrom-Json -InputObject $result.content -AsHashtable
}

function Get-SyntheticHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

try {
    $target = Join-Path $writeRoot 'target.txt'
    foreach ($preference in 'Continue', 'Stop') {
        foreach ($invalid in @(
            @{ path = 'target.txt' }, @{ path = 'target.txt'; content = $null },
            @{ path = 'target.txt'; content = 42 }, @{ path = 'target.txt'; content = $true },
            @{ path = 'target.txt'; content = @() }, @{ path = 'target.txt'; content = @{} },
            @{ path = ' '; content = 'x' }, @{ path = 42; content = 'x' },
            @{ path = 'target.txt'; content = 'x'; other = 1 }, @{ Path = 'target.txt'; content = 'x' },
            @{ path = '../outside.txt'; content = 'x' }, @{ path = '.'; content = 'x' },
            @{ path = 'target.txt'; content = 'x'; expected_bytes = 2 },
            @{ path = 'target.txt'; content = 'x'; expected_bytes = 1.0 },
            @{ path = 'target.txt'; content = 'x'; expected_sha256 = ('0' * 64) }
        )) {
            [IO.File]::WriteAllText($target, 'keep original')
            $result = Invoke-FileFixtureTool write_file $invalid -Preference $preference
            Assert-Harness ($result.content -like 'ERROR:*' -and [IO.File]::ReadAllText($target) -ceq 'keep original') "Invalid write preserves original under $preference"
        }
    }
    $texts = @('', 'no newline', "LF`n", "CRLF`r`n", "mixed`r`nline`nend", ('quote " and slash \ ' + [char]0x03A9 + [char]0x4E2D + [char]::ConvertFromUtf32(0x1F30D)))
    foreach ($text in $texts) {
        $expected = [Text.Encoding]::UTF8.GetBytes($text)
        $result = Invoke-FileFixtureTool write_file @{ path = 'target.txt'; content = $text; expected_bytes = $expected.Length; expected_sha256 = (Get-SyntheticHash $expected) }
        Assert-Harness ($result.content -like 'Wrote*verified.' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToBase64String($expected)) 'Whole-file writes preserve exact supplied UTF-8 bytes'
    }
    foreach ($size in 16000, 17000, 102400, 1048576) {
        $content = 'a' * $size
        $result = Invoke-FileFixtureTool write_file @{ path = 'large.txt'; content = $content; expected_bytes = $size }
        Assert-Harness ($result.content -like 'Wrote*' -and (Get-Item -LiteralPath (Join-Path $writeRoot 'large.txt')).Length -eq $size) "Inline write supports $size bytes exactly"
    }
    Assert-HarnessThrows {
        & $module { param($ctx) Invoke-AgentHarnessFileWrite -Context $ctx -Arguments @{ path = 'surrogate.txt'; content = [string][char]0xD800 } } $fileContext
    } '*Unable to translate Unicode character*'
    Assert-Harness (-not (Test-Path -LiteralPath (Join-Path $writeRoot 'surrogate.txt'))) 'Invalid surrogate never creates a destination'

    [IO.File]::WriteAllText($target, 'read-only original')
    [IO.File]::SetAttributes($target, [IO.FileAttributes]::ReadOnly)
    try {
        $result = Invoke-FileFixtureTool write_file @{ path = 'target.txt'; content = 'replacement' }
        Assert-Harness ($result.content -like 'ERROR:*read-only*' -and [IO.File]::ReadAllText($target) -ceq 'read-only original') 'Read-only destination is rejected before save'
    }
    finally { [IO.File]::SetAttributes($target, [IO.FileAttributes]::Normal) }
    if ($IsWindows) {
        $junction = Join-Path $writeRoot 'linked-parent'
        $realParent = Join-Path $writeRoot 'real-parent'
        $null = New-Item -ItemType Directory -Path $realParent
        $null = New-Item -ItemType Junction -Path $junction -Target $realParent
        try {
            $result = Invoke-FileFixtureTool write_file @{ path = 'linked-parent/new.txt'; content = 'replacement' }
            Assert-Harness ($result.content -like 'ERROR:*reparse*' -and -not (Test-Path -LiteralPath (Join-Path $realParent 'new.txt'))) 'New files cannot traverse junction ancestors'
            $result = Invoke-FileFixtureTool write_file @{ path = 'target.txt:stream'; content = 'replacement' }
            Assert-Harness ($result.content -like 'ERROR:*alternate data streams*') 'Windows alternate data streams are rejected'
        }
        finally { [IO.Directory]::Delete($junction) }
    }

    $savedReadHost = & $module { if (Test-Path Function:Read-Host) { ${function:Read-Host} } }
    try {
        & $module {
            $script:FileReviewPrompts = [Collections.Generic.List[string]]::new()
            $script:FileReviewReplies = [Collections.Generic.Queue[string]]::new()
            foreach ($reply in '', '', 'y') { $script:FileReviewReplies.Enqueue($reply) }
            function script:Read-Host { param($Prompt) $script:FileReviewPrompts.Add($Prompt); $script:FileReviewReplies.Dequeue() }
        }
        $reviewContext = @{ Root = $writeRoot; Quiet = $true; YOLO = $false; NoPromptSound = $true }
        $reviewInfo = @()
        $result = Invoke-FileFixtureTool write_file @{ path = 'reviewed.txt'; content = ('x' * 20001) } $reviewContext -InformationVariable reviewInfo 6>$null
        Assert-Harness ($result.content -like 'Wrote*' -and (& $module { $script:FileReviewPrompts.Count }) -eq 3 -and (Get-Item -LiteralPath (Join-Path $writeRoot 'reviewed.txt')).Length -eq 20001) 'Large Quiet write reviews all pages before final approval'
        & $module { $script:FileReviewReplies.Enqueue('use a smaller candidate') }
        $result = Invoke-FileFixtureTool write_file @{ path = 'page-denied/new.txt'; content = ('x' * 20001) } $reviewContext 6>$null
        Assert-Harness ($result.content -like 'ERROR:*denied*' -and $reviewContext.ApprovalFeedback -ceq 'use a smaller candidate' -and -not (Test-Path -LiteralPath (Join-Path $writeRoot 'page-denied'))) 'Guidance during paged review cancels without creating parent folders'
    }
    finally {
        & $module { param($saved) if ($saved) { Set-Item Function:script:Read-Host $saved } else { Remove-Item Function:script:Read-Host } } $savedReadHost
    }

    # Approval, races and injected failures use the real save helper with fixture-scoped mocks.
    $saveConfirm = & $module { ${function:Confirm-AgentHarnessFileWrite} }
    $saveAssert = & $module { ${function:Assert-AgentHarnessWriteDestination} }
    $saveDestination = & $module { ${function:Get-AgentHarnessWriteDestination} }
    try {
        & $module { function script:Confirm-AgentHarnessFileWrite { param($Context) $false } }
        $result = Invoke-FileFixtureTool write_file @{ path = 'denied/new.txt'; content = 'x' }
        Assert-Harness ($result.content -like 'ERROR:*denied*' -and -not (Test-Path -LiteralPath (Join-Path $writeRoot 'denied'))) 'Denied writes create no destination directories'
        [IO.File]::WriteAllText($target, 'original')
        & $module {
            function script:Confirm-AgentHarnessFileWrite { param($Context, $Path) [IO.File]::WriteAllText((Join-Path $Context.Root $Path), 'external change'); $true }
        }
        $result = Invoke-FileFixtureTool write_file @{ path = 'target.txt'; content = 'candidate' }
        Assert-Harness ($result.content -like 'ERROR:*changed*' -and [IO.File]::ReadAllText($target) -ceq 'external change') 'Change during approval is preserved'
        $result = Invoke-FileFixtureTool write_file @{ path = 'appeared.txt'; content = 'candidate' }
        Assert-Harness ($result.content -like 'ERROR:*changed*' -and [IO.File]::ReadAllText((Join-Path $writeRoot 'appeared.txt')) -ceq 'external change') 'Destination appearing during approval is preserved'
        & $module { function script:Confirm-AgentHarnessFileWrite { $true } }
        & $module {
            param($saved)
            $script:SavedWriteAssert = $saved
            function script:Assert-AgentHarnessWriteDestination {
                param($Context, $Path, $Snapshot)
                & $script:SavedWriteAssert -Context $Context -Path $Path -Snapshot $Snapshot
                if (@(Get-ChildItem -LiteralPath $Context.Root -Filter '.agentharness-*.tmp' -Recurse).Count) { throw 'Synthetic replacement failure.' }
            }
        } $saveAssert
        $result = Invoke-FileFixtureTool write_file @{ path = 'new-parent/file.txt'; content = 'candidate' }
        Assert-Harness ($result.content -like 'ERROR:*Synthetic replacement failure*' -and -not (Test-Path -LiteralPath (Join-Path $writeRoot 'new-parent'))) 'Failed staged save cleans owned files and new empty directories'
        & $module {
            param($savedAssert, $savedDestination)
            Set-Item Function:script:Assert-AgentHarnessWriteDestination $savedAssert
            $script:SavedWriteDestination = $savedDestination
            function script:Get-AgentHarnessWriteDestination {
                param($Root, $Path)
                if ($Path -eq 'uncertain.txt' -and [IO.File]::Exists((Join-Path $Root $Path))) { throw 'Synthetic post-save inspection failure.' }
                & $script:SavedWriteDestination -Root $Root -Path $Path
            }
        } $saveAssert $saveDestination
        $result = Invoke-FileFixtureTool write_file @{ path = 'uncertain.txt'; content = 'actually saved' }
        Assert-Harness ($result.content -like 'ERROR:*may already have changed*' -and [IO.File]::ReadAllText((Join-Path $writeRoot 'uncertain.txt')) -ceq 'actually saved') 'Post-save failure reports uncertain outcome instead of claiming rollback'
    }
    finally {
        & $module { param($confirm, $assert, $destination) Set-Item Function:script:Confirm-AgentHarnessFileWrite $confirm; Set-Item Function:script:Assert-AgentHarnessWriteDestination $assert; Set-Item Function:script:Get-AgentHarnessWriteDestination $destination } $saveConfirm $saveAssert $saveDestination
    }

    $content = (('line "\ ' + [char]0x03A9 + [char]0x4E2D + "`r`n") * 12000)
    $expected = [Text.Encoding]::UTF8.GetBytes($content)
    $begin = Get-FileFixtureJson begin_file_write @{ path = 'chunked/new.txt'; expected_bytes = $expected.Length; expected_sha256 = (Get-SyntheticHash $expected) }
    $id = $begin.write_id
    if ($IsWindows) { Assert-Harness ((Get-Acl -LiteralPath $fileContext.FileWriteState.StagingRoot).AreAccessRulesProtected) 'Staging directory has a private, noninherited ACL' }
    Assert-Harness (-not (Test-Path -LiteralPath (Join-Path $writeRoot 'chunked'))) 'Begin does not create the destination parent'
    $offset = 0
    $firstArguments = $null
    for ($index = 0; $index -lt $content.Length; $index += 1000) {
        $part = $content.Substring($index, [Math]::Min(1000, $content.Length - $index))
        $chunkArguments = @{ write_id = $id; offset_bytes = $offset; content = $part }
        $ack = Get-FileFixtureJson write_file_chunk $chunkArguments
        $offset += [Text.Encoding]::UTF8.GetByteCount($part)
        Assert-Harness ($ack.next_offset_bytes -eq $offset) 'Chunk acknowledgement uses UTF-8 byte offsets'
        if (-not $firstArguments) { $firstArguments = $chunkArguments; $firstReceipt = $ack }
    }
    $retry = Get-FileFixtureJson write_file_chunk $firstArguments
    Assert-Harness ($retry.next_offset_bytes -eq $firstReceipt.next_offset_bytes) 'Exact duplicate chunk returns original acknowledgement'
    $result = Invoke-FileFixtureTool write_file_chunk @{ write_id = $id; offset_bytes = 0; content = ('!' * $firstArguments.content.Length) }
    Assert-Harness ($result.content -like 'ERROR:*Conflicting retry*') 'Conflicting chunk retry is rejected'
    $commit = Get-FileFixtureJson commit_file_write @{ write_id = $id }
    $chunkPath = Join-Path $writeRoot 'chunked/new.txt'
    Assert-Harness ($commit.state -eq 'committed' -and $commit.bytes -eq $expected.Length -and (Get-SyntheticHash ([IO.File]::ReadAllBytes($chunkPath))) -ceq (Get-SyntheticHash $expected)) 'Large Unicode chunked write commits exact independently checked bytes'
    [IO.File]::WriteAllText($chunkPath, 'external change after commit')
    $again = Get-FileFixtureJson commit_file_write @{ write_id = $id }
    Assert-Harness ($again.sha256 -eq $commit.sha256 -and [IO.File]::ReadAllText($chunkPath) -ceq 'external change after commit') 'Repeated commit returns receipt without rewriting'
    $status = Get-FileFixtureJson get_file_write_status @{ write_id = $id }
    Assert-Harness ($status.receipt.bytes -eq $expected.Length -and $status.state -eq 'committed') 'Status retains terminal receipt'
    $result = Invoke-FileFixtureTool write_file_chunk $firstArguments
    Assert-Harness ($result.content -like 'ERROR:*committed*') 'Terminal sessions reject appends'

    $begin = Get-FileFixtureJson begin_file_write @{ path = 'incomplete.txt'; expected_bytes = 3 }
    $id = $begin.write_id
    $result = Invoke-FileFixtureTool commit_file_write @{ write_id = $id }
    Assert-Harness ($result.content -like 'ERROR:*Incomplete file*' -and -not (Test-Path -LiteralPath (Join-Path $writeRoot 'incomplete.txt'))) 'Incomplete commit preserves destination and stays open'
    foreach ($arguments in @(@{ write_id = $id; offset_bytes = 1; content = 'a' }, @{ write_id = $id; offset_bytes = 0; content = '' }, @{ write_id = $id; offset_bytes = 0; content = '1234' }, @{ write_id = $id; offset_bytes = 0; content = ('a' * 5000) })) {
        $result = Invoke-FileFixtureTool write_file_chunk $arguments
        Assert-Harness ($result.content -like 'ERROR:*') 'Gapped, empty, exceeding declared size and oversized chunks are rejected'
    }
    $null = Get-FileFixtureJson write_file_chunk @{ write_id = $id; offset_bytes = 0; content = 'abc' }
    $null = Get-FileFixtureJson commit_file_write @{ write_id = $id }
    $begin = Get-FileFixtureJson begin_file_write @{ path = 'empty.txt'; expected_bytes = 0 }
    $receipt = Get-FileFixtureJson commit_file_write @{ write_id = $begin.write_id }
    Assert-Harness ($receipt.bytes -eq 0 -and (Get-Item -LiteralPath (Join-Path $writeRoot 'empty.txt')).Length -eq 0) 'Zero-byte staged write commits with no chunks'
    $begin = Get-FileFixtureJson begin_file_write @{ path = 'hash.txt'; expected_bytes = 3; expected_sha256 = ('0' * 64) }
    $null = Get-FileFixtureJson write_file_chunk @{ write_id = $begin.write_id; offset_bytes = 0; content = 'abc' }
    $result = Invoke-FileFixtureTool commit_file_write @{ write_id = $begin.write_id }
    Assert-Harness ($result.content -like 'ERROR:*SHA-256*' -and -not (Test-Path -LiteralPath (Join-Path $writeRoot 'hash.txt'))) 'Declared hash mismatch leaves destination untouched'
    $null = Get-FileFixtureJson abort_file_write @{ write_id = $begin.write_id }
    $abort = Get-FileFixtureJson abort_file_write @{ write_id = $begin.write_id }
    Assert-Harness ($abort.state -eq 'aborted') 'Abort is idempotent'
    $begin = Get-FileFixtureJson begin_file_write @{ path = 'compacted-session.txt'; expected_bytes = 3 }
    $null = Get-FileFixtureJson write_file_chunk @{ write_id = $begin.write_id; offset_bytes = 0; content = 'abc' }
    $compaction = & $module {
        param($ctx)
        $ctx.ContextSessionId = [guid]::NewGuid().ToString('N')
        $ctx.AutoCompact = New-AgentHarnessCompactionState -Enabled $true -Budget 4000
        $messages = [Collections.Generic.List[object]]::new()
        $messages.Add(@{ role = 'system'; content = 'Synthetic system.' })
        $messages.Add(@{ role = 'user'; content = 'Synthetic task.' })
        $messages.Add(@{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'compact_write_check'; type = 'function'; function = @{ name = 'inspect'; arguments = '{}' } }) })
        $messages.Add(@{ role = 'tool'; name = 'inspect'; tool_call_id = 'compact_write_check'; content = ('x' * 20000) })
        Invoke-AgentHarnessCompaction -Messages $messages -Context $ctx -Provider TestA -Model synthetic
    } $fileContext
    $status = Get-FileFixtureJson get_file_write_status @{ write_id = $begin.write_id }
    Assert-Harness ($compaction.Changed -and $status.state -eq 'open' -and $status.received_bytes -eq 3) 'Actual archive-backed compaction preserves the live file-write registry'
    $null = Get-FileFixtureJson commit_file_write @{ write_id = $begin.write_id }
    $foreign = @{ Root = $writeRoot; Quiet = $true; YOLO = $true }
    $result = Invoke-FileFixtureTool get_file_write_status @{ write_id = $id } $foreign
    Assert-Harness ($result.content -like 'ERROR:*Unknown write_id*') 'Write IDs are invocation-owned'

    $begin = Get-FileFixtureJson begin_file_write @{ path = 'tampered.txt'; expected_bytes = 3 }
    $null = Get-FileFixtureJson write_file_chunk @{ write_id = $begin.write_id; offset_bytes = 0; content = 'abc' }
    [IO.File]::WriteAllText($fileContext.FileWriteState.Sessions[$begin.write_id].Stage, 'xyz')
    $result = Invoke-FileFixtureTool commit_file_write @{ write_id = $begin.write_id }
    $status = Get-FileFixtureJson get_file_write_status @{ write_id = $begin.write_id }
    Assert-Harness ($result.content -like 'ERROR:*integrity*' -and $status.state -eq 'failed' -and -not (Test-Path -LiteralPath (Join-Path $writeRoot 'tampered.txt'))) 'Locally recorded chunk hashes detect same-size staging tampering without a model-supplied checksum'
    $emoji = [char]::ConvertFromUtf32(0x1F30D)
    $begin = Get-FileFixtureJson begin_file_write @{ path = 'emoji.txt'; expected_bytes = 4 }
    Assert-HarnessThrows {
        & $module { param($ctx,$id) Invoke-AgentHarnessFileWrite -Context $ctx -Name write_file_chunk -Arguments @{ write_id = $id; offset_bytes = 0; content = [string][char]0xD83C } } $fileContext $begin.write_id
    } '*Unable to translate Unicode character*'
    $ack = Get-FileFixtureJson write_file_chunk @{ write_id = $begin.write_id; offset_bytes = 0; content = $emoji }
    $null = Get-FileFixtureJson commit_file_write @{ write_id = $begin.write_id }
    Assert-Harness ($ack.next_offset_bytes -eq 4 -and [IO.File]::ReadAllText((Join-Path $writeRoot 'emoji.txt')) -ceq $emoji) 'Complete surrogate pair stages as four UTF-8 bytes'

    $quotaContext = @{ Root = $writeRoot; Quiet = $true; YOLO = $true; FileWriteState = (& $module { New-AgentHarnessFileWriteState -Options @{ MaxChunkBytes = 4; MaxFileBytes = 8; MaxStagedBytes = 8; MaxActiveSessions = 1; MaxReceipts = 2 } }) }
    $limited = Get-FileFixtureJson begin_file_write @{ path = 'quota.txt'; expected_bytes = 8 } $quotaContext
    $result = Invoke-FileFixtureTool begin_file_write @{ path = 'quota2.txt'; expected_bytes = 0 } $quotaContext
    Assert-Harness ($result.content -like 'ERROR:*session limit*') 'Active session quota enforced'
    $null = Get-FileFixtureJson abort_file_write @{ write_id = $limited.write_id } $quotaContext
    $limited = Get-FileFixtureJson begin_file_write @{ path = 'quota2.txt'; expected_bytes = 0 } $quotaContext
    $null = Get-FileFixtureJson abort_file_write @{ write_id = $limited.write_id } $quotaContext
    $result = Invoke-FileFixtureTool begin_file_write @{ path = 'quota3.txt'; expected_bytes = 0 } $quotaContext
    Assert-Harness ($result.content -like 'ERROR:*session limit*') 'Receipt bound rejects new sessions without evicting idempotency evidence'
    $stageRoot = $quotaContext.FileWriteState.StagingRoot
    & $module { param($ctx) Close-AgentHarnessFileWrites -Context $ctx } $quotaContext
    Assert-Harness (-not (Test-Path -LiteralPath $stageRoot)) 'Cleanup deletes only invocation-owned staging'
    foreach ($badOptions in @(@{ Unknown = 1 }, @{ MaxChunkBytes = 0 }, @{ MaxActiveSessions = 257 }, @{ MaxFileBytes = 8; MaxChunkBytes = 16 })) {
        Assert-HarnessThrows { & $module { param($options) New-AgentHarnessFileWriteState -Options $options } $badOptions } '*'
    }

    $result = Invoke-FileFixtureTool get_file_write_status @{ write_id = $id } -OutputLimit 20
    Assert-Harness ($result.content -like 'ERROR:*MaxToolOutputChars*' -and $result.content -notlike '*truncated*') 'Receipts and statuses fail explicitly rather than truncating JSON'
    $names = & $module { @(Get-AgentHarnessBuiltinTools -AllowWrite:$false -AllowSkills:$false -AllowShell:$false -AllowSubAgents:$false).Keys }
    Assert-Harness (@($names | Where-Object { $_ -in 'write_file','begin_file_write','write_file_chunk','get_file_write_status','commit_file_write','abort_file_write' }).Count -eq 0) 'Disabling writes hides the entire staged write workflow'

    $gateOptions = @{ Model = 'synthetic'; ChatUri = 'https://provider.invalid/chat'; WorkingDirectory = $writeRoot; NoAgentsFile = $true; NoBuiltinTools = $true; NoPromptHistory = $true; NoModelRecovery = $true; Quiet = $true }
    $counter = @{ Calls = 0 }
    $gateTools = @{ probe = @{ Script = { param($a,$ctx) $counter.Calls++; 'called' }.GetNewClosure() } }
    foreach ($mode in @($true, $false)) {
        foreach ($reason in 'length', 'content_filter', '', 'stop') {
            $response = New-HarnessResponse '' @((New-HarnessCall probe '{}'))
            $response.choices[0].finish_reason = $reason
            Set-HarnessResponses @($response)
            Assert-HarnessThrows { Invoke-AgentHarness 'invalid completion' @gateOptions -NoStream:$mode -Tools $gateTools } '*'
            Assert-Harness ($counter.Calls -eq 0 -and @(Get-HarnessRequests).Count -eq 1) 'Incomplete completed responses execute no tools and are not replayed'
        }
        foreach ($bad in @((New-HarnessCall probe '{'), (New-HarnessCall probe '[]'), (New-HarnessCall probe '{}' ''), (New-HarnessCall '' '{}'))) {
            Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall probe '{}'), $bad)))
            Assert-HarnessThrows { Invoke-AgentHarness 'invalid batch' @gateOptions -NoStream:$mode -Tools $gateTools } '*'
            Assert-Harness ($counter.Calls -eq 0) 'Malformed later call prevents earlier valid call from executing'
        }
        $call = New-HarnessCall probe '{}'
        Set-HarnessResponses @((New-HarnessResponse '' @($call, $call)))
        Assert-HarnessThrows { Invoke-AgentHarness 'duplicate IDs' @gateOptions -NoStream:$mode -Tools $gateTools } '*duplicate tool-call IDs*'
        $response = New-HarnessResponse
        $response.choices[0].message.tool_calls = @($null)
        Set-HarnessResponses @($response)
        Assert-HarnessThrows { Invoke-AgentHarness 'null call' @gateOptions -NoStream:$mode -Tools $gateTools } '*null tool call*'
        $response = New-HarnessResponse '' @((New-HarnessCall probe '{}'))
        $response.choices[0].message | Add-Member -NotePropertyName refusal -NotePropertyValue 'synthetic refusal'
        Set-HarnessResponses @($response)
        Assert-HarnessThrows { Invoke-AgentHarness 'refused call' @gateOptions -NoStream:$mode -Tools $gateTools } '*refused*'
        $response = New-HarnessResponse '' @((New-HarnessCall probe '{}'))
        $response | Add-Member -NotePropertyName error -NotePropertyValue ([pscustomobject]@{ code = 503; message = 'synthetic error alongside calls' })
        Set-HarnessResponses @($response)
        Assert-HarnessThrows { Invoke-AgentHarness 'mixed error and output' @gateOptions -NoStream:$mode -Tools $gateTools } '*error alongside assistant output*'
        Assert-Harness ($counter.Calls -eq 0 -and @(Get-HarnessRequests).Count -eq 1) 'Mixed error and assistant output cannot execute or replay'
    }
    $gateOptions.Remove('NoBuiltinTools')
    # A staged write survives a normal task continuation, using actual returned IDs and offsets.
    $workflowContent = '0123456789abcdef' * 7000
    $workflow = @{ Id = $null; Continued = $false }
    $makeResponse = ${function:New-HarnessResponse}
    $makeCall = ${function:New-HarnessCall}
    $workflowCallback = {
        param($body)
        $last = $body.messages[-1]
        $offset = 0
        if ($last.role -eq 'tool') {
            $ack = ConvertFrom-Json -InputObject $last.content
            if (-not $workflow.Id) {
                $workflow.Id = $ack.write_id
                return & $makeResponse 'Staging is open; continue to finish it.'
            }
            if ($ack.state -eq 'committed') { return & $makeResponse 'Chunked workflow complete.' }
            $offset = [int]$ack.next_offset_bytes
        }
        else { $workflow.Continued = $true }
        $call = if ($offset -lt $workflowContent.Length) {
            & $makeCall write_file_chunk @{ write_id = $workflow.Id; offset_bytes = $offset; content = $workflowContent.Substring($offset, [Math]::Min(4096, $workflowContent.Length - $offset)) }
        }
        else { & $makeCall commit_file_write @{ write_id = $workflow.Id } }
        & $makeResponse '' @($call)
    }.GetNewClosure()
    $workflowResponses = [Collections.Generic.List[object]]::new()
    $workflowResponses.Add((New-HarnessResponse '' @((New-HarnessCall begin_file_write (@{ path = 'continued-chunked.txt'; expected_bytes = $workflowContent.Length } | ConvertTo-Json -Compress)))))
    for ($i = 0; $i -lt 40; $i++) { $workflowResponses.Add($workflowCallback) }
    Set-HarnessResponses $workflowResponses.ToArray()
    $savedReadHost = & $module { if (Test-Path Function:Read-Host) { ${function:Read-Host} } }
    try {
        & $module {
            $script:WriteContinuationReplies = [Collections.Generic.Queue[string]]::new()
            $script:WriteContinuationReplies.Enqueue('finish the staged file')
            $script:WriteContinuationReplies.Enqueue('exit')
            function script:Read-Host { param($Prompt) $script:WriteContinuationReplies.Dequeue() }
        }
        $null = Invoke-AgentHarness 'Begin a staged file' @gateOptions -YOLO -NoPromptSound -NoCompletionPrompt:$false 6>$null
        Assert-Harness ($workflow.Continued -and [IO.File]::ReadAllText((Join-Path $writeRoot 'continued-chunked.txt')) -ceq $workflowContent) 'Public chunked workflow preserves registry across task continuation and uses acknowledged offsets'
    }
    finally { & $module { param($saved) if ($saved) { Set-Item Function:script:Read-Host $saved } else { Remove-Item Function:script:Read-Host } } $savedReadHost }
    $sessionsBefore = $fileContext.FileWriteState.Sessions.Count
    $result = Invoke-FileFixtureTool begin_file_write @{ path = 'lost-id.txt'; expected_bytes = 0 } -OutputLimit 20
    Assert-Harness ($result.content -like 'ERROR:*' -and $fileContext.FileWriteState.Sessions.Count -eq $sessionsBefore) 'An output limit too small for the begin receipt cannot create an unreachable session'
    # Staging must be cleaned by the public invocation on every exit path.
    $capturedWrite = @{}
    $captureTool = @{ capture_write = @{ Script = { param($a,$ctx) $capturedWrite.Context = $ctx; $capturedWrite.StageRoot = $ctx.FileWriteState.StagingRoot; 'captured staging metadata' }.GetNewClosure() } }
    foreach ($exitKind in 'completed', 'failure', 'iteration_limit') {
        $responses = @((New-HarnessResponse '' @((New-HarnessCall begin_file_write '{"path":"cleanup-never.txt","expected_bytes":3}'), (New-HarnessCall capture_write '{}'))))
        if ($exitKind -eq 'completed') { $responses += New-HarnessResponse }
        if ($exitKind -eq 'failure') { $responses += New-HarnessApiError 400 }
        Set-HarnessResponses $responses
        if ($exitKind -eq 'failure') { Assert-HarnessThrows { Invoke-AgentHarness 'cleanup failed request' @gateOptions -Tools $captureTool } '*' }
        else { $null = Invoke-AgentHarness 'cleanup invocation' @gateOptions -Tools $captureTool -MaxIterations $(if ($exitKind -eq 'iteration_limit') { 1 } else { 3 }) -WarningAction SilentlyContinue }
        Assert-Harness ($capturedWrite.StageRoot -and -not (Test-Path -LiteralPath $capturedWrite.StageRoot) -and -not (Test-Path -LiteralPath (Join-Path $writeRoot 'cleanup-never.txt'))) "Public invocation cleans staging on $exitKind"
    }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall write_file '{"path":"diagnostic.txt","content":"synthetic private payload"}'))), (New-HarnessResponse))
    $diagnosticInfo = @()
    $null = Invoke-AgentHarness 'diagnostics' @gateOptions -YOLO -ToolPayloadDiagnostics -Quiet:$false -InformationVariable diagnosticInfo 6>$null
    $payloadLogs = @($diagnosticInfo | ForEach-Object { [string]$_.MessageData } | Where-Object { $_ -like 'Payload: *' })
    Assert-Harness ($payloadLogs.Count -ge 3 -and ($payloadLogs -join '') -notlike '*synthetic private payload*') 'Opt-in metadata diagnostics contain boundaries and no payload body'
    Set-HarnessResponses @((New-HarnessResponse))
    $diagnosticInfo = @()
    $null = Invoke-AgentHarness 'quiet diagnostics' @gateOptions -ToolPayloadDiagnostics -InformationVariable diagnosticInfo 6>$null
    Assert-Harness (@($diagnosticInfo | Where-Object { [string]$_.MessageData -like 'Payload: *' }).Count -eq 0) 'Quiet suppresses payload diagnostics'
}
finally {
    & $module { param($ctx) Close-AgentHarnessFileWrites -Context $ctx } $fileContext
}
# Dot-sourced by Invoke-AgentHarness.Tests.ps1 inside its isolated module fixture.
$editSavedPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
function Invoke-EditFixtureTool {
    param([object]$Arguments, [string]$Preference = 'Stop', [hashtable]$Context)
    if (-not $Context) { $Context = @{ Root = $fixture; YOLO = $true; Quiet = $true; NoPromptSound = $true } }
    $json = ConvertTo-Json -InputObject $Arguments -Depth 20 -Compress
    & $module {
        param($json, $context, $preference)
        $ErrorActionPreference = $preference
        Invoke-AgentHarnessToolCall -Call @{ id = 'edit_test'; function = @{ name = 'edit_file'; arguments = $json } } `
            -ToolTable (Get-AgentHarnessBuiltinTools) -Context $context
    } $json $Context $Preference
}

$editRoot = Join-Path $fixture 'edit-fixture'
$null = New-Item -ItemType Directory -Path $editRoot
$editPath = Join-Path $editRoot 'literal [file].txt'
$editRelative = 'edit-fixture/literal [file].txt'
$editArguments = @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = 'beta' }) }
$editOriginal = "header`r`nalpha`r`ntail"
[IO.File]::WriteAllText($editPath, $editOriginal)

$result = Invoke-EditFixtureTool $editArguments
Assert-Harness ($result.content -like 'Applied 1 edit(s)*' -and [IO.File]::ReadAllText($editPath) -ceq "header`r`nbeta`r`ntail") 'Exact edit preserves CRLF, no final newline, and literal square-bracket path'
$batchArguments = @{ path = $editRelative; edits = @(@{ old_text = 'beta'; new_text = 'BETA' }, @{ old_text = 'BETA'; new_text = '' }) }
$result = Invoke-EditFixtureTool $batchArguments
Assert-Harness ($result.content -like 'Applied 2 edit(s)*' -and [IO.File]::ReadAllText($editPath) -ceq "header`r`n`r`ntail") 'Edits apply sequentially in memory and empty new_text deletes a match'

$invalidEditArguments = @(
    $null, @(), @(@{ path = $editRelative }), @{},
    @{ path = $null; edits = @(@{ old_text = 'alpha'; new_text = 'beta' }) },
    @{ path = 2; edits = @(@{ old_text = 'alpha'; new_text = 'beta' }) },
    @{ path = ' '; edits = @(@{ old_text = 'alpha'; new_text = 'beta' }) },
    @{ path = $editRelative; edits = $null },
    @{ path = $editRelative; edits = @() },
    @{ path = $editRelative; edits = @{ old_text = 'alpha'; new_text = 'beta' } },
    @{ path = $editRelative; edits = @($null) },
    @{ path = $editRelative; edits = @(@()) },
    @{ path = $editRelative; edits = @('alpha') },
    @{ path = $editRelative; edits = @(@{ new_text = 'beta' }) },
    @{ path = $editRelative; edits = @(@{ old_text = ''; new_text = 'beta' }) },
    @{ path = $editRelative; edits = @(@{ old_text = 1; new_text = 'beta' }) },
    @{ path = $editRelative; edits = @(@{ old_text = 'alpha' }) },
    @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = $null }) },
    @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = @() }) },
    @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = 1 }) },
    @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = 'beta'; replace_all = $true }) },
    @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = 'beta' }); extra = $true },
    @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = "bad$([char]0)text" }) },
    @{ path = $editRelative; edits = @(1..101 | ForEach-Object { @{ old_text = 'alpha'; new_text = 'beta' } }) }
)
foreach ($preference in 'Continue', 'Stop') {
    [IO.File]::WriteAllText($editPath, $editOriginal)
    foreach ($invalidArguments in $invalidEditArguments) {
        $result = Invoke-EditFixtureTool -Arguments $invalidArguments -Preference $preference
        Assert-Harness ($result.content -like 'ERROR:*') "Malformed edit arguments return tool errors under $preference"
    }
    foreach ($oldText in 'missing', 'ALPHA', "header`nalpha", 'a') {
        $result = Invoke-EditFixtureTool @{ path = $editRelative; edits = @(@{ old_text = $oldText; new_text = 'beta' }) } -Preference $preference
        Assert-Harness ($result.content -like 'ERROR: Edit 1:*') "Missing, case-mismatched, newline-mismatched or ambiguous text is rejected under $preference"
    }
    $result = Invoke-EditFixtureTool @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = 'beta' }, @{ old_text = 'missing'; new_text = 'other' }) } -Preference $preference
    Assert-Harness ($result.content -like 'ERROR: Edit 2:*' -and [IO.File]::ReadAllText($editPath) -ceq $editOriginal) 'Later edit failure leaves all original bytes intact'
    $result = Invoke-EditFixtureTool @{ path = 'edit-fixture/missing/new.txt'; edits = $editArguments.edits } -Preference $preference
    Assert-Harness ($result.content -like 'ERROR:*' -and -not [IO.Directory]::Exists((Join-Path $editRoot 'missing'))) 'Editing a missing file creates neither file nor parent directory'
    $result = Invoke-EditFixtureTool @{ path = 'edit-fixture'; edits = $editArguments.edits } -Preference $preference
    Assert-Harness ($result.content -like 'ERROR:*existing local text file*') 'Directories are rejected'
}
[IO.File]::WriteAllText($editPath, 'aaa')
$result = Invoke-EditFixtureTool @{ path = $editRelative; edits = @(@{ old_text = 'aa'; new_text = 'b' }) }
Assert-Harness ($result.content -like 'ERROR:*matches more than once*' -and [IO.File]::ReadAllText($editPath) -ceq 'aaa') 'Overlapping matches are ambiguous'

$encodings = @(
    [Text.UTF8Encoding]::new($false, $true), [Text.UTF8Encoding]::new($true, $true),
    [Text.UnicodeEncoding]::new($false, $true, $true), [Text.UnicodeEncoding]::new($true, $true, $true),
    [Text.UTF32Encoding]::new($false, $true, $true), [Text.UTF32Encoding]::new($true, $true, $true)
)
foreach ($encoding in $encodings) {
    foreach ($ending in '', "`n", "`r`n", "`r") {
        $originalText = "snowman $([char]0x2603)`r`nalpha`nmixed`rline" + $ending
        $expectedText = $originalText.Replace('alpha', "$([char]0x03B2)eta")
        [IO.File]::WriteAllBytes($editPath, [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($originalText)))
        $result = Invoke-EditFixtureTool @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = "$([char]0x03B2)eta" }) }
        $expected = [Convert]::ToBase64String([byte[]]($encoding.GetPreamble() + $encoding.GetBytes($expectedText)))
        Assert-Harness ($result.content -like 'Applied*' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($editPath)) -ceq $expected) 'Unicode encoding, BOM, mixed newlines and EOF state survive byte-for-byte outside the edit'
    }
}
[IO.File]::WriteAllText($editPath, 'alpha')
$result = Invoke-EditFixtureTool @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = '' }) }
Assert-Harness ($result.content -like 'Applied*' -and [IO.File]::ReadAllBytes($editPath).Length -eq 0) 'Deleting an entire UTF-8 file yields zero bytes without an added newline'

foreach ($invalidBytes in @([byte[]]@(0xC3, 0x28), [byte[]]@(0xFF, 0xFE, 0x61), [byte[]]@(97, 0, 98), [byte[]]@(97, 27, 98))) {
    [IO.File]::WriteAllBytes($editPath, $invalidBytes)
    $result = Invoke-EditFixtureTool $editArguments
    Assert-Harness ($result.content -like 'ERROR:*' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($editPath)) -ceq [Convert]::ToBase64String($invalidBytes)) 'Invalid encodings, NULs and binary control characters fail without modifying bytes'
}
[IO.File]::WriteAllText($editPath, ('a' * (1MB + 1)))
$result = Invoke-EditFixtureTool $editArguments
Assert-Harness ($result.content -like 'ERROR:*up to 1 MiB*') 'Oversized source files are rejected'
[IO.File]::WriteAllText($editPath, 'alpha')
$result = Invoke-EditFixtureTool @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = ('b' * (1MB + 1)) }) }
Assert-Harness ($result.content -like 'ERROR:*exceed*' -and [IO.File]::ReadAllText($editPath) -ceq 'alpha') 'Oversized edit strings are rejected'
$result = Invoke-EditFixtureTool @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = ('b' * 1MB) }, @{ old_text = 'bb'; new_text = 'c' }) }
Assert-Harness ($result.content -like 'ERROR:*' -and [IO.File]::ReadAllText($editPath) -ceq 'alpha') 'Failed large batches preserve the original'
[IO.File]::WriteAllText($editPath, 'prefix alpha')
$result = Invoke-EditFixtureTool @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = ('b' * 1MB) }) }
Assert-Harness ($result.content -like 'ERROR:*resulting file exceeds*') 'Encoded candidate size is bounded as well as input size'
[IO.File]::SetAttributes($editPath, [IO.FileAttributes]::ReadOnly)
try {
    $result = Invoke-EditFixtureTool $editArguments
    Assert-Harness ($result.content -like 'ERROR:*read-only*') 'Read-only files are rejected'
}
finally { [IO.File]::SetAttributes($editPath, [IO.FileAttributes]::Normal) }

# Escapes are tested against a smaller root; every synthetic file stays inside the fixture.
[IO.File]::WriteAllText($editPath, 'alpha')
$confined = @{ Root = $editRoot; Quiet = $true; YOLO = $true; NoPromptSound = $true }
foreach ($escape in '../outside.txt', (Join-Path $fixture 'outside.txt')) {
    $result = Invoke-EditFixtureTool @{ path = $escape; edits = $editArguments.edits } -Context $confined
    Assert-Harness ($result.content -like 'ERROR: Path escapes*') 'Relative and absolute paths outside the working root are rejected'
}
if ($IsWindows) {
    $result = Invoke-EditFixtureTool @{ path = 'literal [file].txt:stream'; edits = $editArguments.edits } -Context $confined
    Assert-Harness ($result.content -like 'ERROR:*alternate data streams*') 'Windows alternate data streams are rejected'
}
$outsideDirectory = Join-Path $fixture 'edit-outside'
$null = New-Item -ItemType Directory -Path $outsideDirectory
[IO.File]::WriteAllText((Join-Path $outsideDirectory 'outside.txt'), 'alpha')
$editLink = Join-Path $editRoot 'linked'
$linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
$null = New-Item -ItemType $linkType -Path $editLink -Target $outsideDirectory
try {
    $result = Invoke-EditFixtureTool @{ path = 'linked/outside.txt'; edits = $editArguments.edits } -Context $confined
    Assert-Harness ($result.content -like 'ERROR:*reparse points*') 'A directory link inside the working root is rejected'
    $linkedRoot = @{ Root = $editLink; Quiet = $true; YOLO = $true; NoPromptSound = $true }
    $result = Invoke-EditFixtureTool @{ path = 'outside.txt'; edits = $editArguments.edits } -Context $linkedRoot
    Assert-Harness ($result.content -like 'ERROR:*reparse points*' -and [IO.File]::ReadAllText((Join-Path $outsideDirectory 'outside.txt')) -ceq 'alpha') 'A linked working root is rejected without changing its target'
}
finally { [IO.Directory]::Delete($editLink) }

$savedEditReadHost = & $module { ${function:Read-Host} }
try {
    & $module {
        $script:EditReplies = [Collections.Generic.Queue[object]]::new()
        $script:EditPromptCount = 0
        function script:Read-Host {
            param($Prompt)
            $script:EditPromptCount++
            if (-not $script:EditReplies.Count) { throw 'Unexpected edit confirmation.' }
            $reply = $script:EditReplies.Dequeue()
            if ($reply -is [scriptblock]) { return (& $reply) }
            $reply
        }
    }
    $editContext = @{ Root = $fixture; Quiet = $true; YOLO = $false; NoPromptSound = $true }
    foreach ($reply in 'n', '') {
        & $module { param($reply) $script:EditReplies.Enqueue($reply) } $reply
        $result = Invoke-EditFixtureTool $editArguments -Context $editContext 6>$null
        Assert-Harness ($result.content -like 'ERROR: the user denied this edit*' -and [IO.File]::ReadAllText($editPath) -ceq 'alpha') 'Denied edit leaves the original file intact'
    }
    [IO.File]::WriteAllText($editPath, "header`r`nalpha`r`ntail")
    $editCall = New-HarnessCall edit_file (ConvertTo-Json -InputObject $editArguments -Depth 10 -Compress) 'edit_approved'
    & $module { $script:EditReplies.Enqueue(' YES ') }
    Set-HarnessResponses @((New-HarnessResponse '' @($editCall)), (New-HarnessResponse 'edited'))
    $editInfo = @()
    $approvedEdit = Invoke-AgentHarness 'edit a file' @withBuiltins -NoPromptSound -PassThru -InformationVariable editInfo 6>$null
    $previewText = $editInfo.MessageData.Message -join "`n"
    Assert-Harness ($approvedEdit.Answer -eq 'edited' -and $approvedEdit.Messages[3].content -like 'Applied*' -and [IO.File]::ReadAllText($editPath) -ceq "header`r`nbeta`r`ntail") 'Approved edit completes a mocked provider tool round trip'
    Assert-Harness ($previewText.Contains('@@ edit 1, line 2, column 1 @@') -and $previewText.Contains("-alpha`n") -and $previewText.Contains("+beta`n")) 'Quiet approval still displays path and replacement diff with coordinates'
    Assert-Harness ($previewText.Contains('ends with newline=False')) 'Preview makes missing trailing newlines visible'
    $advertised = @(Get-HarnessRequests)[0].Body.tools.function | Where-Object name -eq edit_file
    Assert-Harness ($advertised.parameters.properties.edits.type -eq 'array' -and $advertised.parameters.properties.edits.items.required -contains 'old_text') 'Provider receives the edit_file JSON schema'
    $noWriteNames = & $module { (Get-AgentHarnessBuiltinTools -AllowWrite:$false).Keys }
    Assert-Harness ($noWriteNames -notcontains 'edit_file' -and $noWriteNames -notcontains 'write_file') 'AllowWrite false disables both file mutation tools'
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'disable editing' @withBuiltins -AllowWrite:$false
    Assert-Harness (@(Get-HarnessRequests)[0].Body.tools.function.name -notcontains 'edit_file') 'Disabled editing is absent from the provider tools'

    [IO.File]::WriteAllText($editPath, 'alpha')
    $promptCountBefore = & $module { $script:EditPromptCount }
    $result = Invoke-EditFixtureTool $editArguments
    Assert-Harness ($result.content -like 'Applied*' -and (& $module { $script:EditPromptCount }) -eq $promptCountBefore) 'YOLO edits without prompting'
    [IO.File]::WriteAllText($editPath, 'alpha')
    $result = Invoke-EditFixtureTool @{ path = $editRelative; edits = @(@{ old_text = 'alpha'; new_text = 'alpha' }) } -Context $editContext
    Assert-Harness ($result.content -like 'No changes*' -and (& $module { $script:EditPromptCount }) -eq $promptCountBefore) 'A net no-op does not prompt or rewrite the file'

    foreach ($preference in 'Continue', 'Stop') {
        [IO.File]::WriteAllText($editPath, 'alpha')
        & $module { param($path) $script:EditChangedPath = $path; $script:EditReplies.Enqueue({ [IO.File]::WriteAllText($script:EditChangedPath, 'external change'); 'y' }) } $editPath
        $result = Invoke-EditFixtureTool $editArguments -Preference $preference -Context $editContext 6>$null
        Assert-Harness ($result.content -like 'ERROR: File changed*' -and [IO.File]::ReadAllText($editPath) -ceq 'external change') "Concurrent change during approval is preserved under $preference"

        [IO.File]::WriteAllText($editPath, 'alpha')
        & $module { $script:EditReplies.Enqueue('Change the approach first.') }
        Set-HarnessResponses @((New-HarnessResponse '' @($editCall, (New-HarnessCall get_datetime '{}' 'pending_edit_read'))), (New-HarnessResponse 'replanned'))
        $guidedEdit = Invoke-AgentHarness 'edit guidance' @withBuiltins -NoPromptSound -PassThru 6>$null
        $guidedRequests = @(Get-HarnessRequests)
        Assert-Harness ($guidedEdit.Answer -eq 'replanned' -and $guidedRequests[1].Body.messages[-1].content -ceq 'Change the approach first.') 'Edit approval guidance returns to the model as a user message'
        Assert-Harness ($guidedEdit.Messages[4].content -like 'Skipped:*' -and [IO.File]::ReadAllText($editPath) -ceq 'alpha') 'Edit approval guidance skips remaining calls and preserves the file'
    }

    # Simulate a failure after the temporary file is prepared, under both preferences.
    $savedEditReader = & $module { ${function:Read-AgentHarnessEditFile} }
    try {
        foreach ($preference in 'Continue', 'Stop') {
            & $module {
                param($reader)
                $script:SavedEditReader = $reader
                $script:EditReadCount = 0
                function script:Read-AgentHarnessEditFile {
                    param($Path)
                    $script:EditReadCount++
                    if ($script:EditReadCount -eq 3) { throw 'Synthetic failure after staging.' }
                    & $script:SavedEditReader -Path $Path
                }
            } $savedEditReader
            $result = Invoke-EditFixtureTool $editArguments -Preference $preference
            Assert-Harness ($result.content -like 'ERROR:*Synthetic failure after staging*' -and [IO.File]::ReadAllText($editPath) -ceq 'alpha') "Save failure leaves the original intact under $preference"
            Assert-Harness (@(Get-ChildItem -LiteralPath $editRoot -Force -Filter '.agentharness-*.tmp').Count -eq 0) 'Failed save cleans up its temporary file'
        }
    }
    finally { & $module { param($reader) Set-Item -LiteralPath Function:script:Read-AgentHarnessEditFile -Value $reader } $savedEditReader }
}
finally { & $module { param($reader) Set-Item -LiteralPath Function:script:Read-Host -Value $reader } $savedEditReadHost }
$ErrorActionPreference = $editSavedPreference
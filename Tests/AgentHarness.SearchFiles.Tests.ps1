# Dot-sourced by Invoke-AgentHarness.Tests.ps1 inside its isolated module fixture.
$boundedRoot = Join-Path $searchRoot 'bounded'
$null = New-Item -ItemType Directory -Path $boundedRoot
Set-Content -LiteralPath (Join-Path $boundedRoot 'backtracking.txt') -Value (('a' * 40) + '!')
[IO.File]::WriteAllText((Join-Path $boundedRoot 'unicode.txt'), "first`r`n  CAFÉ needle  ", [Text.Encoding]::Unicode)
$oversizedPath = Join-Path $boundedRoot 'oversized.txt'
$stream = [IO.File]::Create($oversizedPath)
try { $stream.SetLength(10MB + 1) } finally { $stream.Dispose() }

foreach ($preference in 'Continue', 'Stop') {
    $boundedResults = & $module {
        param($root, $preference)
        $ErrorActionPreference = $preference
        $context = @{ Root = $root; Quiet = $true }
        $tools = Get-AgentHarnessBuiltinTools
        foreach ($arguments in @(
            '{"pattern":"(?<=café )needle","glob":"unicode.txt"}',
            '{"pattern":"^(a+)+$","glob":"backtracking.txt"}',
            '{"pattern":"[","path":"missing"}',
            '{"pattern":"needle","path":"missing"}',
            '{"pattern":"needle","path":"unicode.txt"}',
            '{"pattern":"needle","glob":"oversized.txt"}',
            '{"pattern":"absent","glob":"unicode.txt"}'
        )) {
            Invoke-AgentHarnessToolCall -Call @{ id = 'bounded_search'; function = @{ name = 'search_files'; arguments = $arguments } } `
                -ToolTable $tools -Context $context
        }
    } $boundedRoot $preference
    Assert-Harness ($boundedResults[0].content -eq 'unicode.txt:2: CAFÉ needle') "Search preserves BOM decoding, case-insensitive .NET regex and line numbers under $preference"
    Assert-Harness ($boundedResults[1].content -like 'ERROR: Regex timed out*backtracking.txt*') "Pathological regex returns a tool error under $preference"
    Assert-Harness ($boundedResults[2].content -like 'ERROR:*' -and $boundedResults[2].content -notlike '*existing directory*') "Invalid regex is rejected before traversal under $preference"
    foreach ($index in 3, 4) {
        Assert-Harness ($boundedResults[$index].content -like 'ERROR: Search path must be an existing directory*') "Missing and non-directory paths return a tool error under $preference"
    }
    Assert-Harness ($boundedResults[5].content -like '*skipped 1 files larger than 10485760 bytes*') "Oversized files are skipped with a visible notice under $preference"
    Assert-Harness ($boundedResults[6].content -eq '(no output)') "Completed searches without matches preserve no-output behavior under $preference"
}

$deadlineErrors = & $module {
    param($root)
    foreach ($action in @(
        { Find-AgentHarnessFileText -Root $root -Path $root -Pattern needle -TimeoutSeconds 0 },
        { Get-AgentHarnessSearchFiles -Root $root -Path $root -Filter '*.absent' -Stopwatch ([Diagnostics.Stopwatch]::StartNew()) -TimeoutSeconds 0 }
    )) {
        try { & $action | Out-Null; 'did not time out' }
        catch { $_.Exception.Message }
    }
} $boundedRoot
Assert-Harness (@($deadlineErrors | Where-Object { $_ -like 'Search timed out;*' }).Count -eq 2) 'Scan deadlines also apply during directory traversal without matching files'

# Reaching 50 matches must stop reading before a pathological later line.
$earlyStopPath = Join-Path $boundedRoot 'early-stop.txt'
Set-Content -LiteralPath $earlyStopPath -Value (@(1..50 | ForEach-Object { 'needle' }) + (('a' * 40) + '!'))
$earlyStop = & $module {
    param($root)
    Invoke-AgentHarnessToolCall -Call @{ id = 'early_stop'; function = @{ name = 'search_files'; arguments = '{"pattern":"needle|^(a+)+$","glob":"early-stop.txt"}' } } `
        -ToolTable (Get-AgentHarnessBuiltinTools) -Context @{ Root = $root; Quiet = $true }
} $boundedRoot
Assert-Harness (@($earlyStop.content -split '\r?\n').Count -eq 51 -and $earlyStop.content -like '*early-stop.txt:50: needle*stopped after 50 matches*') 'The global result cap stops file reading before line 51 and reports it'
$exclusive = [IO.File]::Open($earlyStopPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { Assert-Harness ($exclusive.Length -gt 0) 'Early pipeline termination disposes the file reader' } finally { $exclusive.Dispose() }

$exclusive = [IO.File]::Open((Join-Path $boundedRoot 'backtracking.txt'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { Assert-Harness ($exclusive.Length -gt 0) 'Regex timeout disposes the file reader' } finally { $exclusive.Dispose() }

$exclusive = [IO.File]::Open((Join-Path $boundedRoot 'unicode.txt'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    foreach ($preference in 'Continue', 'Stop') {
        $readFailure = & $module {
            param($root, $preference)
            $ErrorActionPreference = $preference
            Invoke-AgentHarnessToolCall -Call @{ id = 'locked_search'; function = @{ name = 'search_files'; arguments = '{"pattern":"needle","glob":"unicode.txt"}' } } `
                -ToolTable (Get-AgentHarnessBuiltinTools) -Context @{ Root = $root; Quiet = $true }
        } $boundedRoot $preference
        Assert-Harness ($readFailure.content -like 'ERROR:*' -and $readFailure.content -ne '(no output)') "File read failures return an explicit tool error under $preference"
    }
} finally { $exclusive.Dispose() }

# All protected-name fixtures contain synthetic text; never inspect the real file.
$securityRoot = Join-Path $boundedRoot 'security'
$null = New-Item -ItemType Directory -Path (Join-Path $securityRoot 'nested') -Force
foreach ($name in 'Initialize.ps1', 'nested/INITIALIZE.PS1', 'keep.txt', 'token.txt', 'nested/keep.txt') {
    Set-Content -LiteralPath (Join-Path $securityRoot $name) -Value 'synthetic_search_marker'
}
$protectedLocks = @(
    [IO.File]::Open((Join-Path $securityRoot 'Initialize.ps1'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    [IO.File]::Open((Join-Path $securityRoot 'nested/INITIALIZE.PS1'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
)
try {
    $exclusionResults = & $module {
        param($root)
        foreach ($arguments in @(
            '{"pattern":"synthetic_search_marker"}',
            '{"pattern":"synthetic_search_marker","exclude_files":[]}',
            '{"pattern":"synthetic_search_marker","exclude_files":["TOKEN.TXT"]}',
            '{"pattern":"synthetic_search_marker","exclude_files":"token.txt"}',
            '{"pattern":"synthetic_search_marker","exclude_files":["nested/keep.txt"]}',
            '{"pattern":"synthetic_search_marker","exclude_files":["*.txt"]}',
            '{"pattern":"synthetic_search_marker","exclude_files":[null]}',
            '{"pattern":"synthetic_search_marker","glob":"Initialize.ps1"}'
        )) {
            Invoke-AgentHarnessToolCall -Call @{ id = 'exclusion_search'; function = @{ name = 'search_files'; arguments = $arguments } } `
                -ToolTable (Get-AgentHarnessBuiltinTools) -Context @{ Root = $root; Quiet = $true }
        }
    } $securityRoot
    Assert-Harness (@($exclusionResults[0].content -split '\r?\n').Count -eq 3 -and $exclusionResults[0].content -notlike '*Initialize.ps1*') 'Protected file names at every depth are excluded before opening, including case variants'
    Assert-Harness ($exclusionResults[1].content -eq $exclusionResults[0].content) 'An empty exclude_files array cannot disable protected names'
    Assert-Harness (@($exclusionResults[2].content -split '\r?\n').Count -eq 2 -and $exclusionResults[2].content -notlike '*token.txt*') 'Additional file exclusions match literal names case-insensitively'
    Assert-Harness ($exclusionResults[3].content -like 'ERROR: exclude_files must be an array*') 'Scalar exclude_files values are rejected'
    foreach ($index in 4, 5, 6) {
        Assert-Harness ($exclusionResults[$index].content -like 'ERROR: exclude_files entries must be*') 'Invalid file exclusions return tool errors'
    }
    Assert-Harness ($exclusionResults[7].content -eq '(no output)') 'A filename glob cannot override the protected filename exclusion'
} finally { foreach ($handle in $protectedLocks) { $handle.Dispose() } }

$directFileError = & $module {
    param($root)
    try { Get-AgentHarnessSearchFiles -Root $root -Path (Join-Path $root 'keep.txt') | Select-Object -First 2 }
    catch { $_.Exception.Message }
} $securityRoot
Assert-Harness ($directFileError -eq 'Search path must be an existing directory.') 'The file enumerator itself rejects file paths instead of looping'

$noticeRoot = Join-Path $boundedRoot 'cap-notices'
$null = New-Item -ItemType Directory -Path $noticeRoot
[IO.File]::WriteAllBytes((Join-Path $noticeRoot '00-binary.dat'), [Text.Encoding]::UTF8.GetBytes("needle`0binary"))
$stream = [IO.File]::Create((Join-Path $noticeRoot '01-large.txt'))
try { $stream.SetLength(10MB + 1) } finally { $stream.Dispose() }
Set-Content -LiteralPath (Join-Path $noticeRoot '02-matches.txt') -Value @(1..60 | ForEach-Object { 'needle' })
$notices = & $module {
    param($root)
    Invoke-AgentHarnessToolCall -Call @{ id = 'search_notices'; function = @{ name = 'search_files'; arguments = '{"pattern":"needle"}' } } `
        -ToolTable (Get-AgentHarnessBuiltinTools) -Context @{ Root = $root; Quiet = $true }
} $noticeRoot
Assert-Harness ($notices.content -notlike '*00-binary.dat:*' -and $notices.content -like '*skipped 1 binary files*') 'NUL-containing binary files do not emit matching text'
Assert-Harness ($notices.content -like '*stopped after 50 matches*' -and $notices.content -like '*skipped 1 files larger than*') 'Result limiting preserves notices for oversized and binary files already skipped'

$orderRoot = Join-Path $boundedRoot 'ordering'
foreach ($directory in 'zeta', 'alpha') { $null = New-Item -ItemType Directory -Path (Join-Path $orderRoot $directory) -Force }
foreach ($name in 'zeta.txt', 'alpha.txt', 'zeta/child.txt', 'alpha/child.txt') { Set-Content -LiteralPath (Join-Path $orderRoot $name) -Value 'needle' }
$orderedPaths = & $module {
    param($root)
    Get-AgentHarnessSearchFiles -Root $root -Path $root | ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') }
} $orderRoot
Assert-Harness (($orderedPaths -join ',') -eq 'alpha.txt,zeta.txt,alpha/child.txt,zeta/child.txt') 'Traversal sorts files within directories and visits subdirectories alphabetically'
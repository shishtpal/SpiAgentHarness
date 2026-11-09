# Dot-sourced by Invoke-AgentHarness.Tests.ps1 inside its isolated module fixture.
$mcpFixture = Join-Path $fixture 'mcp-fixture'
$null = New-Item -ItemType Directory -Path $mcpFixture
$mcpServerScript = Join-Path $repo 'Tests/Fixtures/AgentHarness.McpServer.ps1'
$mcpPwsh = (Get-Command pwsh -ErrorAction Stop).Source
$mcpLogs = [Collections.Generic.List[string]]::new()

function New-McpFixtureConfig {
    param([string]$Mode = 'legacy', [string[]]$AllowedTools = @('echo'), [int]$TimeoutSec = 10)
    $logPath = Join-Path $mcpFixture ([guid]::NewGuid().ToString('N') + '.jsonl')
    $mcpLogs.Add($logPath)
    @{
        Command = $mcpPwsh
        Arguments = @('-NoProfile', '-File', $mcpServerScript, '-Mode', $Mode, '-LogPath', $logPath, '-ReadyPath', ($logPath + '.ready'))
        AllowedTools = $AllowedTools
        TimeoutSec = $TimeoutSec
    }
}
function Read-McpFixtureLog {
    param([hashtable]$Config)
    $path = $Config.Arguments[($Config.Arguments.IndexOf('-LogPath') + 1)]
    if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path | ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable -NoEnumerate } }
}
function Invoke-McpFixtureHarness {
    param([hashtable]$Config, [string]$Tool = 'echo', [string]$Json = '{}', [switch]$YOLO)
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall "mcp_fixture_$Tool" $Json))), (New-HarnessResponse 'MCP finished'))
    Invoke-AgentHarness 'Synthetic MCP task' @basic -NoAgentsFile -McpServers @{ fixture = $Config } -YOLO:$YOLO -NoPromptSound -PassThru
}

$mcpSavedReadHost = & $module { ${function:Read-Host} }
try {
    & $module {
        function script:Read-Host {
            param([string]$Prompt)
            if (-not $script:ConfirmationReplies.Count) { throw 'Unexpected MCP approval prompt.' }
            $script:ConfirmationPrompts.Add($Prompt)
            $script:ConfirmationReplies.Dequeue()
        }
    }
    # Explicit JSON configuration uses synthetic servers and the same mocked provider.
    $jsonDirectory = Join-Path $mcpFixture 'json [configs]'
    $null = New-Item -ItemType Directory -Path $jsonDirectory
    $jsonPath = Join-Path $jsonDirectory '[servers].json'
    # The shared default belongs to the isolated module fixture, never the real module.
    Assert-Harness (@(Get-McpServer).Count -eq 0) 'Missing module-default MCP configuration lists no servers'
    $defaultMcpPath = Join-Path $fixture 'mcp.json'
    $defaultConfig = New-McpFixtureConfig -Mode modern
    $defaultConfig.AutoApproveTools = @('echo')
    [IO.File]::WriteAllText($defaultMcpPath, (ConvertTo-Json -InputObject @{ mcpServers = @{ fixture = $defaultConfig } } -Depth 20))
    try {
        $listing = @(Get-McpServer -WorkingDirectory $jsonDirectory)
        Assert-Harness ($listing.Count -eq 1 -and $listing[0].Name -eq 'fixture' -and $listing[0].Transport -eq 'stdio' -and $listing[0].Endpoint -eq $mcpPwsh) 'Get-McpServer defaults to the module directory regardless of current working directory'
        Assert-Harness (-not (Test-Path -LiteralPath ($defaultConfig.Arguments[$defaultConfig.Arguments.IndexOf('-LogPath') + 1]))) 'Listing configured MCP servers never launches a process'
        Assert-Harness (@(Get-McpServer -Name 'absent*').Count -eq 0) 'Server listing supports wildcard name filters'
        [IO.File]::WriteAllText($defaultMcpPath, (ConvertTo-Json -InputObject @{ mcpServers = @{
            fixture = $defaultConfig; excluded = @{ Command = 'nonexistent-mcp-server-that-must-not-launch' }
        } } -Depth 20))
        Set-HarnessResponses @((New-HarnessResponse 'no activation'))
        $null = Invoke-AgentHarness 'MCP disabled by default' @basic
        Assert-Harness (-not (Get-HarnessRequests)[0].Body.PSObject.Properties['tools'] -and -not (Test-Path -LiteralPath ($defaultConfig.Arguments[$defaultConfig.Arguments.IndexOf('-LogPath') + 1]))) 'Default harness invocation ignores configured JSON servers without launching them'
        Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall mcp_fixture_echo))), (New-HarnessResponse 'default JSON done'))
        $result = Invoke-AgentHarness 'selected shared MCP configuration' @basic -McpServer fixture -NoPromptSound -PassThru
        Assert-Harness ($result.Answer -eq 'default JSON done' -and $result.Messages[3].content -like '*"name":"echo"*') 'Harness activates a named server from module-default MCP configuration'
        Set-HarnessResponses @((New-HarnessResponse 'disabled'))
        $null = Invoke-AgentHarness 'explicit empty override' @basic -McpServers @{}
        Assert-Harness (-not (Get-HarnessRequests)[0].Body.PSObject.Properties['tools']) 'Explicit empty server map disables module-default MCP servers'
        [IO.File]::WriteAllText($jsonPath, '{"mcpServers":{}}')
        Set-HarnessResponses @((New-HarnessResponse 'file override'))
        $null = Invoke-AgentHarness 'explicit JSON override' @basic -McpConfigPath $jsonPath
        Assert-Harness (-not (Get-HarnessRequests)[0].Body.PSObject.Properties['tools']) 'Explicit JSON overrides the module-default MCP configuration'
        $selected = & $module {
            Select-AgentHarnessMcpServers -Servers @{ first = @{}; second = @{}; third = @{} } -Name @('first', 'third', 'first')
        }
        Assert-Harness ($selected.Count -eq 2 -and $selected.ContainsKey('first') -and $selected.ContainsKey('third')) 'MCP activation accepts several exact server names and deduplicates repeated names'
        foreach ($names in @(@('missing'), @('fixture', 'missing'), @('*', 'fixture'), @(' '))) {
            Set-HarnessResponses @((New-HarnessResponse))
            Assert-HarnessThrows { Invoke-AgentHarness 'invalid activation' @basic -McpServer $names } '*MCP*'
            Assert-Harness (@(Get-HarnessRequests).Count -eq 0) 'Invalid MCP selection fails before any provider call'
        }
        $otherConfig = New-McpFixtureConfig -Mode modern
        [IO.File]::WriteAllText($defaultMcpPath, (ConvertTo-Json -InputObject @{ mcpServers = @{ fixture = $defaultConfig; other = $otherConfig } } -Depth 20))
        foreach ($names in @(@('fixture', 'other'), @('*'))) {
            Set-HarnessResponses @((New-HarnessResponse 'selected several'))
            $null = Invoke-AgentHarness 'activate multiple servers' @basic -McpServer $names
            $specNames = @((Get-HarnessRequests)[0].Body.tools.function.name)
            Assert-Harness ($specNames -contains 'mcp_fixture_echo' -and $specNames -contains 'mcp_other_echo') 'Both explicit server lists and * activate all selected configured servers'
        }
        [IO.File]::WriteAllText($defaultMcpPath, '{"mcpServers":null}')
        Assert-HarnessThrows { Get-McpServer } '*mcpServers must be a JSON object*'
        Set-HarnessResponses @((New-HarnessResponse 'ignored invalid default'))
        Assert-Harness ((Invoke-AgentHarness 'ignore unused MCP file' @basic) -eq 'ignored invalid default') 'An inactive shared MCP file is not read or validated during normal harness use'
    }
    finally { Remove-Item -LiteralPath $defaultMcpPath -Force }

    $safeListing = @(Get-McpServer -McpServers @{
        local = @{ Command = 'nonexistent-server'; Arguments = @('synthetic-argument-secret'); Environment = @{ KEY = 'synthetic-environment-secret' }; AllowedTools = @(); AutoApproveTools = @() }
        remote = @{ Url = 'https://user:synthetic-password@example.invalid/mcp?token=synthetic-query-secret#synthetic-fragment'; Headers = @{ Authorization = 'Bearer synthetic-header-secret' }; BearerTokenEnvironmentVariable = 'UNSET_SYNTHETIC_VARIABLE' }
    })
    Assert-Harness (($safeListing.Name -join ',') -eq 'local,remote' -and $safeListing[1].Endpoint -eq 'https://example.invalid/mcp') 'Server listing is sorted and removes URL user information, query and fragment'
    Assert-Harness (-not $safeListing[0].AllToolsAllowed -and $safeListing[0].AllowedTools.Count -eq 0 -and $safeListing[1].AllToolsAllowed) 'Server listing distinguishes empty allowlists from unrestricted configuration'
    $summaryJson = ConvertTo-Json -InputObject $safeListing -Depth 20
    Assert-Harness ($summaryJson -notmatch 'synthetic-(argument|environment|password|query|header)-secret|synthetic-fragment' -and -not $safeListing[0].PSObject.Properties['Arguments'] -and -not $safeListing[1].PSObject.Properties['Headers']) 'Server summaries omit arguments, credential values and raw configuration'

    foreach ($wrapped in $true, $false) {
        $config = New-McpFixtureConfig -Mode modern
        $jsonServer = @{
            command = $config.Command; args = $config.Arguments; type = 'stdio'
            env = @{ SPI_MCP_FIXTURE_VALUE = 'json-synthetic-value' }
            allowedTools = @('echo'); autoApproveTools = @('echo')
        }
        $document = if ($wrapped) { @{ mcpServers = @{ fixture = $jsonServer } } } else { @{ fixture = $jsonServer } }
        [IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $document -Depth 20))
        $listing = @(Get-McpServer -McpConfigPath $jsonPath)
        Assert-Harness ($listing.Count -eq 1 -and $listing[0].AllowedTools.Count -eq 1 -and $listing[0].AllowedTools[0] -ceq 'echo') 'Explicit JSON server listing uses the shared configuration parser and preserves array properties'
        Set-HarnessResponses @((New-HarnessResponse 'JSON inactive'))
        $null = Invoke-AgentHarness 'explicit JSON still needs activation' @basic -McpConfigPath $jsonPath
        Assert-Harness (-not (Get-HarnessRequests)[0].Body.PSObject.Properties['tools'] -and -not (Test-Path -LiteralPath ($config.Arguments[$config.Arguments.IndexOf('-LogPath') + 1]))) 'An explicit JSON file does not activate servers until names are selected'
        Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall mcp_fixture_echo '{"values":[],"text":"from JSON"}'))), (New-HarnessResponse 'JSON done'))
        $result = Invoke-AgentHarness 'JSON MCP task' @basic -McpConfigPath 'mcp-fixture/json [configs]/[servers].json' -McpServer fixture -NoPromptSound -PassThru
        $toolResult = $result.Messages[3].content | ConvertFrom-Json -AsHashtable
        Assert-Harness ($result.Answer -eq 'JSON done' -and $toolResult.arguments.text -ceq 'from JSON' -and $toolResult.arguments.values -is [array]) 'Wrapped and bare JSON server maps execute through the public harness'
        Assert-Harness ($toolResult.cwd -eq $jsonDirectory -and $toolResult.environment -eq '[REDACTED]') 'JSON defaults child working directory to the configuration directory and handles env aliases without exposing values'
        Assert-Harness ($null -eq (Get-Process -Id $toolResult.pid -ErrorAction SilentlyContinue)) 'JSON-configured child processes are reaped'
    }

    $pathDocument = @{ mcpServers = @{ fixture = @{
        command = './bin/server.exe'; args = @(); cwd = './child'; allowedTools = @(); autoApproveTools = @()
    } } }
    [IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $pathDocument -Depth 20))
    $parsed = & $module { param($path, $root) Read-AgentHarnessMcpConfig -Path $path -WorkingDirectory $root } $jsonPath $fixture
    Assert-Harness ($parsed.fixture.Arguments -is [array] -and $parsed.fixture.Arguments.Count -eq 0 -and $parsed.fixture.AllowedTools -is [array] -and $parsed.fixture.AllowedTools.Count -eq 0) 'JSON configuration preserves explicitly empty arrays'
    Assert-Harness ($parsed.fixture.Command -eq (Join-Path $jsonDirectory 'bin/server.exe') -and $parsed.fixture.WorkingDirectory -eq (Join-Path $jsonDirectory 'child')) 'Relative executable and cwd paths resolve against the JSON file directory'

    [IO.File]::WriteAllText($jsonPath, '{"mcpServers":{"remote":{"type":"streamable-http","url":"https://fixture.invalid/mcp","bearerTokenEnvironmentVariable":"SPI_SYNTHETIC_TOKEN"}}}')
    $parsed = & $module { param($path, $root) Read-AgentHarnessMcpConfig -Path $path -WorkingDirectory $root } $jsonPath $fixture
    Assert-Harness ($parsed.remote.Transport -eq 'http' -and $parsed.remote.BearerTokenEnvironmentVariable -ceq 'SPI_SYNTHETIC_TOKEN') 'JSON supports HTTP type aliases and existing credential environment references without resolving them during parsing'

    foreach ($parameterName in 'McpConfigPath', 'McpConfigFile', 'McpConfig') {
        [IO.File]::WriteAllText($jsonPath, '{"mcpServers":{}}')
        Set-HarnessResponses @((New-HarnessResponse 'no MCP tools'))
        $jsonOptions = @{ $parameterName = $jsonPath }
        Assert-Harness ((Invoke-AgentHarness 'empty JSON' @basic @jsonOptions) -eq 'no MCP tools') 'JSON path parameter and aliases accept an explicitly empty server map'
    }
    Set-HarnessResponses @((New-HarnessResponse))
    Assert-HarnessThrows { Invoke-AgentHarness 'ambiguous configuration' @basic -McpServers @{} -McpConfigPath $jsonPath } '*either*not both*'
    Assert-Harness (@(Get-HarnessRequests).Count -eq 0) 'Supplying both configuration sources fails before provider requests'
    Assert-HarnessThrows { Invoke-AgentHarness 'missing config' @basic -McpConfigPath (Join-Path $jsonDirectory 'missing.json') } '*readable .json*'

    $invalidJsonConfigs = @(
        '{"mcpServers": "synthetic-secret-invalid-json"', '[]', '[{}]', 'null', '42',
        '{"mcpServers":[]}', '{"mcpServers":null}', '{"mcpServers":{"fixture":[]}}',
        '{"mcpServers":{"fixture":{"args":null}}}', '{"mcpServers":{"fixture":{"args":"unexpected"}}}',
        '{"mcpServers":{"fixture":{"args":[null]}}}', '{"mcpServers":{"fixture":{"args":[],"arguments":[]}}}',
        '{"mcpServers":{"fixture":{"allowedTools":null}}}', '{"mcpServers":{"fixture":{"allowedTools":"echo"}}}',
        '{"mcpServers":{"fixture":{"env":[]}}}', '{"mcpServers":{"fixture":{"headers":{"Authorization":false}}}}',
        '{"mcpServers":{"fixture":{"command":[]}}}', '{"mcpServers":{"fixture":{"timeoutSec":"synthetic-secret-invalid-json"}}}'
    )
    foreach ($preference in 'Continue', 'Stop') {
        foreach ($json in $invalidJsonConfigs) {
            [IO.File]::WriteAllText($jsonPath, $json)
            Set-HarnessResponses @((New-HarnessResponse))
            $savedPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = $preference
                $failure = $null
                try { Invoke-AgentHarness 'invalid JSON' @basic -McpConfigPath $jsonPath | Out-Null } catch { $failure = $_.Exception.Message }
                Assert-Harness ($failure -like 'MCP configuration*' -and $failure -notlike '*synthetic-secret-invalid-json*' -and @(Get-HarnessRequests).Count -eq 0) "Invalid JSON configuration fails safely before model requests under $preference"
            }
            finally { $ErrorActionPreference = $savedPreference }
        }
    }

    foreach ($mode in 'legacy', 'modern') {
        $config = New-McpFixtureConfig -Mode $mode
        $config.AutoApproveTools = @('echo')
        $config.Environment = @{ SPI_MCP_FIXTURE_VALUE = 'synthetic-environment' }
        $result = Invoke-McpFixtureHarness -Config $config -Json '{"text":"hello","values":[]}'
        $toolResult = $result.Messages[3].content | ConvertFrom-Json -AsHashtable
        Assert-Harness ($result.Answer -eq 'MCP finished' -and $toolResult.arguments.text -ceq 'hello' -and $toolResult.arguments.values -is [array] -and $toolResult.arguments.values.Count -eq 0) "$mode MCP preserves object arguments and empty arrays"
        Assert-Harness ($toolResult.environment -eq '[REDACTED]' -and $toolResult.cwd -eq $fixture) 'MCP child receives configured environment and working directory without exposing configured values'
        $requests = @(Get-HarnessRequests)
        Assert-Harness (@($requests[0].Body.tools).Count -eq 1 -and $requests[0].Body.tools[0].function.name -eq 'mcp_fixture_echo') 'Only allowed MCP tools are advertised alongside the existing provider contract'
        $log = @(Read-McpFixtureLog $config)
        Assert-Harness (@($log | Where-Object method -eq 'tools/list').Count -eq 2) 'MCP discovery follows pagination'
        Assert-Harness (@($log | Where-Object method -eq 'tools/call').Count -eq 1 -and $log[-1].params.name -ceq 'echo') 'MCP routes exact original names without replaying calls'
        Assert-Harness ($null -eq (Get-Process -Id $toolResult.pid -ErrorAction SilentlyContinue)) 'MCP child is reaped after a successful invocation'
        if ($mode -eq 'legacy') {
            Assert-Harness (@($log | Where-Object method -eq 'initialize').Count -eq 1 -and @($log | Where-Object method -eq 'notifications/initialized').Count -eq 1) 'Legacy discovery falls back to initialize plus initialized notification'
        }
        else {
            Assert-Harness (@($log | Where-Object method -eq 'initialize').Count -eq 0 -and $log[-1].params._meta['io.modelcontextprotocol/protocolVersion'] -eq '2026-07-28') 'Modern MCP uses per-request metadata without initialization'
        }
    }

    foreach ($reply in 'n', 'y', 'Please use another tool') {
        $config = New-McpFixtureConfig
        & $module { param($reply) $script:ConfirmationReplies.Enqueue($reply) } $reply
        $result = Invoke-McpFixtureHarness -Config $config 6>$null
        $log = @(Read-McpFixtureLog $config)
        Assert-Harness (@($log | Where-Object method -eq 'tools/call').Count -eq [int]($reply -eq 'y')) 'MCP approval gates execution'
        if ($reply -eq 'n') { Assert-Harness ($result.Messages[3].content -like 'Denied:*') 'MCP denial is returned to the model' }
        if ($reply -like 'Please*') { Assert-Harness ($result.Messages[4].role -eq 'user' -and $result.Messages[4].content -ceq $reply) 'MCP approval guidance returns to the normal replanning flow' }
    }
    $config = New-McpFixtureConfig
    $result = Invoke-McpFixtureHarness -Config $config -YOLO
    Assert-Harness ($result.Messages[3].content -like '*"name":"echo"*') 'YOLO explicitly bypasses MCP approvals'

    $first = New-McpFixtureConfig -Mode modern
    $second = New-McpFixtureConfig -Mode modern
    $first.AutoApproveTools = @('echo'); $second.AutoApproveTools = @('echo')
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall mcp_first_echo '{"text":"one"}' 'one'), (New-HarnessCall mcp_second_echo '{"text":"two"}' 'two'))), (New-HarnessResponse))
    $result = Invoke-AgentHarness 'two servers' @basic -McpServers @{ first = $first; second = $second } -PassThru
    $one = $result.Messages[3].content | ConvertFrom-Json
    $two = $result.Messages[4].content | ConvertFrom-Json
    Assert-Harness ($one.arguments.text -ceq 'one' -and $two.arguments.text -ceq 'two' -and $one.pid -ne $two.pid) 'MCP closures route same-named tools to the correct server connection'

    $config = New-McpFixtureConfig -Mode modern
    $config.AutoApproveTools = @('echo')
    $options = $basic.Clone(); $options.NoCompletionPrompt = $false
    & $module { $script:ConfirmationReplies.Enqueue('second MCP task'); $script:ConfirmationReplies.Enqueue('exit') }
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall mcp_fixture_echo))), (New-HarnessResponse 'first final'), (New-HarnessResponse '' @((New-HarnessCall mcp_fixture_echo))), (New-HarnessResponse 'second final'))
    $result = Invoke-AgentHarness 'first MCP task' @options -NoPromptSound -McpServers @{ fixture = $config } -PassThru 6>$null
    $log = @(Read-McpFixtureLog $config)
    Assert-Harness ($result.Answer -eq 'second final' -and @($log | Where-Object method -eq 'server/discover').Count -eq 1 -and @($log | Where-Object method -eq 'tools/call').Count -eq 2) 'Continuation reuses MCP connections and discovery across tasks'

    $config = New-McpFixtureConfig -Mode modern
    Set-HarnessResponses @((New-HarnessApiError 400))
    Assert-HarnessThrows { Invoke-AgentHarness 'provider fails after MCP discovery' @basic -McpServers @{ fixture = $config } } '*No working model*'
    $ready = $config.Arguments[($config.Arguments.IndexOf('-ReadyPath') + 1)]
    Assert-Harness ($null -eq (Get-Process -Id ([int][IO.File]::ReadAllText($ready)) -ErrorAction SilentlyContinue)) 'MCP process is reaped when the model request fails'

    foreach ($json in '[]', '[{}]', 'null', '42') {
        $config = New-McpFixtureConfig
        $config.AutoApproveTools = @('echo')
        $result = Invoke-McpFixtureHarness -Config $config -Json $json
        Assert-Harness ($result.Messages[3].content -like 'ERROR:*JSON object*' -and @((Read-McpFixtureLog $config) | Where-Object method -eq 'tools/call').Count -eq 0) 'Invalid outer JSON never reaches the MCP server'
    }
    foreach ($preference in 'Continue', 'Stop') {
        foreach ($tool in 'fail', 'rpcfail', 'structured') {
            $config = New-McpFixtureConfig -AllowedTools @($tool)
            $config.AutoApproveTools = @($tool)
            $savedPreference = $ErrorActionPreference
            try { $ErrorActionPreference = $preference; $result = Invoke-McpFixtureHarness -Config $config -Tool $tool }
            finally { $ErrorActionPreference = $savedPreference }
            if ($tool -eq 'fail') { Assert-Harness ($result.Messages[3].content -like 'ERROR:*synthetic tool failure*') "MCP isError is an error result under $preference" }
            if ($tool -eq 'rpcfail') { Assert-Harness ($result.Messages[3].content -like 'ERROR:*JSON-RPC -32602*' -and $result.Messages[3].content -notlike '*secret-test-value*') 'MCP protocol failures do not echo server error data'
            }
            if ($tool -eq 'structured') { Assert-Harness ($result.Messages[3].content -like '*"ok":true*' -and $result.Messages[3].content -like '*Unsupported MCP content: audio*' -and $result.Messages[3].content -notlike '*SYNTHETIC*') 'Structured results survive and unsupported media is explicitly omitted' }
        }
    }

    foreach ($tool in 'sleep', 'disconnect', 'oversize', 'malformed') {
        $config = New-McpFixtureConfig -AllowedTools @($tool) -TimeoutSec 2
        $config.AutoApproveTools = @($tool)
        if ($tool -eq 'oversize') { $config.MaxResponseChars = 12000 }
        $result = Invoke-McpFixtureHarness -Config $config -Tool $tool
        Assert-Harness ($result.Messages[3].content -like 'ERROR:*connection was closed*' -and @((Read-McpFixtureLog $config) | Where-Object method -eq 'tools/call').Count -eq 1) "MCP $tool closes the connection and never retries the action"
    }
    foreach ($mode in 'cursor', 'reject-version') {
        $config = New-McpFixtureConfig -Mode $mode
        Set-HarnessResponses @((New-HarnessResponse))
        Assert-HarnessThrows { Invoke-AgentHarness 'invalid MCP' @basic -McpServers @{ fixture = $config } } '*MCP*'
        Assert-Harness (@(Get-HarnessRequests).Count -eq 0) 'MCP discovery failure occurs before sending model requests'
        $ready = $config.Arguments[($config.Arguments.IndexOf('-ReadyPath') + 1)]
        Assert-Harness ($null -eq (Get-Process -Id ([int][IO.File]::ReadAllText($ready)) -ErrorAction SilentlyContinue)) 'MCP discovery failures reap their child processes'
    }

    # Name normalization must preserve case-distinct originals, punctuation and length.
    $config = New-McpFixtureConfig
    $config.Remove('AllowedTools')
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'names' @basic -McpServers @{ fixture = $config }
    $names = @((Get-HarnessRequests)[0].Body.tools.function.name)
    Assert-Harness ($names.Count -eq 14 -and @($names | Where-Object { $_.Length -gt 64 -or $_ -notmatch '^[A-Za-z0-9_-]+$' }).Count -eq 0 -and @($names | Sort-Object -Unique).Count -eq $names.Count) 'MCP names fit provider limits and remain unique across case/punctuation/long names'
    # Resolve normalized provider names back to each exact original server name.
    $config = New-McpFixtureConfig -AllowedTools @('Search', 'search', 'namespace/tool')
    $table = & $module {
        param($config, $root)
        $connections = [Collections.Generic.List[hashtable]]::new()
        $table = [ordered]@{}
        try {
            Get-AgentHarnessMcpTools -Servers @{ fixture = $config } -ToolTable $table -Connections $connections -WorkingDirectory $root
            foreach ($name in $table.Keys) {
                $result = Invoke-AgentHarnessToolCall -Call @{ id = 'mapped'; function = @{ name = $name; arguments = '{}' } } -ToolTable $table -Context @{ Root = $root; Quiet = $true; YOLO = $true }
                @{ Original = $table[$name].McpBinding.OriginalName; Result = $result.content }
            }
        }
        finally { foreach ($connection in $connections) { Close-AgentHarnessMcpConnection $connection } }
    } $config $fixture
    foreach ($entry in $table) {
        Assert-Harness (($entry.Result | ConvertFrom-Json).name -ceq $entry.Original) 'Normalized tool names route exact case-sensitive and punctuated original names'
    }

    $config = New-McpFixtureConfig -AllowedTools @()
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'empty allowlist' @basic -McpServers @{ fixture = $config }
    Assert-Harness (-not (Get-HarnessRequests)[0].Body.PSObject.Properties['tools']) 'An explicitly empty allowlist exposes no MCP tools'
    foreach ($key in 'AllowedTools', 'AutoApproveTools') {
        $config = New-McpFixtureConfig
        $config[$key] = @('missing')
        Assert-HarnessThrows { Invoke-AgentHarness 'typo' @basic -McpServers @{ fixture = $config } } '*entry*'
    }

    $config = New-McpFixtureConfig -Mode gateway -AllowedTools @('search_tool', 'call_tool')
    $config.AutoApproveTools = @('list_memory')
    Set-HarnessResponses @((New-HarnessResponse))
    Assert-HarnessThrows { Invoke-AgentHarness 'stale underlying tool approval' @basic -McpServers @{ fixture = $config } } "*AutoApproveTools entry 'list_memory'*top-level tools: call_tool, search_tool*dispatcher*"
    Assert-Harness (@(Get-HarnessRequests).Count -eq 0) 'Unavailable underlying auto-approval fails with dispatcher guidance before provider requests'
    $config.AutoApproveTools = @()
    Set-HarnessResponses @((New-HarnessResponse))
    $null = Invoke-AgentHarness 'gateway with manual approvals' @basic -McpServers @{ fixture = $config }
    $gatewayTools = @((Get-HarnessRequests)[0].Body.tools.function.name)
    Assert-Harness ($gatewayTools.Count -eq 2 -and $gatewayTools -contains 'mcp_fixture_search_tool' -and $gatewayTools -contains 'mcp_fixture_call_tool') 'Dispatcher discovery succeeds after removing stale underlying auto-approval without broadening approval'

    $config = New-McpFixtureConfig -AllowedTools @('echo')
    $config.AutoApproveTools = @('structured')
    Assert-HarnessThrows { Invoke-AgentHarness 'excluded auto-approval' @basic -McpServers @{ fixture = $config } } "*AutoApproveTools entry 'structured' is excluded by AllowedTools*"

    # Real loopback HTTP tests use a synthetic TCP server and no provider traffic.
    foreach ($mode in 'legacy', 'modern', 'sse', 'bad-header') {
        $portFinder = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $portFinder.Start(); $port = $portFinder.LocalEndpoint.Port; $portFinder.Stop()
        $readyPath = Join-Path $mcpFixture ([guid]::NewGuid().ToString('N') + '.ready')
        $config = New-McpFixtureConfig -Mode $mode
        $start = [Diagnostics.ProcessStartInfo]::new($mcpPwsh)
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $config.Arguments[$config.Arguments.IndexOf('-ReadyPath') + 1] = $readyPath
        foreach ($argValue in @($config.Arguments + @('-Transport', 'http', '-Port', [string]$port))) { $start.ArgumentList.Add($argValue) }
        $serverProcess = [Diagnostics.Process]::Start($start)
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $readyPath)) {
                if ($serverProcess.HasExited -or $timer.Elapsed.TotalSeconds -gt 10) { throw 'Synthetic HTTP MCP server did not start.' }
                Start-Sleep -Milliseconds 50
            }
            $httpConfig = @{ Url = "http://127.0.0.1:$port/mcp"; AllowedTools = @('headers'); AutoApproveTools = @('headers'); TimeoutSec = 10 }
            $result = Invoke-McpFixtureHarness -Config $httpConfig -Tool headers -Json '{"context":{"region":" padded "}}'
            Assert-Harness ($result.Messages[3].content -like '*"name":"headers"*') "MCP $mode HTTP handles JSON/SSE responses"
            $httpLog = @(Read-McpFixtureLog $config)
            $call = @($httpLog | Where-Object method -eq 'tools/call')[0]
            if ($mode -eq 'legacy') {
                Assert-Harness ($call.fixtureHeaders['Mcp-Session-Id'] -eq 'fixture-session' -and $httpLog[-1].delete) 'Legacy HTTP reuses and deletes its session'
            }
            else {
                Assert-Harness ($call.fixtureHeaders['Mcp-Method'] -ceq 'tools/call' -and $call.fixtureHeaders['Mcp-Name'] -ceq 'headers' -and $call.fixtureHeaders['Mcp-Param-Region'] -ceq '=?base64?IHBhZGRlZCA=?=') 'Modern HTTP mirrors methods, original names and safely encoded schema headers'
            }
        }
        finally {
            if (-not $serverProcess.HasExited) { $serverProcess.Kill($true); $null = $serverProcess.WaitForExit(1000) }
            $serverProcess.Dispose()
        }
    }
}
finally {
    & $module { param($saved) Set-Item Function:script:Read-Host -Value $saved } $mcpSavedReadHost
}
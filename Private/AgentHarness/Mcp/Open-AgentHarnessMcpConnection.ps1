function Open-AgentHarnessMcpConnection {
    param([string]$Name, [hashtable]$Config, [string]$WorkingDirectory)

    $ErrorActionPreference = 'Stop'
    $validKeys = @('Transport', 'Command', 'Arguments', 'Url', 'WorkingDirectory', 'Environment', 'EnvironmentVariables',
        'Headers', 'HeaderEnvironmentVariables', 'BearerTokenEnvironmentVariable', 'TimeoutSec', 'MaxResponseChars',
        'ProtocolVersion', 'AllowedTools', 'AutoApproveTools')
    foreach ($key in $Config.Keys) {
        if ($key -notin $validKeys) { throw "MCP '$Name': unknown configuration option '$key'." }
    }
    foreach ($key in 'AllowedTools', 'AutoApproveTools') {
        if ($Config.ContainsKey($key)) {
            foreach ($value in $Config[$key]) {
                if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { throw "MCP '$Name': $key must contain nonempty exact tool names." }
            }
            if ($null -eq $Config[$key]) { throw "MCP '$Name': $key cannot be null. Use an empty array to select no tools." }
        }
    }
    $transport = if ($Config.Transport) { [string]$Config.Transport } elseif ($Config.Url) { 'http' } else { 'stdio' }
    if ($transport -notin 'stdio', 'http') { throw "MCP '$Name': Transport must be stdio or http." }
    $version = if ($Config.ProtocolVersion) { [string]$Config.ProtocolVersion } else { 'auto' }
    $legacyVersions = @('2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05')
    if ($version -notin (@('auto', '2026-07-28') + $legacyVersions)) { throw "MCP '$Name': unsupported ProtocolVersion." }
    if ($transport -eq 'http' -and $version -eq '2024-11-05') { throw "MCP '$Name': deprecated HTTP+SSE transport is not supported." }
    $timeout = if ($Config.ContainsKey('TimeoutSec')) { [int]$Config.TimeoutSec } else { 30 }
    $limit = if ($Config.ContainsKey('MaxResponseChars')) { [int]$Config.MaxResponseChars } else { 4194304 }
    if ($timeout -lt 1 -or $timeout -gt 3600 -or $limit -lt 1024 -or $limit -gt 67108864) { throw "MCP '$Name': TimeoutSec must be 1..3600 and MaxResponseChars 1024..67108864." }
    $connection = @{
        Name = $Name; Transport = $transport; TimeoutSec = $timeout; MaxResponseChars = $limit
        ProtocolVersion = $(if ($version -eq 'auto') { '2026-07-28' } else { $version })
        NextId = 0; Closed = $false; Headers = @{}; SessionId = $null
        Secrets = [Collections.Generic.List[string]]::new()
        ToolHeaders = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    }
    $stage = 'transport setup'
    try {
        if ($transport -eq 'stdio') {
            if (-not $Config.Command -or $Config.Url) { throw "MCP '$Name': stdio requires Command and cannot specify Url." }
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = [string]$Config.Command
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
            $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
            $start.WorkingDirectory = if ([IO.Path]::IsPathRooted([string]$Config.WorkingDirectory)) { $Config.WorkingDirectory }
            elseif ($Config.WorkingDirectory) { [IO.Path]::GetFullPath((Join-Path $WorkingDirectory $Config.WorkingDirectory)) }
            else { $WorkingDirectory }
            foreach ($argument in $Config.Arguments) { $start.ArgumentList.Add([string]$argument) }
            foreach ($key in $Config.Environment.Keys) {
                $start.Environment[$key] = [string]$Config.Environment[$key]
                $connection.Secrets.Add([string]$Config.Environment[$key])
            }
            foreach ($key in $Config.EnvironmentVariables.Keys) {
                $value = [Environment]::GetEnvironmentVariable([string]$Config.EnvironmentVariables[$key])
                if ([string]::IsNullOrEmpty($value)) { throw "MCP '$Name': a configured environment variable is unset." }
                $start.Environment[$key] = $value
                $connection.Secrets.Add($value)
            }
            $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
            $connection.Process = $process
            $null = $process.Start()
            # Consume stderr continuously without retaining or logging potential secrets.
            $connection.StderrDrain = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            $connection.Reader = New-AgentHarnessMcpReader -Reader $process.StandardOutput -MaxResponseChars $limit
        }
        else {
            $url = $null
            if (-not [uri]::TryCreate([string]$Config.Url, [UriKind]::Absolute, [ref]$url) -or $url.Scheme -notin 'http', 'https' -or $url.UserInfo -or $url.Fragment) {
                throw "MCP '$Name': Url must be an absolute HTTP(S) URL without user information or a fragment."
            }
            if ($url.Scheme -eq 'http' -and -not $url.IsLoopback) { throw "MCP '$Name': remote endpoints require HTTPS." }
            if ($Config.Command) { throw "MCP '$Name': http cannot specify Command." }
            $connection.Url = $url
            foreach ($key in $Config.Headers.Keys) { $connection.Headers[$key] = [string]$Config.Headers[$key]; $connection.Secrets.Add([string]$Config.Headers[$key]) }
            foreach ($key in $Config.HeaderEnvironmentVariables.Keys) {
                $value = [Environment]::GetEnvironmentVariable([string]$Config.HeaderEnvironmentVariables[$key])
                if ([string]::IsNullOrEmpty($value)) { throw "MCP '$Name': a configured header environment variable is unset." }
                $connection.Headers[$key] = $value; $connection.Secrets.Add($value)
            }
            if ($Config.BearerTokenEnvironmentVariable) {
                $value = [Environment]::GetEnvironmentVariable([string]$Config.BearerTokenEnvironmentVariable)
                if ([string]::IsNullOrEmpty($value)) { throw "MCP '$Name': the bearer token environment variable is unset." }
                $connection.Headers['Authorization'] = 'Bearer ' + $value
                $connection.Secrets.Add($value)
            }
            foreach ($key in $connection.Headers.Keys) {
                if ($key -notmatch "^[!#$%&'*+.^_``|~0-9A-Za-z-]+$" -or $connection.Headers[$key] -match '[\r\n]' -or
                    $key -match '^(Accept|Content-Type|Host|Mcp-.*)$') { throw "MCP '$Name': invalid or reserved HTTP header." }
            }
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $false
            $connection.HttpClient = [Net.Http.HttpClient]::new($handler)
            $connection.HttpClient.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        }

        $stage = 'protocol discovery'
        $modern = $version -eq '2026-07-28'
        if ($version -eq 'auto' -or $modern) {
            try {
                $discovery = Invoke-AgentHarnessMcpRequest -Connection $connection -Method 'server/discover'
                if ($discovery.supportedVersions -and '2026-07-28' -notin $discovery.supportedVersions) { throw 'MCP server does not support the requested modern version.' }
                $modern = $true
            }
            catch {
                $code = $_.Exception.Data['McpCode']
                $httpStatus = $_.Exception.Data['HttpStatus']
                # Recognized modern errors must not be mistaken for an older server.
                if ($version -ne 'auto' -or $connection.Closed -or $code -in -32020, -32021, -32022 -or ($httpStatus -and $httpStatus -ne 400)) { throw }
                $modern = $false
            }
        }
        if (-not $modern) {
            $stage = 'initialization'
            $connection.ProtocolVersion = if ($version -eq 'auto') { '2025-11-25' } else { $version }
            $initialized = Invoke-AgentHarnessMcpRequest -Connection $connection -Method 'initialize' -Parameters @{
                protocolVersion = $connection.ProtocolVersion; capabilities = @{}
                clientInfo = @{ name = 'SpiAgentHarness'; version = '1.0.0' }
            }
            if ($initialized.protocolVersion -notin $legacyVersions -or ($transport -eq 'http' -and $initialized.protocolVersion -eq '2024-11-05')) { throw "MCP '$Name': server selected an unsupported protocol version." }
            $connection.ProtocolVersion = $initialized.protocolVersion
            Invoke-AgentHarnessMcpRequest -Connection $connection -Method 'notifications/initialized' -Notification
        }
        return $connection
    }
    catch {
        Close-AgentHarnessMcpConnection -Connection $connection
        # Do not echo command lines, configuration values, endpoint URLs, or native exception text.
        $code = $_.Exception.Data['McpCode']
        throw "MCP '$Name' could not connect during $stage$(if ($code) { " (JSON-RPC $code)" }). Check its executable/endpoint, credentials, and ProtocolVersion."
    }
}
function Read-AgentHarnessMcpConfig {
    param([string]$Path, [string]$WorkingDirectory)

    $ErrorActionPreference = 'Stop'
    if (-not $PSBoundParameters.ContainsKey('Path')) {
        $Path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../mcp.json'))
        if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    }
    try {
        $configPath = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $WorkingDirectory $Path }
        $file = Get-Item -LiteralPath $configPath -ErrorAction Stop
        if ($file -isnot [IO.FileInfo] -or $file.Extension -ine '.json' -or $file.Length -gt 1MB) { throw 'Invalid configuration file.' }
        $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName)) -AsHashtable -NoEnumerate -ErrorAction Stop
    }
    catch {
        # JSON parser diagnostics can contain raw configuration, including credentials.
        throw 'MCP configuration must be a readable .json file up to 1 MiB containing valid JSON.'
    }
    if ($document -isnot [hashtable]) { throw 'MCP configuration must be a JSON object.' }
    $servers = if ($document.ContainsKey('mcpServers')) { $document.mcpServers } else { $document }
    if ($servers -isnot [hashtable]) { throw 'MCP configuration mcpServers must be a JSON object.' }

    $result = @{}
    $aliases = @{ args = 'Arguments'; env = 'Environment'; type = 'Transport'; cwd = 'WorkingDirectory' }
    foreach ($name in $servers.Keys) {
        if ([string]::IsNullOrWhiteSpace($name) -or $servers[$name] -isnot [hashtable]) { throw 'MCP configuration must map nonempty server names to JSON objects.' }
        if ($result.ContainsKey($name)) { throw 'MCP configuration contains server names differing only in case.' }
        $config = @{}
        foreach ($key in $servers[$name].Keys) {
            $option = if ($aliases.ContainsKey($key)) { $aliases[$key] } else { $key }
            if ($config.ContainsKey($option)) { throw 'MCP configuration contains duplicate options or aliases for the same option.' }
            $config[$option] = $servers[$name][$key]
        }
        foreach ($key in 'Arguments', 'AllowedTools', 'AutoApproveTools') {
            if (-not $config.ContainsKey($key)) { continue }
            if ($config[$key] -isnot [array]) { throw "MCP configuration $key must be a JSON array of strings." }
            foreach ($value in $config[$key]) {
                if ($value -isnot [string]) { throw "MCP configuration $key must be a JSON array of strings." }
            }
        }
        foreach ($key in 'Environment', 'EnvironmentVariables', 'Headers', 'HeaderEnvironmentVariables') {
            if (-not $config.ContainsKey($key)) { continue }
            if ($config[$key] -isnot [hashtable]) { throw "MCP configuration $key must be a JSON object of strings." }
            foreach ($value in $config[$key].Values) {
                if ($value -isnot [string]) { throw "MCP configuration $key must be a JSON object of strings." }
            }
        }
        foreach ($key in 'Command', 'Url', 'Transport', 'WorkingDirectory', 'BearerTokenEnvironmentVariable', 'ProtocolVersion') {
            if ($config.ContainsKey($key) -and ($config[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($config[$key]))) { throw "MCP configuration $key must be a nonempty JSON string." }
        }
        foreach ($key in 'TimeoutSec', 'MaxResponseChars') {
            if ($config.ContainsKey($key) -and $config[$key] -isnot [int] -and $config[$key] -isnot [long]) { throw "MCP configuration $key must be a JSON integer." }
        }
        if ($config.Transport -eq 'streamable-http') { $config.Transport = 'http' }
        # A file can be invoked from any directory; resolve its paths against its own directory.
        $basePath = $file.DirectoryName
        $config.WorkingDirectory = if (-not $config.ContainsKey('WorkingDirectory')) { $basePath }
        elseif ([IO.Path]::IsPathRooted($config.WorkingDirectory)) { $config.WorkingDirectory }
        else { [IO.Path]::GetFullPath((Join-Path $basePath $config.WorkingDirectory)) }
        if ($config.Command -and -not [IO.Path]::IsPathRooted($config.Command) -and $config.Command -match '[/\\]') {
            $config.Command = [IO.Path]::GetFullPath((Join-Path $basePath $config.Command))
        }
        $result[$name] = $config
    }
    $result
}
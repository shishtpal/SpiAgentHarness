function Get-AgentHarnessPythonTools {
    @{
        run_python = @{
            Description = 'Run Python 3 code in a fresh process in the working directory. Resolves uv, then python/python3 on PATH, then SPI_AGENT_PYTHON. Requires approval unless YOLO. uv may download Python and optional packages without syncing the working project. Setup counts toward timeout_sec (default 60; maximum 86400). Returns status, exit code and bounded stdout/stderr. No persistent variables or interactive input.'
            RequiresApproval = $true
            Parameters = @{
                type = 'object'; additionalProperties = $false
                properties = @{
                    code = @{ type = 'string'; minLength = 1; maxLength = 1048576 }
                    timeout_sec = @{ type = 'integer'; minimum = 1; maximum = 86400 }
                    packages = @{ type = 'array'; maxItems = 64; items = @{ type = 'string'; minLength = 1; maxLength = 512 }; description = 'Optional package requirements, e.g. requests>=2. Requires a usable uv runtime; direct Python never installs packages.' }
                }
                required = @('code')
            }
            Script = { param($a, $ctx) Invoke-AgentHarnessPythonTool -Arguments $a -Context $ctx }
        }
    }
}
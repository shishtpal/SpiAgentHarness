function Get-AgentHarnessSubAgentTools {
    param([switch]$AllowSpawn = $true)

    $tools = [ordered]@{}
    $idProperty = @{ type = 'string'; pattern = '^[a-f0-9]{32}$'; description = 'Agent ID returned by spawn_agent' }
    if ($AllowSpawn) {
        $tools.spawn_agent = @{
            Description = 'Launch a focused task in a new visible PowerShell terminal on Windows and return its agent ID immediately. Uses the current provider/model and inherits YOLO unless yolo is supplied. Read-only by default; allow_write enables file/shell tools only if permitted by the parent. Child gets built-ins, not custom tools or MCP servers, and cannot delegate. Launch requires confirmation unless parent YOLO.'
            RequiresApproval = $true
            Parameters = @{
                type = 'object'; additionalProperties = $false; required = @('task')
                properties = @{
                    task = @{ type = 'string'; minLength = 1; description = 'Self-contained task, expected result, and file ownership boundaries' }
                    name = @{ type = 'string'; minLength = 1; maxLength = 80 }
                    yolo = @{ type = 'boolean'; description = 'Child YOLO; defaults to the parent setting. Launch approval discloses this setting.' }
                    allow_write = @{ type = 'boolean'; description = 'Default false. Enable child edits/writes and, if allowed by the parent, shell execution.' }
                }
            }
            Script = { param($a, $ctx) Start-AgentHarnessSubAgent -Arguments $a -Context $ctx }
        }
    }
    $tools.agent_status = @{
        Description = 'Read a saved sub-agent status and final answer by agent_id, or list all saved agents in the working directory when omitted. Reports closed terminals as interrupted. Includes result and work-status file paths for later resumption.'
        Parameters = @{ type = 'object'; additionalProperties = $false; properties = @{ agent_id = $idProperty } }
        Script = {
            param($a, $ctx)
            if ($a.ContainsKey('agent_id')) { Get-AgentHarnessSubAgent -Id $a.agent_id -Context $ctx | ConvertTo-Json -Depth 20 }
            else { ConvertTo-Json -InputObject @(Get-AgentHarnessSubAgent -Context $ctx) -Depth 20 }
        }
    }
    $tools.wait_agent = @{
        Description = 'Wait up to timeout_seconds (default 30, maximum 60) for a sub-agent, then return its latest status and any final answer. A running result means it is still working; wait again when needed.'
        Parameters = @{
            type = 'object'; additionalProperties = $false; required = @('agent_id')
            properties = @{ agent_id = $idProperty; timeout_seconds = @{ type = 'integer'; minimum = 0; maximum = 60 } }
        }
        Script = { param($a, $ctx) Wait-AgentHarnessSubAgent -Arguments $a -Context $ctx | ConvertTo-Json -Depth 20 }
    }
    $tools.stop_agent = @{
        Description = 'Stop a running sub-agent and its child processes, preserving its saved task and work-status files. Requires confirmation unless YOLO. Does not undo completed file changes.'
        RequiresApproval = $true
        Parameters = @{ type = 'object'; additionalProperties = $false; required = @('agent_id'); properties = @{ agent_id = $idProperty } }
        Script = { param($a, $ctx) Stop-AgentHarnessSubAgent -Id $a.agent_id -Context $ctx | ConvertTo-Json -Depth 20 }
    }
    $tools
}
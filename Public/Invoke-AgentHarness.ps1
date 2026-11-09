#requires -Version 7.0
<#
.SYNOPSIS
    Minimal tool-calling agent harness for OpenAI-compatible chat endpoints.

.DESCRIPTION
    Public entry point with reusable helpers in Private/AgentHarness/, integrated with
    Register-FreeModelProvider / Get-FreeModels.

    * Model selection: picks from Get-FreeModels (optionally filtered / interactive),
      or uses a custom model id you pass with -Model.
    * Opt into decision-dependent tools with -DecisionConfigPath (one or more JSON
      packages) or -DecisionConfig (hashtables). -DecisionToolHandlers registers
      host scriptblocks for new tools sharing the configured decision service.
    * Endpoint + API key come from the provider registry ($script:FreeModelProviders):
      chat URI = the registered ChatUri, or the models URI with /models replaced by /chat/completions,
      key = the env var named in the registry. Override with -ChatUri / -ApiKey.
    * Agent loop: send messages -> run requested tools -> feed results back ->
      repeat until the model answers without tool calls (or -MaxIterations).
    * Attach local images, documents and videos with -Attachments. The selected
      provider/model must support the corresponding content types.
      In any prompt, including a continuation, use @attach("path/to/file").
      On Windows, @clipboard attaches the current clipboard screenshot as PNG.
    * Output is verbose by default (trace goes to the host/information stream).
      Use -Quiet to turn it off. The final answer is always returned as output.
    * Loads AGENTS.md from the working directory unless -NoAgentsFile is set.
      -Instructions appends user instructions to the default system prompt.
    * Discovers project skills in .agents/skills and global skills in the module's .agents/skills.
      -SkillPath adds roots, -Skill preloads named skills, and -NoSkills disables them.
    * Use edit_file for exact replacements in existing text files, preserving encoding.
      File writes, edits and raw PowerShell execution require confirmation unless -YOLO is set.
      At approval, enter y/yes to allow, n/no or blank to deny, or type guidance
      to skip the action and remaining tool calls and redirect the agent.
    * Activate servers from the module directory's mcp.json with -McpServer.
      JSON-configured servers are inactive by default. Use '*' for all servers,
      or one or more exact names. Override the file with -McpConfigPath (JSON).
      MCP tools require confirmation unless explicitly auto-approved or -YOLO is set.
    * The ask_user tool collects text, single-choice and multiple-choice answers
      with question titles and descriptions. Questions wait even in -Quiet/-YOLO;
      Escape cancels, and missing interactive consoles return unavailable.
    * The show_interactive_menu tool asks one or several questions in a single call,
      each allowing one or more selections,
      including in -Quiet and -YOLO modes. Escape returns a cancellation result.
    * Sub-agents run in separate visible PowerShell terminals on Windows. They inherit
      -YOLO unless the spawn_agent call overrides it, and cannot spawn further agents.
      Use -NoSubAgents to disable delegation and -MaxSubAgents to limit active children.
    * If a request fails, choose another model or retry without losing the conversation.
      Use -NoModelRecovery to disable recovery prompts in unattended runs.
    * After each final answer, asks whether to continue or stop. Continuing retains
      user messages and the latest final answer, clearing previous tool interactions.
      Use -NoCompletionPrompt to return immediately after the answer.

    Get-AgentHarnessProviderConfig reads the existing provider registry
    ($script:FreeModelProviders). Model selection, menus and logging reuse module commands.

.PARAMETER All
    Include paid and unknown-price models during discovery and recovery.
    Combine with -Pick to choose interactively from the full catalogue.
    By default, discovery and recovery list only free models.

.PARAMETER Prompt
    The user message, as a string or an array of lines (for example Get-Clipboard).
    Arrays are joined with platform newlines, preserving blank lines.
    Include @attach("path/to/file") to attach local files, both
    here and at the next-task prompt. Repeat for multiple files. Use @@attach(...)
    to send the marker as literal text. Paths resolve against WorkingDirectory.
    On Windows, use @clipboard to include the current clipboard image, or
    @@clipboard to send that marker as literal text.

.PARAMETER Attachments
    Local file paths to include with the prompt, relative to WorkingDirectory or
    absolute. Images and videos are encoded as data URLs; text files are included
    as text, and other files use file content parts. Attachment is an alias.
    Files can also be added with @attach("path/to/file") inside any prompt.
    Attachments are retained in History and when continuing with another task.

.PARAMETER NoPromptHistory
    Disable automatic local input recording under WorkingDirectory/.agents/prompts.
    By default, each invocation appends original prompts and interactive replies to
    its own UTF-8 JSONL file. Attachment contents and prior History are not recorded.

.PARAMETER McpServers
    Hashtable mapping server names to explicit configuration hashtables. Use Command
    and Arguments for stdio, or Url for Streamable HTTP. AllowedTools restricts exact,
    case-sensitive server tool names; an empty array exposes none. AutoApproveTools
    skips tool approval for named trusted tools. By default, every MCP call requires
    approval. ProtocolVersion defaults to auto (2026-07-28, with legacy initialization
    fallback). Connections last for this invocation and close on completion or failure.
    See Docs/Invoke-AgentHarness.md for authentication and configuration options.

.PARAMETER SkillPath
    Additional directories whose immediate subfolders contain SKILL.md files.
    Relative paths resolve against WorkingDirectory. Explicit roots override project
    and global skills; duplicate names across explicit roots are excluded as ambiguous.

.PARAMETER GlobalSkillPath
    Optional global skill root, default .agents/skills under the module directory.
    Module installation junctions/symlinks are resolved before deriving this default.
    Pass an empty string to disable the global root. Project discovery remains enabled.
    UserSkillPath is an alias.

.PARAMETER Skill
    Exact names to preload into each task's instructions. Other skills are catalogued
    by name/description and can be loaded on demand through the skill tools.

.PARAMETER NoSkills
    Disable folder discovery and skill tools. NoBuiltinTools also disables skills.
    Neither switch can be combined with explicit Skill selections.

.PARAMETER McpConfigPath
    Path to a JSON file containing a mcpServers object or a bare server map.
    Supports args/env/type/cwd aliases and the same options as -McpServers.
    Relative configuration paths resolve against WorkingDirectory. Relative server
    paths and the default server working directory resolve against the JSON file's
    directory. Cannot be combined with -McpServers. McpConfigFile and McpConfig
    are aliases. With -McpServer and no override, uses mcp.json in the module directory.
    An absent default file means no MCP servers; an explicit missing file is an error.

.PARAMETER McpServer
    Activate named servers from mcp.json or -McpConfigPath. Accepts one or more
    exact configured names, or '*' alone for all. Without this parameter, JSON
    servers are inactive. An explicit -McpServers hashtable is already an opt-in;
    this parameter can further restrict its servers. Unknown names are errors.

.EXAMPLE
    Invoke-AgentHarness 'List the .ps1 files here and say what each one does'

.EXAMPLE
    # Use copied text, including a clipboard result containing multiple lines.
    Invoke-AgentHarness -Prompt (Get-Clipboard) -Provider Inception -Pick -All

.EXAMPLE
    # Select a model that supports the attached media and file formats.
    Invoke-AgentHarness 'Compare these materials' -Attachments './photo.png', './report.pdf', './clip.mp4' -Provider OpenRouter -Pick -All

.EXAMPLE
    # The same syntax also works at the conversation's next-task prompt.
    Invoke-AgentHarness 'Describe this @attach("./photo.png")' -Provider OpenRouter -Pick -All

.EXAMPLE
    # Copy a screenshot first (Windows+Shift+S); also works at the next-task prompt.
    Invoke-AgentHarness 'Explain this screenshot @clipboard' -Provider OpenRouter -Pick -All

.EXAMPLE
    # Pick among free Kilo models whose id/name matches *glm*
    Invoke-AgentHarness 'Summarise README.md' -Provider Kilo -ModelFilter '*glm*'

.EXAMPLE
    # Custom model id (no free-list lookup needed when -Provider is given)
    Invoke-AgentHarness 'Say hi' -Provider Kilo -Model 'z-ai/glm-5:free' -Quiet

.EXAMPLE
    # Choose a free Experiential Labs model (requires EXPLABS_API_KEY)
    Invoke-AgentHarness 'Say hi' -Provider ExperientialLabs -Pick

.EXAMPLE
    # Choose any listed model, including paid models, matching the filter
    Invoke-AgentHarness 'Say hi' -Provider OpenRouter -Pick -All -ModelFilter '*glm*'

.EXAMPLE
    # Choose a Cohere chat model (requires COHERE_API_KEY; pricing is not listed)
    Invoke-AgentHarness 'Say hi' -Provider Cohere -Pick -All

.EXAMPLE
    # Choose an Inception chat model (requires INCEPTION_API_KEY)
    Invoke-AgentHarness 'Say hi' -Provider Inception -Pick -All

.EXAMPLE
    # Custom tool
    $tools = @{
        get_weather = @{
            Description = 'Get the weather for a city'
            Parameters  = @{ type = 'object'; properties = @{ city = @{ type = 'string' } }; required = @('city') }
            Script      = { param($a, $ctx) "Sunny in $($a.city)" }
        }
    }
    Invoke-AgentHarness 'Weather in Delhi?' -Tools $tools

.EXAMPLE
    # Multi-turn: keep the transcript and pass it back
    $r = Invoke-AgentHarness 'My name is Sam' -PassThru -NoCompletionPrompt
    Invoke-AgentHarness 'What is my name?' -History $r.Messages -Provider $r.Provider -Model $r.Model -NoCompletionPrompt
#>

function Invoke-AgentHarness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string[]]$Prompt,

        # --- model selection -------------------------------------------------
        [string]$Provider,                 # registry name (OpenRouter, Kilo, ...)
        [string]$Model,                    # custom model id; skips auto-selection
        [string]$ModelFilter = '*',        # wildcard on id/name when auto-selecting
        [switch]$Pick,                     # choose interactively from Get-FreeModels
        [switch]$All,                      # include paid and unknown-price models
        [ValidateRange(1, [int]::MaxValue)][int]$MaxModelAttempts = 3,        # auto-selected models to try before giving up
        [switch]$NoModelRecovery,          # disable interactive recovery after request failures

        # --- connection overrides -------------------------------------------
        [string]$ChatUri,
        [string]$ApiKey,
        [ValidateRange(1, [int]::MaxValue)][int]$TimeoutSec = 120,
        [Nullable[double]]$Temperature,

        # --- conversation ---------------------------------------------------
        [Alias('Attachment', 'AttachmentPath')][string[]]$Attachments,
        [Alias('SystemPrompt', 'AdditionalInstructions')][string]$Instructions,
        [switch]$NoAgentsFile,             # skip automatic AGENTS.md loading
        [string[]]$SkillPath,              # additional skill roots, relative to WorkingDirectory
        [Alias('UserSkillPath')][AllowEmptyString()][string]$GlobalSkillPath,
        [string[]]$Skill,                  # explicitly preload named skills on each task
        [switch]$NoSkills,                 # disable folder discovery and skill tools
        [object[]]$History,                # transcript from a previous -PassThru run
        [ValidateRange(1, [int]::MaxValue)][int]$MaxIterations = 100,
        [switch]$NoCompletionPrompt,       # return after one task without asking what next
        [switch]$NoPromptHistory,          # disable local prompt/reply journal

        # --- tools ----------------------------------------------------------
        [hashtable]$Tools,                 # extra / overriding tools (see .EXAMPLE)
        [hashtable[]]$DecisionConfig,       # decision tool packages, one per tool
        [string[]]$DecisionConfigPath,      # JSON packages, relative to WorkingDirectory
        [hashtable]$DecisionToolHandlers,   # host-supplied handlers for additional decision tools
        [hashtable]$McpServers,            # named stdio or Streamable HTTP server configurations
        [AllowEmptyCollection()][string[]]$McpServer, # activate selected JSON servers, or '*' for all
        [Alias('McpConfigFile', 'McpConfig')][ValidateNotNullOrEmpty()][string]$McpConfigPath,
        [switch]$NoBuiltinTools,
        [switch]$AllowWrite = $true,       # -AllowWrite:$false disables write_file and edit_file
        [switch]$AllowShell = $true,       # compatibility; -AllowShell:$false disables it
        [switch]$NoShellTool,              # disable run_powershell (NOT sandboxed)
        [switch]$NoSubAgents,              # disable the sub-agent tools
        [ValidateRange(1, 16)][int]$MaxSubAgents = 3,
        [Alias('AutoApprove')][switch]$YOLO, # skip y/N prompts for write/shell
        [string]$WorkingDirectory = (Get-Location).Path,
        [ValidateRange(1, [int]::MaxValue)][int]$MaxToolOutputChars = 8000,

        # --- output ---------------------------------------------------------
        [switch]$Quiet,                    # turn the verbose trace off
        [switch]$NoPromptSound,            # mute notification sounds before user prompts
        [switch]$PassThru                  # return an object instead of just the answer
    )

    # Clipboard and other line-oriented commands can return an array of strings.
    $promptText = $Prompt -join [Environment]::NewLine
    if ([string]::IsNullOrEmpty($promptText)) { throw 'Prompt cannot be empty.' }
    if ($PSBoundParameters.ContainsKey('McpConfigPath') -and $PSBoundParameters.ContainsKey('McpServers')) {
        throw 'Specify either McpConfigPath or McpServers, not both.'
    }

    if ($PSBoundParameters.ContainsKey('DecisionConfig') -and $PSBoundParameters.ContainsKey('DecisionConfigPath')) {
        throw 'Specify either DecisionConfig or DecisionConfigPath, not both.'
    }
    if ($NoBuiltinTools -and ($DecisionConfig.Count -or $DecisionConfigPath.Count)) {
        throw 'Decision tool configuration cannot be combined with NoBuiltinTools.'
    }

    # Reuse the module logger, keeping trace output on the information stream.
    # Capture the module-bound helper before creating a dynamic closure.
    $writeLogMessage = ${function:Write-LogMessage}
    $log = {
        param([string]$Text, [string]$Color = 'Gray')
        & $writeLogMessage -Message $Text -Color $Color -NoTimestamp -Silent:$Quiet
    }.GetNewClosure()

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "Working directory does not exist or is not a directory: $WorkingDirectory"
    }
    if (-not $PSBoundParameters.ContainsKey('GlobalSkillPath')) {
        $GlobalSkillPath = if ($NoSkills -or $NoBuiltinTools) { '' } else { Get-AgentHarnessDefaultSkillPath }
    }

    $ctx = @{
        Root            = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).ProviderPath
        YOLO            = [bool]$YOLO
        AutoApprove     = [bool]$YOLO # Compatibility for existing custom tools.
        Quiet           = [bool]$Quiet
        NoPromptSound   = [bool]$NoPromptSound
        AllowWrite      = [bool]$AllowWrite
        AllowShell      = [bool]($AllowShell -and -not $NoShellTool)
        MaxSubAgents    = $MaxSubAgents
        SubAgents       = [Collections.Generic.List[string]]::new()
        SubAgentOptions = @{
            Instructions = $Instructions; NoAgentsFile = [bool]$NoAgentsFile
            NoSkills = [bool]($NoSkills -or $NoBuiltinTools)
            GlobalSkillPath = $GlobalSkillPath
            MaxIterations = $MaxIterations; MaxToolOutputChars = $MaxToolOutputChars
            TimeoutSec = $TimeoutSec; NoPromptSound = [bool]$NoPromptSound
        }
        SubAgentApiKey  = $ApiKey
    }

    if (-not $NoPromptHistory) {
        $sessionId = [guid]::NewGuid().ToString('N')
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
        $ctx.PromptHistory = @{
            SessionId = $sessionId; RelativePath = ".agents/prompts/$stamp-$sessionId.jsonl"
            Sequence = 0; Failed = $false; Path = $null
        }
    }
    Write-AgentHarnessPromptHistory -Context $ctx -Type 'initial_prompt' -Text $promptText -Data @{ attachments = @($Attachments) }

    $ctx.DecisionState = New-AgentHarnessDecisionState -Definition $DecisionConfig -Path $DecisionConfigPath -Handlers $DecisionToolHandlers -Root $ctx.Root
    $ctx.SkillState = New-AgentHarnessSkillState -WorkingDirectory $ctx.Root -SkillPath $SkillPath -Skill $Skill `
        -GlobalSkillPath $GlobalSkillPath -Disabled:($NoSkills -or $NoBuiltinTools)
    $ctx.SubAgentOptions.Skill = @($ctx.SkillState.Explicit)
    $ctx.SubAgentOptions.SkillPath = @($ctx.SkillState.Roots | Where-Object Priority -eq 2 | ForEach-Object { $_.Path })

    if ($GlobalSkillPath) { $ctx.SubAgentOptions.GlobalSkillPath = [IO.Path]::GetFullPath($GlobalSkillPath, $ctx.Root) }
    if ($null -ne $Temperature) { $ctx.SubAgentOptions.Temperature = [double]$Temperature }
    if (-not $PSBoundParameters.ContainsKey('McpServers')) {
        $McpServers = @{}
        if ($PSBoundParameters.ContainsKey('McpConfigPath') -or $McpServer.Count) {
            $mcpConfigOptions = @{ WorkingDirectory = $ctx.Root }
            if ($PSBoundParameters.ContainsKey('McpConfigPath')) { $mcpConfigOptions.Path = $McpConfigPath }
            $McpServers = Read-AgentHarnessMcpConfig @mcpConfigOptions
        }
        $McpServers = Select-AgentHarnessMcpServers -Servers $McpServers -Name $McpServer
    }
    elseif ($PSBoundParameters.ContainsKey('McpServer')) {
        $McpServers = Select-AgentHarnessMcpServers -Servers $McpServers -Name $McpServer
    }

    $systemPrompt = Get-AgentHarnessSystemPrompt -WorkingDirectory $ctx.Root `
        -AdditionalInstructions $Instructions -NoAgentsFile:$NoAgentsFile -SkillState $ctx.SkillState
    $messages = New-AgentHarnessMessages -SystemPrompt $systemPrompt -Prompt $promptText -History $History `
        -Attachments $Attachments -WorkingDirectory $ctx.Root

    $candidates = [Collections.Generic.List[object]]::new()
    $candidates.AddRange([object[]]@(Get-AgentHarnessCandidates -Provider $Provider -Model $Model `
                -ModelFilter $ModelFilter -ChatUri $ChatUri -Pick:$Pick -All:$All -Log $log))
    $state = @{ Candidates = $candidates; Locked = $false; Attempts = 0; All = [bool]$All }

    $toolTable = Get-AgentHarnessToolTable -Tools $Tools -NoBuiltinTools:$NoBuiltinTools `
        -AllowWrite:$AllowWrite -AllowShell:($AllowShell -and -not $NoShellTool) -AllowSubAgents:(-not $NoSubAgents) -AllowSkills:(-not $NoSkills) -DecisionState $ctx.DecisionState

    $mcpConnections = [Collections.Generic.List[hashtable]]::new()
    try {
        if ($McpServers) {
            Get-AgentHarnessMcpTools -Servers $McpServers -ToolTable $toolTable -Connections $mcpConnections -WorkingDirectory $ctx.Root
        }
        $toolSpecs = @(ConvertTo-AgentHarnessToolSpec -ToolTable $toolTable)
        & $log '== Agent harness ==' 'Cyan'
        & $log ("   tools   : " + ($(if ($toolTable.Count) { $toolTable.Keys -join ', ' } else { '(none)' }))) 'DarkGray'
        & $log "   workdir : $($ctx.Root)" 'DarkGray'
        & $log "   prompt  : $(Limit-AgentHarnessText $promptText 200)" 'DarkGray'

        # Each task has its own turn budget; totals cover the entire invocation.
        $iteration = 0
        $taskIterations = 0
        $final = $null; $used = $null; $tokIn = 0; $tokOut = 0
        $totalTimer = [Diagnostics.Stopwatch]::StartNew()

        while ($taskIterations -lt $MaxIterations) {
            $iteration++
            $taskIterations++
            $turn = Invoke-AgentHarnessTurn -State $state -Messages $messages -ToolSpecs $toolSpecs `
                -ChatUri $ChatUri -ApiKey $ApiKey -TimeoutSec $TimeoutSec -Temperature $Temperature `
                -MaxModelAttempts $MaxModelAttempts -Iteration $iteration -Log $log -NoModelRecovery:$NoModelRecovery
            $response = $turn.Response
            $used = $turn.Candidate
            $ctx.SubAgentProvider = $used.Provider
            $ctx.SubAgentModel = $used.Id
            $ctx.SubAgentConnection = Get-AgentHarnessProviderConfig -Provider $used.Provider -ChatUri $ChatUri
            $msg = $response.choices[0].message
            $text = [string]$msg.content

            $served = if ($response.PSObject.Properties['model'] -and $response.model) { " served-by=$($response.model)" } else { '' }
            $usage = ''
            if ($response.PSObject.Properties['usage'] -and $response.usage) {
                $tokIn += [int]$response.usage.prompt_tokens
                $tokOut += [int]$response.usage.completion_tokens
                $usage = " tokens in/out=$([int]$response.usage.prompt_tokens)/$([int]$response.usage.completion_tokens)"
            }
            & $log ("   {0} ms,{1}{2} finish={3}" -f [int]$turn.ElapsedMilliseconds, $usage, $served, $response.choices[0].finish_reason) 'DarkGray'

            foreach ($rp in 'reasoning', 'reasoning_content') {
                if ($msg.PSObject.Properties[$rp] -and $msg.$rp) {
                    & $log "   [thinking] $(Limit-AgentHarnessText ([string]$msg.$rp) 500)" 'DarkGray'
                    break
                }
            }

            $calls = @(ConvertTo-AgentHarnessToolCall -Calls $msg.tool_calls)
            # No tool calls -> this is the final answer
            if (-not $calls.Count) {
                $final = $text
                $messages.Add(@{ role = 'assistant'; content = $text })
                if ($NoCompletionPrompt) { break }
                $retryPrompt = $false
                while ($true) {
                    $nextPrompt = Read-AgentHarnessNextPrompt -Answer $final -NoPromptSound:$NoPromptSound -SkipAnswer:$retryPrompt -Context $ctx
                    if ([string]::IsNullOrWhiteSpace($nextPrompt)) { break }

                    try {
                        Update-AgentHarnessSkills -State $ctx.SkillState
                        $systemPrompt = Get-AgentHarnessSystemPrompt -WorkingDirectory $ctx.Root `
                            -AdditionalInstructions $Instructions -NoAgentsFile:$NoAgentsFile -SkillState $ctx.SkillState
                        $nextMessages = New-AgentHarnessMessages -SystemPrompt $systemPrompt -Prompt $nextPrompt `
                            -History $messages.ToArray() -KeepLatestAnswer -WorkingDirectory $ctx.Root
                        break
                    }
                    catch {
                        Write-AgentHarnessBlock -Title 'Invalid prompt' -Text $_.Exception.Message -Color Yellow
                        $retryPrompt = $true
                    }
                }
                if ([string]::IsNullOrWhiteSpace($nextPrompt)) { break }

                $messages = $nextMessages
                $state.Candidates.Clear()
                $state.Candidates.Add($used)
                $state.Attempts = 0
                $taskIterations = 0
                $final = $null
                continue
            }

            if ($text) { & $log "   assistant: $text" 'Gray' }

            $messages.Add(@{ role = 'assistant'; content = ($text ? $text : $null); tool_calls = $calls })
            foreach ($call in $calls) {
                if ($ctx.ApprovalFeedback) {
                    # Resolve every tool-call ID before adding the user's new instructions.
                    $result = @{
                        role = 'tool'; tool_call_id = $call.id; name = $call.function.name
                        content = 'Skipped: the user supplied guidance at an earlier approval prompt. Reconsider this action using the new instructions.'
                    }
                }
                else {
                    $result = Invoke-AgentHarnessToolCall -Call $call -ToolTable $toolTable -Context $ctx `
                        -MaxOutputChars $MaxToolOutputChars
                }
                $messages.Add($result)
            }
            if ($ctx.SkillPromptDirty) {
                $messages[0].content = Get-AgentHarnessSystemPrompt -WorkingDirectory $ctx.Root `
                    -AdditionalInstructions $Instructions -NoAgentsFile:$NoAgentsFile -SkillState $ctx.SkillState
                $ctx.SkillPromptDirty = $false
            }
            if ($ctx.ApprovalFeedback) {
                $messages.Add(@{ role = 'user'; content = $ctx.ApprovalFeedback })
                $ctx.ApprovalFeedback = $null
            }
        }
        $totalTimer.Stop()

        if ($null -eq $final) {
            Write-Warning "Stopped after $MaxIterations iterations without a final answer."
            $final = ''
        }

        & $log ("== done: {0} turn(s), {1:N1}s, tokens in/out={2}/{3}, model=[{4}] {5} ==" -f `
                $iteration, $totalTimer.Elapsed.TotalSeconds, $tokIn, $tokOut, $used.Provider, $used.Id) 'Cyan'

        if ($PassThru) {
            [pscustomobject]@{
                Answer            = $final
                Provider          = $used.Provider
                Model             = $used.Id
                Iterations        = $iteration
                PromptTokens      = $tokIn
                CompletionTokens  = $tokOut
                Messages          = $messages.ToArray()
                PromptHistoryPath = $(if ($ctx.PromptHistory) { $ctx.PromptHistory.Path })
            }
        }
        else { $final }
    }
    finally {
        foreach ($connection in $mcpConnections) { Close-AgentHarnessMcpConnection -Connection $connection }
    }
}
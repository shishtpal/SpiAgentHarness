# SpiAgentHarness

An independent PowerShell 7.0+ agent harness with local tools, MCP servers, folder skills, child agents, provider discovery, and decision models.

```powershell
Import-Module 'D:\SchoolPi\SpiAgentHarness\SpiAgentHarness.psd1'
Invoke-AgentHarness 'Summarise README.md' -Provider Kilo -Pick
```

The module is self-contained. Import does not load SpiPowershell, run credential or bootstrap scripts, contact providers, or start MCP servers. Credentials come from provider-specific environment variables or explicit parameters at request time.

Assistant responses stream by default. Use `-NoStream` for buffered requests or `-Quiet` to suppress live text. The pipeline still returns one completed answer or `-PassThru` result; interrupted streamed messages are not automatically replayed and their tool calls never execute. See [streaming responses](Docs/Invoke-AgentHarness.md#streaming-responses).

For long builds and tests, the agent can use `start_powershell`, `poll_powershell` and `stop_powershell` with invocation-scoped IDs, configurable deadlines and bounded output. `run_powershell` still waits synchronously (default 60 seconds) and now accepts a custom deadline. See [long-running commands](Docs/Invoke-AgentHarness.md#long-running-powershell-commands).

The `run_python` tool runs Python 3 snippets with bounded output and deadlines. It tries uv first, then Python on PATH, then `SPI_AGENT_PYTHON`. uv can download Python and requested packages. See [Python code execution](Docs/Invoke-AgentHarness.md#python-code-execution).

Public commands:

- [Invoke-AgentHarness](Docs/Invoke-AgentHarness.md)
- [Get-McpServer](Docs/Get-McpServer.md)
- [Get-FreeModels](Docs/Get-FreeModels.md)
- Register-FreeModelProvider (see [provider registration](Docs/Get-FreeModels.md))
- [Invoke-DecisionModel](Docs/Invoke-DecisionModel.md)
- [Get-DecisionModels](Docs/Get-DecisionModels.md)

Menus, logging, sound, and all runtime helpers are private. Provider registration belongs to this module's own registry.

The built-in [Respan gateway provider](Docs/Invoke-AgentHarness.md#respan) uses `RESPAN_API_KEY` for chat. Discover models with `Get-FreeModels -Provider Respan -All`, then choose one with `Invoke-AgentHarness 'Say hi' -Provider Respan -Pick -All`.

Global skills default to `.agents/skills` beneath the installed module. MCP configuration defaults to `mcp.json` beside the manifest and is local configuration excluded from Git. Use `Config/AgentHarness.mcp.example.json` as an example. Servers require explicit `-McpServer` activation. Decision tools are configured with JSON packages; see [Decision tools](Docs/DecisionTools.md).

User prompts and interactive replies are saved automatically to one JSONL file per invocation under the working directory's `.agents/prompts/`. Use `-NoPromptHistory` to disable recording, or `-PassThru` to obtain `PromptHistoryPath`. Attachment contents are excluded. See [local prompt history](Docs/Invoke-AgentHarness.md#local-prompt-history).

Save conversation context explicitly with `/save-context raw|pruned|summary <path>` at the completion prompt, or `-SaveContextPath <path> -ContextMode Raw|Pruned|Summary`. Resume later with `-ContextPath <path>` and a new prompt. Raw and pruned saves are local; summary saves make an additional model request. See [saving and loading context](Docs/Invoke-AgentHarness.md#saving-and-loading-conversation-context).

Use `-SaveContextOnFailure` to keep raw recovery context on provider failure or iteration exhaustion. No `-SaveContextPath` is needed: the harness generates and reports a unique path under `.agents/harness/checkpoints/`. Resume it with `-ContextPath` and a new prompt; historical tools are not replayed.

Opt into automatic in-task retirement with `-AutoCompact` (default budget: 131072 estimated characters, or 128K). It archives before replacing old tool payloads or historical media and preserves user text and raw history. `-AutoCompact -NoAutoCompactArchive` measures only. See [automatic compaction](Docs/Invoke-AgentHarness.md#automatic-in-task-compaction).

[REA integration](Docs/REA.md) uses an already installed local CLI for static JavaScript/Electron and managed .NET inspection, with a scoped MCP allowlist, a module-owned workflow and an opt-in synthetic smoke test. It installs no software.

Verify with mocked providers and synthetic files:

```powershell
pwsh -NoProfile -File ./Tests/Invoke-ModuleIntegration.Tests.ps1
pwsh -NoProfile -File ./Tests/Invoke-AgentHarness.Tests.ps1
pwsh -NoProfile -File ./Tests/Invoke-DecisionModel.Tests.ps1
pwsh -NoProfile -File ./Tests/Show-InteractiveMenu.Tests.ps1
pwsh -NoProfile -File ./Tests/Invoke-Sound.Tests.ps1
```

Tests use temporary module fixtures and do not read local MCP configuration or user skills. The opt-in MCP smoke script connects to the selected server; it is separate from the automated suite.
# REA static application inspection

SpiAgentHarness can use an existing REA CLI over local stdio MCP. This integration is verified against REA 6.8.0 and focuses on static JavaScript/Electron applications and managed .NET assemblies. It does not require a native decompiler for these routes.

## Use the configured server

```powershell
Import-Module 'D:\SchoolPi\SpiAgentHarness\SpiAgentHarness.psd1'
Get-McpServer -Name rea

Invoke-AgentHarness 'Use REA to explain the IPC handlers in D:/samples/electron-app' `
    -McpServer rea -Skill reverse-engineer-anything -MaxToolOutputChars 32768

Invoke-AgentHarness 'Use REA to inspect the declared types and CIL in D:/samples/Example.dll' `
    -McpServer rea -Skill reverse-engineer-anything -MaxToolOutputChars 32768
```

Choose a model/provider with function calling as usual. MCP tool descriptions and returned findings go to that selected model provider. The application analysis itself runs locally. REA reads the selected JavaScript/ASAR or PE/CLI bytes without executing the application.

The shared module-root `mcp.json` is local and ignored by Git. Its `rea` entry starts the existing CLI with the argument `mcp`; importing the module or listing servers does not launch it. Select `-McpServer rea` for each invocation. Existing browser-server and other registrations are independent. A fresh invocation picks up configuration or tool changes.

The module-owned workflow is `.agents/skills/reverse-engineer-anything/SKILL.md`. It is a concise adaptation of the installed REA workflow for these two static routes. It deliberately omits the upstream native, runtime, browser, device and installer workflows. Skill discovery refreshes on the next task/invocation; `-Skill reverse-engineer-anything` explicitly preloads it.

## Configuration and architecture

```text
Invoke-AgentHarness + local REA workflow
    -> existing MCP client and per-tool approval
    -> installed rea CLI, argument: mcp
    -> static JavaScript/Electron or managed PE/CLI inspection
    -> retained Evidence summaries and selected pages
```

[The portable example](../Config/AgentHarness.rea.mcp.example.json) uses `rea` from PATH. The local configuration may instead use the resolved executable path, including an existing Vite+ `rea.exe` shim. No package runner or setup command is launched. There is no module import hook, public command, or dependency on SpiPowershell.

To use the example independently of the shared configuration:

```powershell
Invoke-AgentHarness 'Inspect D:/samples/Example.dll with REA' `
    -McpConfigPath 'D:/SchoolPi/SpiAgentHarness/Config/AgentHarness.rea.mcp.example.json' `
    -McpServer rea -Skill reverse-engineer-anything -MaxToolOutputChars 32768
```

Configuration sources are not merged. To activate REA alongside an existing browser server, keep both entries in the shared file and pass `-McpServer rea,browser`.

The example allows 13 existing tools: JavaScript application analysis, feature/semantic tracing and comparisons; managed artifact/member/native-declaration inspection, comparison and graph projection; analysis views; session status and Evidence retrieval. The harness's exact allowlist excludes runtime capture, application/device execution and extraction tools. It is a model-facing restriction, not an operating-system sandbox. MCP calls require the normal approval; `autoApproveTools` is empty.

Settings used for the installed release:

| Setting | Value | Purpose |
|---|---|---|
| `REA_MCP_INPUT_SCHEMA_PROFILE` | `compact` | Reduce provider-facing input schemas. REA validates canonical inputs. |
| `REA_MCP_OUTPUT_SCHEMA_PROFILE` | `off` | Omit discovery output schemas, which the harness does not consume. Actual text and structured Evidence remain available. |
| `timeoutSec` | `360` | Allow headroom beyond the JavaScript analyzer's default 300-second per-source deadline. This is a per-MCP-request budget. |
| `allowedTools` | Explicit static list | Expose only the selected workflows to the model. |
| `autoApproveTools` | `[]` | Keep per-call approval. |

Keep upfront catalog discovery. The harness does not implement dynamic tool-list refresh. The installed 6.8.0 package still advertises its full catalog; use the harness allowlist rather than relying on newer repository-main tool-family settings. This release accepts only `full` or `off` for the output-schema profile; `compact` output schemas from newer documentation fail startup. Follow installed schemas and verified behavior when upstream main differs.

Do not set `HOPPER_TARGET_PATH` for these target-free operations. An inherited value can pre-open an unrelated target at server startup; remove that setting before starting this workflow. An empty string is invalid in REA 6.8.0.

## Evidence and limits

Start application analysis, managed artifact inspection and managed member inspection with `detail: "summary"`. The summary's `normalized_result.parent_evidence_id` identifies complete Evidence retained on the same connection. Use `inspect_analysis_view` with that ID and a small selected page. The skill includes examples for modules and managed methods.

The harness renders both text and structured content, so the same REA Evidence can appear twice. It also truncates results at `MaxToolOutputChars` (8,000 by default). The examples use 32,768 characters, but summaries and selected pages remain preferable to large complete records. A truncation marker means JSON/Evidence is incomplete; request a smaller view. Retained IDs do not survive the connection closing. Static CIL is not original C# source, and static declarations do not prove runtime behavior or native implementations.

This setup does not validate NativeAOT, native decompilers, live Electron/browser inspection or every model gateway's schema handling. Optional prerequisites are not installed automatically. The owner manages the already installed CLI; ask before installing/updating any package or dependency. After an update, recheck `rea --version` and rerun the explicit smoke test before relying on a changed tool catalog.

## Verify without a live model

```powershell
# Default is a skip; no REA process starts.
pwsh -NoProfile -File ./Tests/Invoke-AgentHarness.ReaSmoke.ps1

# Explicit opt-in to the existing installed CLI and the portable static allowlist.
pwsh -NoProfile -File ./Tests/Invoke-AgentHarness.ReaSmoke.ps1 -Run

# Exercise only the rea entry in a selected real configuration; never copies it.
pwsh -NoProfile -File ./Tests/Invoke-AgentHarness.ReaSmoke.ps1 -Run `
    -McpConfigPath 'D:/SchoolPi/SpiAgentHarness/mcp.json'
```

The smoke test creates isolated synthetic JavaScript/Electron files in the ignored `.agent-harness/rea-smoke-*` directory and compiles a small synthetic managed DLL using PowerShell's bundled compiler. It mocks the model transport, then exercises real discovery, static analysis, retained Evidence paging, an expected missing-file error, unchanged-input checks and process cleanup. It does not copy global skills, contact a model, install dependencies or inspect user applications. It remains separate from the automated fixture suites. Run it from an ordinary local PowerShell session if a desktop sandbox blocks REA's filesystem/process controls; do not change the controls or install packages to bypass a sandbox error.

To disconnect REA, stop the active invocation and remove only the `rea` configuration entry. Remove the `reverse-engineer-anything` workflow folder if no longer wanted. This does not uninstall or update the user's CLI or alter other MCP servers.
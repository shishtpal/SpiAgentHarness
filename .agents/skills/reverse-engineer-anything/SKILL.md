---
name: reverse-engineer-anything
description: Inspect shipped JavaScript/Electron trees or ASAR archives and managed .NET assemblies with the existing local REA MCP server. Use for static application behavior, metadata, CIL, references, or build comparisons; use normal repository tools for ordinary source-code review.
---

# Static application inspection with REA

This harness workflow targets REA 6.8.0 and static JavaScript/Electron and .NET inspection. Read [the static workflows](references/static-workflows.md) for retained Evidence, paging, and focused examples. Follow the connected server's actual schemas when they differ from an example.

1. Establish the user's target path and question. Resolve the path on the machine running REA. Analyze only the selected artifact and supporting files needed to answer that question.
2. Use the advertised `mcp_rea_*` tools. An ASAR or extracted JavaScript/Electron tree starts with `mcp_rea_analyze_javascript_application`; a managed PE/CLI assembly starts with `mcp_rea_inspect_managed_artifact`. These target-free tools do not need `open_binary` or a native engine.
3. Request `detail: "summary"` on the initial analysis and managed member inspection. Keep the returned `normalized_result.parent_evidence_id` on this connection, then use `mcp_rea_inspect_analysis_view` for selected rows and small pages. Do not paste an abbreviated or truncated record back as complete Evidence.
4. Follow only findings relevant to the user's question. For JavaScript, select module paths, imports, IPC, routes, or semantic relations. For .NET, select exact type names and inspect declared members, CIL and native boundary declarations. Compare builds using the recorded artifact identities and matching selections.
5. Report concrete observations with paths, members, locations and Evidence IDs. Carry forward coverage, unresolved references and limitations. Static relationships do not establish that a branch ran, a route is reachable, or a P/Invoke implementation behaves as declared. CIL is not recovered original C#.

If the model's tool list lacks `mcp_rea_*`, explain that a new invocation needs `-McpServer rea -Skill reverse-engineer-anything`. Do not run setup for Codex or another client to repair this harness. If an advertised tool is blocked, inspect the harness allowlist and approval result before proposing a change. Discovery is fixed for an invocation; configuration changes require a new invocation.

Use the already installed `rea` CLI only when a CLI fallback is needed. Never run package acquisition, updates, setup installers, `npx`, `vp install`, or dependency installation without the user's explicit permission. Report a missing prerequisite and let the user install it. Native decompilation, runtime capture, browser sessions, instrumentation, recovery tools and device operations are outside this configured workflow.

Before retrying a host timeout, determine whether the existing invocation stopped and whether retained Evidence is available. Do not automatically repeat a long analysis or assume a transport timeout stopped its worker. When output contains `[truncated ...]`, request a smaller view or restart with a larger `-MaxToolOutputChars`; never treat truncated JSON as a complete record. A new connection loses unsaved retained Evidence.

This is a scoped harness adaptation of the installed REA workflow, not a copy of its full native/runtime catalog. Upstream guidance: [REA](https://github.com/morluto/rea).
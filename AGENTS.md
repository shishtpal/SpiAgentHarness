# Repository instructions

- Do not stage, unstage, or commit changes. Preserve the user's index.
- Never read, search, print, diff, or execute `Initialize.ps1`, including any external copy. Never expose credentials in output, documentation, tests, or memory.
- Actively recall relevant browser-server memory before changes and save durable verified outcomes afterward.
- When asked for a plan, include architecture design. Ask about missing user requirements instead of guessing them.
- Keep SpiAgentHarness independent of SpiPowershell. Bundle dependencies here; shared console helpers stay private under `Private/Console/` and `Private/Sound/`.
- Keep public entry points in `Public/<FunctionName>.ps1`; feature helpers belong under `Private/`. The loader defines functions before initializing the module-owned provider registry and completers.
- List new public functions in `FunctionsToExport`; use `Update-Manifest.ps1` and review its diff. Do not export private helpers or add import-time bootstrap, credential scripts, server connections, or provider requests.
- Maintain PowerShell 7.0 compatibility. Follow `.editorconfig`: four spaces, UTF-8, CRLF, no trailing whitespace or final newline.
- Run `Tests/Invoke-ModuleIntegration.Tests.ps1`, `Tests/Invoke-AgentHarness.Tests.ps1`, and `Tests/Invoke-DecisionModel.Tests.ps1` with `pwsh -NoProfile -File` after runtime or module integration changes. Run console dependency tests when those helpers change.
- Use isolated fixtures, mocked provider requests, and synthetic files. Never send repository contents or credentials to live providers. Check normal Continue preference and terminating errors; preserve JSON arrays so tool arguments accept only JSON objects.
- Keep local `mcp.json` untracked, and never print its values. Do not copy user configuration or global skills into automated fixtures. Live MCP smoke tests require explicit opt-in.
- Update relevant Docs when behavior or usage changes. Check `git diff --check` and report results and material limitations.
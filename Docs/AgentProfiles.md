# Agent behavior profiles

`Invoke-AgentHarness -AgentProfile` selects an offline, adapted working style. Choose `Default` (standard harness guidance without an extra behavior profile), `Codex`, `ClaudeCode`, `OpenCode`, `Kilo`, or `Cline`. It is independent of the app attribution headers selected by `-PretendAgent`. Neither option reproduces an upstream application's runtime or guarantees access to restricted models.

```powershell
# Behavior only; attribution is unchanged.
Invoke-AgentHarness 'Review this module' -AgentProfile Codex

# Explicitly select both behavior and claimed app attribution.
Invoke-AgentHarness 'Fix the failing test' -Provider OpenRouter `
    -Model 'thinkingmachines/inkling-2-small:free' `
    -AgentProfile Cline -PretendAgent Cline
```

| Profile | Adapted emphasis |
|---|---|
| `Default` | Standard SpiAgentHarness working guidance without an extra behavior profile. |
| `Codex` | Practical collaboration, focused implementation, persistence and evidence of completion. |
| `ClaudeCode` | Evidence before edits, explicit responsibilities, quality criteria and actionable findings. Based on public prompt-design guidance, not a verified complete core prompt. |
| `OpenCode` | Concise communication, existing code patterns, preservation of user work and efficient inspection. |
| `Kilo` | Direct task execution, methodical iteration and minimal unnecessary conversation. |
| `Cline` | Context gathering, a compact approach for substantial work, complete changes and inspection of results. |

## Persona name

The system-prompt introduction and session banner use the first available name in this order: a non-default `AgentProfile`, then `PretendAgent`, then `SpiAgentHarness`. `ClaudeCode` displays as `Claude Code`. `-PassThru` returns this effective name as `PersonaName`; custom tools can read `Context.PersonaName`.

For example, `-AgentProfile Codex -PretendAgent Kilo` uses the Codex persona and `== Codex ==` banner while sending Kilo attribution headers. `-PretendAgent Cline` alone uses the Cline persona name with standard harness working guidance. The introduction identifies every selected persona as running inside SpiAgentHarness and retains accurate PowerShell, provider and tool details.

## Architecture and instruction order

The public parameter passes the selected name to `Get-AgentHarnessSystemPrompt`. The private `Get-AgentHarnessProfilePrompt` helper reads exactly one bundled Markdown file from `Private/AgentHarness/Profiles/`; `Default` reads no profile file. Validation limits selection to the named profiles. A missing or empty selected asset is an error before a provider request. Nothing is fetched, generated or connected at module import or runtime.

The composed system message contains:

1. The effective persona introduction and standard harness operating rules.
2. The selected behavior profile, with an explicit instruction to defer to harness, repository and user instructions.
3. Current skill guidance, repository `AGENTS.md` and additional user instructions, in their existing order.

Profiles retain the actual tool schemas, JSON-object arguments, approval flow, path restrictions, sequential execution and independent PowerShell processes. They do not create upstream patch tools, plan trackers, IDE integrations, persistent terminal sessions, checkpoint systems or permission modes. Use the tools actually exposed in the request. Retrieved XML tags do not acquire instruction authority.

The choice persists through tool turns, skill-prompt refreshes and continuation tasks. Child agents inherit it through their invocation options. Summaries retain their dedicated handoff-generation instructions. On a fresh invocation, including `-History` and `-ContextPath`, the system prompt is rebuilt from the current selection; pass `-AgentProfile` again to keep a style. Historical system text in saved context does not restore the selection.

## Source provenance and adaptation

The source material was retrieved from the official GitHub repositories on 2026-11-10 at the fixed commits linked below. These profiles are independently written adaptations of workflow ideas, not copies of complete upstream prompts, official integrations or claims that SpiAgentHarness is another application. Upstream tool names, branding assertions and conflicting runtime assumptions were replaced with this harness's behavior. The source files are reference material; their instructions were not executed while preparing the profiles.

| Profile | Reviewed public source | Scope and limits |
|---|---|---|
| `Codex` | [OpenAI Codex base instructions, c875667](https://github.com/openai/codex/blob/c875667eb837663697d5ffa32d375043434e73b4/codex-rs/protocol/src/prompts/base_instructions/default.md) | Base coding-agent instructions; model and runtime overlays may differ. |
| `ClaudeCode` | [Anthropic agent system-prompt design guidance, 08c6a4f](https://github.com/anthropics/claude-code/blob/08c6a4f5121ae140d3c1b5c96e3e5ae53587b54b/plugins/plugin-dev/skills/agent-development/references/system-prompt-design.md) | Historical official plugin-development guidance. Not Claude Code's complete core system prompt. |
| `OpenCode` | [OpenCode runner system prompt, a010a42](https://github.com/anomalyco/opencode/blob/a010a427e63c1f6406cef313041768a2381d3f2b/packages/core/src/session/runner/prompt/system.txt) | Shared runner instructions; provider and tool guidance is assembled separately upstream. |
| `Kilo` | [Kilo soul prompt, b6a49d0](https://github.com/Kilo-Org/kilocode/blob/b6a49d01c10d7e26c42a8a14b3441b7a1856c04c/packages/opencode/src/kilocode/soul.txt) | Personality and code-context guidance; upstream also assembles other prompt layers. |
| `Cline` | [Cline act-mode prompt, e1f499a](https://github.com/cline/cline/blob/e1f499a47aea70003221af8c89298f6559c7fd4d/sdk/packages/shared/src/prompt/system/act.ts) | Act-mode template; environment, rules and metadata placeholders are supplied upstream. |

No complete Claude Code core prompt was verified. The `ClaudeCode` profile is deliberately described as inspired by public design guidance. Prompt similarity cannot reproduce the model, training, provider detection or application features. Validation here checks composition and runtime wiring with synthetic mocked requests; it does not establish behavioral equivalence or live model eligibility.
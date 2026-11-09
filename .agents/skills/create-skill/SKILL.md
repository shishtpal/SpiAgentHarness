---
name: create-skill
description: Create or add folder-based skills for the PowerShell agent harness. Use when the user asks to turn a repeatable workflow into a SKILL.md, add an existing skill folder, or update an existing skill's instructions and resources.
---

# Create or Add a Folder Skill

Produce a small, discoverable skill that changes the agent's decisions for a specific workflow. Use the user's request and existing examples; ask only when missing information materially changes the skill's scope or behavior.

## Choose the Destination

- Honor an explicit destination and scope. Otherwise use the current project's `.agents/skills/<skill-name>/`. When WorkingDirectory is the SpiAgentHarness module directory, project and default global roots are the same directory.
- For a global addition, use the configured `GlobalSkillPath`. Its default is `.agents/skills` beneath the installed SpiAgentHarness module, independent of WorkingDirectory. Here that is `D:\SchoolPi\SpiAgentHarness\.agents\skills`. Resolve another installation from supplied configuration or loaded module metadata rather than assuming this machine's path.
- Additional `SkillPath` roots take precedence over project skills, then global skills. Check the catalog and destination for a conflicting name before creating or copying. Explain an intended override; do not silently replace an unrelated skill or create an ambiguous duplicate across roots at the same priority.
- Respect available file boundaries and normal write approvals. Discovery of a global folder does not grant permission to write there. If the requested destination is unavailable to the exposed tools, report the boundary rather than bypassing a rejected path.
- Inspect an existing target before updating it. Preserve unrelated instructions, resources and user changes. Never stage, unstage or commit as part of skill creation unless the user's repository rules and explicit request allow it.

## Create a New Skill

Start with one folder and `SKILL.md`. Add other files only when the workflow needs them:

```text
skill-name/
    SKILL.md
    scripts/       # optional deterministic helpers
    references/    # optional details read only when needed
    assets/        # optional templates or output resources
```

Use this minimal entry point, replacing every example value:

```markdown
---
name: review-example
description: Review example project files using the team's specific checks. Use when the user requests that review workflow.
---

# Review Example

Read the relevant project instructions and selected files. Apply the workflow's
specific checks, verify the result and report actionable findings.
```

- Use a folder matching the skill name: 1..64 lowercase letters, digits and single hyphens; no leading/trailing or repeated hyphens. `name` and a nonblank `description` of at most 1024 characters are required.
- Keep frontmatter compatible with the harness's YAML subset. Use plain strings, single-quoted strings with doubled apostrophes, JSON-compatible double-quoted strings, or an indented description block using `|`, `|-`, `>` or `>-`. Quote values containing colon-space or YAML-like collection/tag/anchor syntax. Do not evaluate metadata as code.
- Describe the actual capability and when it applies. Add exclusions only to prevent likely misrouting. Put routing information in the description; put the workflow in the body. The body must be nonblank.
- Assume the agent already knows general tasks. Include the decisions, input requirements, constraints and verification that are specific to this workflow. Remove generic advice, repeated instructions and unrelated examples.
- Preserve user intent and authorization. Reuse choices already supplied. Distinguish preparation from external actions; require only missing authorization and existing tool approvals. For actions with uncertain outcomes, define how to reconcile success before retrying and when to stop.
- Use tool names actually exposed in the target environment. For MCP dispatchers, discover underlying schemas and call through the exposed dispatcher. Do not invent tools or assume a fixed server prefix.
- Link supporting resources by paths relative to the skill folder and say when to read them. Keep large conditional procedures in references instead of loading everything on every task.
- Scripts are optional. Add them for concrete repeated or fragile operations; validate them with synthetic inputs in an isolated directory. Discovery and instruction loading never execute them automatically.
- Do not add scaffolding, placeholder resources, copied manuals, extra README files or UI metadata without a concrete need. The harness does not interpret `agents/openai.yaml` invocation policies; do not promise behavior it cannot enforce. Preserve existing optional metadata when importing or updating a skill.

## Add an Existing Skill

- Inspect the source `SKILL.md` and only the supporting files needed for its workflow. Follow repository exclusions; do not read or copy credentials, prohibited files, runtime state or an entire unrelated repository.
- Check its name, description, instructions, referenced paths and tool dependencies before installing. Adapt unsupported syntax and environment-specific assumptions within the user's requested scope; disclose material behavior changes.
- Copy the intended skill folder and necessary resources to the chosen root using permitted tools. Verify that relative references remain inside the skill folder. Do not overwrite an existing destination blindly.
- Do not execute bundled scripts merely to install the skill. Run only the validation or synthetic tests appropriate to reviewed code. If a user supplies a remote source, use an available authorized retrieval capability and inspect the result; do not invent repository contents or install missing tools silently.

## Validate and Make It Discoverable

1. Read the completed entry point and check that it routes the intended request, preserves scope and includes an observable completion condition. Consider realistic cases, including missing inputs and failures. Validate behavior rather than writing tests that only mirror the prose.
2. Verify the harness can parse the actual `SKILL.md` using its existing parser or a compatible available validator. Do not import the real module manifest just to validate: its initialization can have side effects. If no validator can run, report the manual checks and the remaining limitation.
3. Check that each referenced resource exists and is permitted, files are UTF-8 text where required, and skill paths contain no symlink/junction escapes. Keep text files within the harness's 1 MiB read limit and instructions concise enough for paged loading. Follow the target repository's formatting; here use four-space indentation where applicable, UTF-8, CRLF and no final newline.
4. For added or changed executable helpers, run focused synthetic checks without live services, secrets or unrelated repository contents. A real external-action test requires the authorization appropriate to that action; creating a skill does not authorize publishing, messaging or other side effects.
5. If `refresh_skills` is available, call it after writing and verify the intended entry through `list_skills`. Read all catalog pages when needed and resolve warnings or priority conflicts. If these tools are unavailable, explain that discovery refreshes at the next task/invocation; do not claim the catalog was refreshed.
6. Report the final folder/entry-point path, invocation purpose, validation results, dependencies and any unresolved limitations. A skill that passes structural checks has not necessarily been behaviorally tested.
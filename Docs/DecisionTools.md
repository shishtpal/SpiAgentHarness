# Decision-dependent harness tools

Decision tools use a separately configured model while the harness keeps its conversational model. Each tool has a JSON package containing its advertised schema, handler name, model profiles, and request policy. JSON is data; it never contains executable PowerShell.

## Enable the supplied tools

```powershell
# Set EXPLABS_API_KEY locally before invoking a model. Never store its value in JSON.
Invoke-AgentHarness 'Choose the observed Settings button' `
    -DecisionConfigPath './Config/decide_screen_target.json'

# Enable both tools; each package has its own active profile and request settings.
Invoke-AgentHarness 'Evaluate the evidence and select the next target' `
    -DecisionConfigPath './Config/decision.json', './Config/decide_screen_target.json'
```

Paths resolve against `-WorkingDirectory`. Configurations are opt-in, loaded once per invocation, and retained during continuation and chat-model recovery. `-DecisionConfig` accepts an array of equivalent hashtables instead of files; it cannot be combined with `-DecisionConfigPath`. `-NoBuiltinTools` cannot be combined with explicit decision configuration. Custom `-Tools` retain their existing override behavior. Configurations and handlers are not inherited by sub-agents.

Edit `config.active_profile` in a package to choose `luna` or `clef`. Each profile names `provider`, `model`, `protocol`, `endpoint`, `key_env_var`, and `input_modalities`. Credentials are read from the named environment variable at request time. Tool arguments cannot override routing, credentials, or request settings. Endpoint URLs must use HTTPS without embedded credentials, a query, or a fragment.

`request.timeout_sec` accepts integer seconds from 1 to 3600; `max_retries` accepts 0 to 5 and defaults to zero in the shipped packages. Explicit retries can repeat billable provider work after uncertain outcomes. Automatic model fallback is unsupported and must remain false. Profiles are local capability declarations, not live availability checks.

## Screen target selection

`Config/decide_screen_target.json` contains both the tool contract and its settings. The handler receives a goal, a snapshot, and 1-63 observed candidates. Each candidate has a unique ID, a description, and bounds and/or an observed locator. Bounds are `{x,y,width,height}` within the supplied snapshot dimensions. The handler adds the configured abstention choice, keeping the total within 64 options.

Example tool arguments:

```json
{
    "goal": "Open settings",
    "snapshot": {
        "id": "screen-42",
        "captured_at": "2026-11-08T09:00:00Z",
        "source": "observed-tab-id",
        "coordinate_space": "browser_css_pixels",
        "width": 1000,
        "height": 800
    },
    "candidates": [
        {
            "id": "settings",
            "description": "Settings button",
            "bounds": { "x": 900, "y": 20, "width": 40, "height": 40 }
        }
    ]
}
```

Replace the example timestamp and identifiers with the actual observation. Snapshots older than `snapshot.max_age_sec` (120 seconds in the shipped package) return `stale_snapshot` before inference; expiry during inference also discards the selection. Capture timestamps must include a timezone and cannot be more than five seconds in the future. This age check cannot detect a UI change; current-target revalidation remains the executor's responsibility.

An optional `snapshot.screenshot_path` supplies a local image within the harness working directory. Luna accepts images; Clef rejects screenshot input rather than silently dropping it. Native image files are bounded to 20 MiB and checked for a supported extension and matching signature; the provider performs full image decoding. Native Luna request JSON has a local 32 MiB cap. Systemone request JSON is limited to 256 KiB. MCP image blocks are not automatically saved; capture to a local file when the observation tool supports it.

The normalized answer must name an original candidate. Missing probabilities, insufficient selected probability, or an insufficient margin over the strongest alternative cause abstention. The shipped 0.85 probability and 0.15 margin are illustrative; evaluate them with your own examples. `none` is reserved by default. Refusals return `refused`; malformed provider answers return sanitized tool errors. Results include model/request/usage metadata and the original candidate's locator/bounds, never model-generated coordinates.

This tool returns a recommendation and never clicks. Every result requires the caller to revalidate source and target before execution. `screenshot_pixels` results additionally flag `requires_coordinate_transform`; the click executor must supply an observed transform for cropped/scaled screenshots. The tool does not calculate transforms or verify the UI after a click. Use your existing MCP observation and click tools, then inspect the resulting UI. There is no raw-screenshot target detector in this implementation.

## General decisions

`Config/decision.json` uses the `questions` handler. Arguments are `state`, `questions`, and optional `attachments`. Question types follow `Invoke-DecisionModel`: `choice` criteria are a label-to-description object, `noul` criteria contain `true` and `false` descriptions, and `score` criteria are an ordered description array. The service translates noul to Luna's predicate protocol. Results contain normalized answers, a summary, and model/usage metadata; raw provider responses are omitted from tool output.

Both supplied handlers validate arguments locally against their configured JSON schema using PowerShell's `Test-Json`. External schema references are unsupported. Additional semantic validation checks questions, candidates, bounds, IDs, routing, and policy. Decision results must fit `-MaxToolOutputChars`; oversize output becomes an explicit error rather than a truncated decision.

## Add another tool without changing the transport

The reusable layers are:

| Layer | Location | Responsibility |
| --- | --- | --- |
| Protocol adapters | `Private/DecisionModels/` | Wire encoding/decoding, shared public invocation, HTTP errors, normalized answers. |
| Harness service | `Private/AgentHarness/Decisions/Invoke-AgentHarnessDecision.ps1` | Configured profile, credentials by environment reference, attachment paths, timeout/retry policy. |
| Package registration | `New-AgentHarnessDecisionState.ps1`, `Get-AgentHarnessDecisionTools.ps1` | Load packages, resolve handler names, advertise schemas, retain invocation state. |
| Individual handlers | `Invoke-AgentHarnessQuestionDecision.ps1`, `Invoke-AgentHarnessScreenDecision.ps1` | Build domain questions and interpret normalized answers. |

For a new tool that simply asks typed questions, copy `Config/decision.json`, rename `tool.function.name`, and keep `handler: questions`. More specialized tools can register a host scriptblock with `-DecisionToolHandlers`; no core service or protocol changes are necessary:

```powershell
$definition = Get-Content './Config/decision.json' -Raw | ConvertFrom-Json -AsHashtable
$definition.tool.function.name = 'route_request'
$definition.handler = 'route_request'

$handlers = @{
    route_request = {
        param($arguments, $context, $definition)
        # Build domain questions here, or use supplied questions after validation.
        $response = & $context.DecisionState.Invoke `
            $definition $arguments.state $arguments.questions @() $context.Root
        @{ answers = $response.Answers; model = $response.Model; usage = $response.Usage }
    }
}

Invoke-AgentHarness 'Route this request' `
    -DecisionConfig $definition -DecisionToolHandlers $handlers
```

Handlers receive `(arguments, context, definition)` and return a JSON-serializable value. The shared service takes `(definition, state, questions, attachments, root)` and returns the same structured result as `Invoke-DecisionModel`. Use `context.Root` for paths. Host handlers are trusted code with the same responsibilities as existing custom tools; declaring a handler in JSON never executes an arbitrary file or script. New bundled handlers require a small private function and one registry entry; public functions/exports are unnecessary.

## Validation

Run the isolated suites:

```powershell
pwsh -NoProfile -File ./Tests/Invoke-DecisionModel.Tests.ps1
pwsh -NoProfile -File ./Tests/Invoke-AgentHarness.Tests.ps1
```

Tests mock all model calls and use synthetic UI/image evidence. They verify both wire formats, refusals, missing/invalid probabilities, configuration, opt-in registration, local screenshots, stale observations, and a third custom handler using the shared service. Live Experiential compatibility and actual UI execution have not been tested.

Native protocol references: [Luna model](https://platform.experientiallabs.ai/models/gpt-6-luna-decisions), [Clef model](https://platform.experientiallabs.ai/models/clef), [OpenAI Decisions format](https://developers.openai.com/api/docs/guides/decisions), [Systemone gateway format](https://platform.experientiallabs.ai/docs/integrate#typesafe), and [native Systemone response examples](https://docs.typesafe.ai/introduction/quickstart).
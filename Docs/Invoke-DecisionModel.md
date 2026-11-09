# Invoke-DecisionModel

Evaluates supplied text or JSON context with named, typed questions. Returns structured decisions and probabilities through configurable protocol adapters, defaulting to OpenRouter's [Decisions API](https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-request). Requires PowerShell 7.0 or later.

Configure `OPENROUTER_API_KEY` in your environment, then import the module using your usual setup. The command also accepts `-ApiKey` explicitly. Supply the state and questions as objects or load them from JSON files.

## JSON files

Use `-QuestionsFile` to pass a JSON file directly. Its root object contains the named questions, without an outer `questions` wrapper:

```json
{
    "category": {
        "type": "choice",
        "instructions": "Which team should own this support request?",
        "criteria": {
            "billing": "Payments, invoices, or refunds",
            "technical": "Broken or unexpected product behavior"
        }
    }
}
```

```powershell
Invoke-DecisionModel -State 'My subscription is inactive.' `
    -QuestionsFile './questions.json' -Model 'typesafe/jev-1.14'

# Load both inputs from files, using the included examples from the repository root
Invoke-DecisionModel `
    -StateFile './Examples/DecisionModels/state.json' `
    -QuestionsFile './Examples/DecisionModels/questions.json' `
    -Pick -All
```

Ready-to-edit examples: [questions.json](../Examples/DecisionModels/questions.json) and [state.json](../Examples/DecisionModels/state.json). The state file contains the JSON state itself: an object, array, or quoted JSON string. Relative paths resolve against the current PowerShell location, and brackets in filenames are treated literally. Files are read as UTF-8, with BOM-marked encodings also supported.

Supply exactly one of `-Questions` or `-QuestionsFile`, and exactly one of `-State` or `-StateFile`. Invalid JSON and invalid question schemas fail before model selection or HTTP requests. Nested nulls, empty/singleton arrays, and case-sensitive names remain intact.

## Example

```powershell
$questions = @{
    category = @{
        type = 'choice'
        instructions = 'Which team should own this support request?'
        criteria = @{
            billing = 'Payments, invoices, subscriptions, or refunds'
            technical = 'Broken or unexpected product behavior'
            general = 'Other questions'
        }
    }
    is_bug = @{
        type = 'noul'
        instructions = 'Does the request describe a software defect?'
        criteria = @{
            'true' = 'The product is broken or behaves unexpectedly'
            'false' = 'The customer is asking a question or requesting a feature'
        }
    }
    urgency = @{
        type = 'score'
        instructions = 'How urgent is the request?'
        criteria = @('Can wait', 'Needs attention this week', 'Blocking work now')
    }
}

$result = Invoke-DecisionModel `
    -State @{ ticket = 'My payment succeeded, but the subscription is inactive.' } `
    -Questions $questions `
    -Model 'typesafe/jev-1.14'

$result.Answers.category.choice
$result.Answers.category.probabilities
$result.Answers.is_bug.noul
$result.Answers.urgency.score
$result.Usage
```

## Inputs and model selection

| Parameter | Default | Behavior |
| --- | --- | --- |
| `-State` | Required unless `-StateFile` is supplied; positional | Text, dictionary, PSCustomObject, or an array of context. Empty text and arrays are preserved. Root null and primitive numbers/booleans are rejected; nested nulls and booleans are supported. |
| `-StateFile` | Alternative to `-State` | Literal path to a JSON state file. Alias: `-StatePath`. |
| `-Attachment` | Off | Image files (PNG, JPEG, GIF or WebP) to send with the state. Relative paths resolve against the current PowerShell location. When supplied, `state` becomes an ordered content array: one text part with the context (JSON is serialized to text), then one `image_url` data URL per image. Other file types are rejected before any request. |
| `-Questions` | Required unless `-QuestionsFile` is supplied | A dictionary or PSCustomObject containing at least one named question. |
| `-QuestionsFile` | Alternative to `-Questions` | Literal path to a JSON object containing named questions. Alias: `-QuestionsPath`. |
| `-Model` | Explicit selection required | Exact model ID. Bypasses the bundled catalogue, including for compatible future models. Mutually exclusive with `-Pick`. |
| `-Pick` | Off | Open the existing interactive model menu. Escape cancels before any request. |
| `-ModelFilter` | `*` | With `-Pick`, match model ID or display name using a wildcard. |
| `-All` | Off | With `-Pick`, include paid models. Applies only to catalogue selection; it is unnecessary for an explicit model ID. |
| `-Provider` | `OpenRouter` | Registered provider name; it must have a Decisions endpoint unless overridden. |
| `-DecisionUri` | Registered endpoint | Override with an absolute HTTPS URL implementing the same Decisions schema. |
| `-ApiKey` | Provider's environment variable | Override request authentication. A key is required, including for free model variants. |
| `-TimeoutSec` | `120` | Timeout per HTTP attempt. |
| `-MaxRetries` | `3` | Zero to five additional attempts after the initial request. |
| `-Quiet` | Off | Suppress informational request metadata. Structured results still return. |
| `-OutFile` | Off | Also save the result as UTF-8 JSON (overwriting the file) and still return it. See [Saving results](#saving-results). |

Each question requires a lowercase `type`, nonempty `instructions`, and `criteria`:

- `choice`: criteria is an object mapping allowed string labels to nonempty descriptions. The answer contains the selected label and a probability for every label.
- `noul`: criteria is an object containing exactly the string keys `'true'` and `'false'`, each with a description. The answer's `noul` is the probability of yes, between zero and one; it is not a boolean.
- `score`: criteria is a nonempty array of descriptions, ordered from lowest to highest. The answer's `score` is a fractional expected position on the zero-based scale, not necessarily an integer.

The command preserves case-sensitive question names and choice labels. It validates answer types, allowed choices, score ranges, and probability values. It preserves the provider's confidence, probabilities, score legends, and additional answer fields without computing thresholds or replacing confidence with the winning probability. Set and evaluate thresholds for your selected model in the calling script.

```powershell
# Pick from the bundled free variants
Invoke-DecisionModel -State $ticket -Questions $questions -Pick

# Pick from all six starter models, including paid models
Invoke-DecisionModel -State $ticket -Questions $questions -Pick -All

# Narrow the picker
Invoke-DecisionModel -State $ticket -Questions $questions -Pick -All -ModelFilter '*decider*'
```

## Result

One object is returned for each invocation. In the console it shows a model header and one row per question. `RawResponse` and the other properties stay available on the object:

```text
Model: typesafe/jev-1.14  [OpenRouter, served by Synthetic, 812 ms]

Question Type   Answer  Confidence Probabilities
-------- ----   ------  ---------- -------------
route    choice billing 0.88       billing=0.9, other=0.1
relevant noul   0.97
urgency  score  1.2     0.6        0=0.333, 1=0.333, 2=0.333
```

The header names the requested model too when it differs from the served snapshot. Use `$result | Format-List *` to see every property.

| Property | Meaning |
| --- | --- |
| `Answers` | Named native answers, including probability distributions and optional confidence/legend fields. |
| `Summary` | One flat row per question, in question order: `Question`, `Type`, `Answer` (the choice label, noul probability, or score), `Confidence`, and `Probabilities` as text in criteria order. Display and CSV helper only; use `Answers` for calculations. |
| `RequestedModel` | The model ID sent in the request. |
| `Model` | The model snapshot reported by the response. |
| `Provider` | Registry/gateway name, normally `OpenRouter`. |
| `ServedBy` | Upstream inference provider reported by the response, when supplied. |
| `Id` | Provider request ID, when supplied. |
| `Usage` | Original usage object, including tokens and cost when supplied. |
| `ElapsedMilliseconds` | Elapsed HTTP time including retries and delays. |
| `RawResponse` | Full parsed response, using dictionaries to preserve JSON keys. |

Request failures throw terminating errors with an HTTP status in `Exception.Data['Status']` (`0` when unavailable). Only HTTP 429 and 5xx responses are retried, including API error objects returned with HTTP 200. Delays use exponential backoff or `Retry-After`, capped at 30 seconds. Requests retain the chosen model. Authentication, billing, schema, missing model, and malformed answer failures do not trigger model switching or interactive recovery.

Logs contain request metadata, not state, questions, authorization headers, or upstream error bodies. The returned `RawResponse` is the provider response; callers control whether they store it.

## Saving results

```powershell
# Show the table and keep a JSON copy, e.g. to compare models picked with -Pick -All
Invoke-DecisionModel `
    -StateFile './Examples/DecisionModels/state.json' `
    -QuestionsFile './Examples/DecisionModels/questions.json' `
    -Pick -All -OutFile './result.json'

# Flat rows for spreadsheets
$result.Summary | Export-Csv './result.csv' -NoTypeInformation
```

`-OutFile` writes `SavedAt` (UTC), `RequestedModel`, `Model`, `Provider`, `ServedBy`, `Id`, `ElapsedMilliseconds`, `Usage`, and `Answers`. It omits `RawResponse` (duplicated data) and `Summary` (derived from `Answers`). The state, questions, and API key are never written. Relative paths resolve against the current PowerShell location, and brackets are treated literally. The parent directory must already exist. Invalid paths fail before model selection or any request. If the write fails after a successful request, the command warns and still returns the result, so you don't lose the decision you already paid for.

## Provider extension

`Register-FreeModelProvider` accepts optional `-DecisionUri` alongside its existing model-list and chat settings. An endpoint override changes routing; select the matching wire adapter with `-Protocol` when it differs from OpenRouter.

```powershell
Register-FreeModelProvider -Name MyDecisionGateway `
    -Uri 'https://gateway.example/v1/models' `
    -DecisionUri 'https://gateway.example/decisions' `
    -KeyEnvVar 'MY_DECISION_API_KEY'

Invoke-DecisionModel -State $ticket -Questions $questions `
    -Provider MyDecisionGateway -Model 'custom/decision-model'
```

Custom providers use explicit IDs. Bundled menus cover OpenRouter and ExperientialLabs. Existing OpenRouter images use `image_url` parts inside `state`; live compatibility of that image format remains unverified. Harness tools can opt into the shared service through JSON packages; see [Decision tools](DecisionTools.md).

## Native Experiential protocols

```powershell
# Uses EXPLABS_API_KEY from the registered provider; no chat-model switch.
Invoke-DecisionModel -State $ticket -Questions $questions `
    -Provider ExperientialLabs -Model gpt-6-luna-decisions

Invoke-DecisionModel -State $ticket -Questions $questions `
    -Provider ExperientialLabs -Model clef
```

`-Protocol` accepts `openrouter`, `openai_decisions`, or `systemone`. Without an explicit value, Experiential Luna selects `openai_decisions` at `/v1/decisions`; Clef selects `systemone` at `/v1/systemone`. Other Experiential model IDs require an explicit protocol. Other providers keep the existing OpenRouter default. `-DecisionUri` overrides the endpoint and `-KeyEnvVar` overrides the credential environment-variable name; explicit `-ApiKey` retains precedence for direct command callers.

The public question format stays the same. Luna converts noul into predicate questions, criteria into choices/levels, and image attachments into inline `input_image` parts. Ordered native answers are mapped back to question names; a present mismatched name is rejected. Clef accepts text/JSON state and rejects image attachments. Native protocols enforce at most 32 questions, 64 choices, and 2-10 score levels. Image size/signature and request byte limits are described in [Decision tools](DecisionTools.md).

Native adapters preserve refusal answers (`type=refusal`) and allow absent probability distributions, which remain absent rather than being inferred from confidence. Present distributions must match the criteria, contain valid probabilities, and sum to one within 0.01 rounding tolerance. Existing OpenRouter validation is unchanged. Native requests default to zero retries; an explicit `-MaxRetries` remains available. There is no automatic model fallback. Tests use mocked responses; live native endpoint compatibility is unverified.

## Verification

Run `pwsh -NoProfile -File ./Tests/Invoke-DecisionModel.Tests.ps1`. Tests import an isolated module fixture with bootstrap side effects replaced, exercise the actual HTTP serialization and response parsing with synthetic responses, and never use a live provider.
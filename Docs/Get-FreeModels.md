# Get-FreeModels

Lists free models from registered providers. Use `-All` to include every model returned by each selected provider, including paid models and models with unknown pricing.

## Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `-Provider` | All registered providers | Provider names to query. Supports multiple names. |
| `-Name` | `*` | Wildcard matched against model id or display name. |
| `-All` | Off | Skip the provider's free-model check. Provider and name filters still apply. |

## Examples

```powershell
# Free models from all registered providers
Get-FreeModels

# All models from all registered providers
Get-FreeModels -All

# All models from one provider
Get-FreeModels -Provider OpenRouter -All

# Filter all models by id or display name
Get-FreeModels -Provider Kilo,OpenRouter -All -Name '*glm*' |
    Format-Table -AutoSize
```

Results contain `Provider`, `Id`, `Name`, and `Context`. Providers that require an API key are still skipped with a warning when their configured environment variable is missing. `-All` only changes model listing; it does not make paid models free to use.

For typed decision models, use [Get-DecisionModels](Get-DecisionModels.md) and [Invoke-DecisionModel](Invoke-DecisionModel.md). Provider registration also accepts an optional `-DecisionUri` for gateways implementing the OpenRouter Decisions schema; the chat endpoint is configured independently.

## Cohere

Set `COHERE_API_KEY`, then run:

```powershell
Get-FreeModels -Provider Cohere -All
Invoke-AgentHarness 'Say hi' -Provider Cohere -Pick -All
```

Cohere's [List Models API](https://docs.cohere.com/reference/list-models) returns paginated model names without pricing. Discovery follows all pages of the chat catalogue, maps names to ids, and preserves context lengths. Use `-All`; these models are not assumed to be free. See [Invoke-AgentHarness](Invoke-AgentHarness.md#cohere) for chat setup.

## Respan

```powershell
Get-FreeModels -Provider Respan -All
Invoke-AgentHarness 'Say hi' -Provider Respan -Pick -All
```

Respan's [List models API](https://www.respan.ai/docs/apis/models/list-models) at `https://api.respan.ai/api/v1/models` supports public discovery without a key. Set `RESPAN_API_KEY` to list models available to your project; chat requests require that key. Model ids and context lengths are preserved. Free-only discovery requires both `pricing.input_cost` and `pricing.output_cost` to be explicitly zero; missing, null, invalid or nonzero prices are excluded, including ids ending in `:free`. Use `-All` to include paid and unknown-price models. Choose a chat-capable model from the catalogue. See [Respan gateway setup](Invoke-AgentHarness.md#respan).

## Custom catalogue mapping

`Register-FreeModelProvider -GetModels` accepts a scriptblock whose first argument is the raw API response. An optional second argument is a hashtable containing the catalogue `Uri` and request `Headers`, allowing a mapper to fetch subsequent pages using the same authentication. Existing single-argument mappers continue to work. Return model objects with an `id` and optional `name`, `context_length`, and `pricing` fields.
# Get-DecisionModels

Lists a bundled starter catalogue of decision models without a network request or API key. Use the results with [Invoke-DecisionModel](Invoke-DecisionModel.md).

```powershell
Get-DecisionModels
Get-DecisionModels -All | Format-Table Provider, Id, IsFree
Get-DecisionModels -All -Name '*Jev*'
```

| Parameter | Default | Description |
| --- | --- | --- |
| `-Provider` | `OpenRouter` | Gateway name. Bundled entries cover OpenRouter and ExperientialLabs. Other providers return no bundled entries. |
| `-Name` | `*` | Wildcard matched against model ID or display name. |
| `-All` | Off | Include paid starter models. The default includes only the `:free` variant. |

The six entries are:

- `perplexity/pplx-decider-flash-v1.2`
- `liquid/d1-ultra`
- `typesafe/jev-1.14`
- `cloudflare/clef-omni`
- `openai/gpt-6-luna-decisions`
- `inception/mercury-decide:free`

Results contain `Provider`, `Id`, `Name`, `IsFree`, `QuestionTypes`, and `CatalogSource` (`Bundled`). `IsFree` identifies the named free variant; it is not a live price or availability guarantee. No prices, context lengths, or unverified capability metadata are inferred from the general chat catalogue. The catalogue reflects the initial model list reviewed on October 20, 2026; model availability and account requirements can change.

To invoke a compatible model absent from this starter list, pass its exact ID using `Invoke-DecisionModel -Model`. This does not require changing the catalogue or using `-All`.

`Get-DecisionModels -Provider ExperientialLabs -All` lists `gpt-6-luna-decisions` (`openai_decisions`, text/images) and `clef` (`systemone`, text). These rows additionally include `Protocol` and `InputModalities`. They are not marked free because allowances depend on the account; the catalogue does not check entitlement or pricing. See [Decision tools](DecisionTools.md) for configurable harness integration.
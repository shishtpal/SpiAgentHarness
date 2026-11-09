# Static workflows (REA 6.8.0)

Use the actual tool schemas. Replace placeholder paths and Evidence IDs with the selected absolute path and returned identity.

## JavaScript and Electron

Start with `mcp_rea_analyze_javascript_application`:

```json
{"input_path":"D:/samples/app","detail":"summary"}
```

An ASAR path is also accepted. When only known files matter and the schema supports `source_paths`, supply exact root-relative paths, including relevant manifests/maps. Dependencies are not implicitly selected. Summary reduces delivery, not analysis work. Neither this operation nor its follow-up views execute application JavaScript.

Read `normalized_result.parent_evidence_id`, then page modules with `mcp_rea_inspect_analysis_view`:

```json
{
    "source": {"kind":"retained-evidence","evidence_id":"ev_ACTUAL_PARENT_ID"},
    "view": {"kind":"page","collection":"modules","offset":0,"limit":4}
}
```

Keep node IDs and exact paths when selecting further views. Use `trace_application_feature`, `trace_javascript_semantics`, `compare_application_versions`, or `compare_javascript_export_shapes` only with the schemas and authenticated Evidence/reference forms they advertise. These names have the `mcp_rea_` prefix in this harness. Preserve incomplete source-map and relationship coverage.

## Managed .NET assemblies

Use `mcp_rea_inspect_managed_artifact` to identify a selected assembly without loading it:

```json
{"path":"D:/samples/Example.dll","detail":"summary"}
```

Then call `mcp_rea_inspect_managed_members`, optionally restricting exact full type names:

```json
{"path":"D:/samples/Example.dll","type_names":["Example.Parser"],"detail":"summary"}
```

Use the member summary's parent ID for selected CIL/member rows:

```json
{
    "source": {"kind":"retained-evidence","evidence_id":"ev_ACTUAL_MEMBER_PARENT_ID"},
    "view": {"kind":"managed-members","collection":"methods","offset":0,"limit":2}
}
```

Other member collections include `types`, `fields`, `member_refs`, `call_edges`, `field_accesses` and `user_strings`. The installed 6.8.0 managed-member view accepts only `kind`, `collection`, `offset` and `limit`; names, declaring-type and column filters from newer documentation are rejected. Restrict exact `type_names` on the producer, page small result sets and select the relevant returned rows. Follow `coverage.next_offset` when present. Build-local tokens require the recorded artifact digest and module identity; matching names alone do not establish identity across builds.

`inspect_managed_native_boundaries` reports declarations, not native implementations. NativeAOT needs a separately configured native engine. A single-file .NET host can require separately extracted components; report that boundary rather than treating it as an ordinary managed DLL. Use `compare_managed_members` with complete compatible Evidence or supported retained references, never manually reconstructed summaries.

## Output and recovery

The harness renders REA text and structured content together, so Evidence may appear twice. Treat matching copies as one observation. The recommended invocation uses `-MaxToolOutputChars 32768`; prefer small summaries/pages before raising it. Read coverage and limitations even when a page has no matching rows.

Keep full upfront catalog discovery: this harness snapshots it once. Its allowlist controls which tools the model receives; the installed 6.8.0 runtime still advertises its full catalog. Omitted output schemas reduce discovery size without removing returned structured Evidence or REA's server-side validation.

Diagnose missing tools, denied approvals, unavailable capabilities and invalid requests separately. Preserve completed findings and resume the original question after any authorized repair. Do not install packages or configure another agent client.
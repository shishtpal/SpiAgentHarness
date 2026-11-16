function Get-AgentHarnessFileWriteTools {
    $path = @{ type = 'string'; minLength = 1; description = 'File path within the working directory.' }
    $size = @{ type = 'integer'; minimum = 0; description = 'Exact expected UTF-8 byte count, not characters or tokens.' }
    $hash = @{ type = 'string'; pattern = '^[a-fA-F0-9]{64}$'; description = 'Optional SHA-256 from an independent reference; do not invent a checksum.' }
    $content = @{ type = 'string'; description = 'Literal exact text; no newline is added. Use an explicit empty string to create an empty file.' }
    $id = @{ type = 'string'; pattern = '^[a-f0-9]{32}$'; description = 'Invocation-owned write_id from begin_file_write.' }
    $tools = [ordered]@{}
    $handler = ${function:Invoke-AgentHarnessFileWrite}
    $definitions = @(
        @{ Name = 'write_file'; Description = 'Create or replace a UTF-8 file with exactly content, without BOM or an added newline. Requires approval unless YOLO. Missing/null content is invalid. Optional expected_bytes/expected_sha256 reject incomplete content. Large model-authored files should use begin_file_write/write_file_chunk/commit_file_write.'; Properties = @{ path = $path; content = $content; expected_bytes = $size; expected_sha256 = $hash }; Required = @('path', 'content'); Approval = $true },
        @{ Name = 'begin_file_write'; Description = 'Begin staging a large UTF-8 text file without changing the destination. Required expected_bytes declares the exact final size. Returns write_id and chunk limits; wait for these before sending chunks. Sessions belong to this invocation. Final commit requires approval unless YOLO.'; Properties = @{ path = $path; expected_bytes = $size; expected_sha256 = $hash }; Required = @('path', 'expected_bytes'); Approval = $false },
        @{ Name = 'write_file_chunk'; Description = 'Stage a nonempty literal UTF-8 chunk at offset_bytes from the previous acknowledgement (starts at zero). Respect returned byte and argument limits. Exact retries at the original offset are idempotent; gaps/overlaps/conflicting retries fail. Acknowledgement is not a completed destination write.'; Properties = @{ write_id = $id; offset_bytes = $size; content = $content }; Required = @('write_id', 'offset_bytes', 'content'); Approval = $false },
        @{ Name = 'get_file_write_status'; Description = 'Inspect staged file state, received bytes, next offset and final receipt. Does not return content. Use after an uncertain acknowledgement before retrying; a new invocation cannot resume an old session.'; Properties = @{ write_id = $id }; Required = @('write_id'); Approval = $false },
        @{ Name = 'commit_file_write'; Description = 'Verify declared size/hash, show complete candidate for approval unless YOLO, then atomically create or replace the destination if unchanged. Success returns a verified receipt. A repeated successful commit returns that receipt without rewriting. Incomplete content leaves staging open.'; Properties = @{ write_id = $id }; Required = @('write_id'); Approval = $true },
        @{ Name = 'abort_file_write'; Description = 'Discard this invocation-owned staged write. Does not alter the destination or undo a committed write. Repeated abort is safe.'; Properties = @{ write_id = $id }; Required = @('write_id'); Approval = $false }
    )
    foreach ($definition in $definitions) {
        $operation = $definition.Name
        $tools[$operation] = @{
            Description = $definition.Description
            Parameters = @{ type = 'object'; additionalProperties = $false; properties = $definition.Properties; required = $definition.Required }
            RequiresApproval = $definition.Approval
            FileWriteTool = $true
            OutputMustFit = $true
            OutputLimitMessage = 'ERROR: File-write result exceeds MaxToolOutputChars. The action may have completed; inspect the destination or get_file_write_status before retrying. Increase the output limit for a complete receipt.'
            Script = { param($a, $ctx) & $handler -Arguments $a -Context $ctx -Name $operation }.GetNewClosure()
        }
    }
    $tools
}
function Get-AgentHarnessSkillTools {
    $tools = [ordered]@{}
    foreach ($operation in 'list_skills', 'load_skill', 'read_skill_resource', 'refresh_skills') {
        $properties = @{
            offset = @{ type = 'integer'; minimum = 0; maximum = 1048576; description = 'Character offset from next_offset. Default 0.' }
            max_chars = @{ type = 'integer'; minimum = 1; maximum = 16000; description = 'Page size. Default 4000. Lower if the tool output limit is smaller.' }
        }
        $required = @()
        if ($operation -in 'load_skill', 'read_skill_resource') {
            $properties.name = @{ type = 'string'; description = 'Exact catalog skill name.' }
            $required += 'name'
        }
        if ($operation -eq 'read_skill_resource') {
            $properties.path = @{ type = 'string'; description = 'Text file path relative to the selected skill folder, such as references/workflow.md. Links and escapes are rejected.' }
            $required += 'path'
        }
        $description = switch ($operation) {
            'list_skills' { 'List discovered folder skills as a paged JSON catalog of names, descriptions and directories.' }
            'load_skill' { 'Load a skill instruction body as task guidance. Read every page before following its workflow. Does not execute code or grant approval.' }
            'read_skill_resource' { 'Read a UTF-8 supporting file inside a discovered skill folder. Text only, up to 1 MiB, paged; never executes scripts.' }
            'refresh_skills' { 'Rescan configured skill folders and update the prompt catalog without reimporting the module. Returns the first catalog page; use list_skills for more pages. Reload previously read skills after edits.' }
        }
        $schema = @{ type = 'object'; additionalProperties = $false; properties = $properties }
        if ($required.Count) { $schema.required = $required }
        # Literal scriptblocks retain the module's private helper scope.
        $script = switch ($operation) {
            'list_skills' { { param($a, $ctx) Invoke-AgentHarnessSkillTool -Operation list_skills -Arguments $a -Context $ctx } }
            'load_skill' { { param($a, $ctx) Invoke-AgentHarnessSkillTool -Operation load_skill -Arguments $a -Context $ctx } }
            'read_skill_resource' { { param($a, $ctx) Invoke-AgentHarnessSkillTool -Operation read_skill_resource -Arguments $a -Context $ctx } }
            'refresh_skills' { { param($a, $ctx) Invoke-AgentHarnessSkillTool -Operation refresh_skills -Arguments $a -Context $ctx } }
        }
        $tools[$operation] = @{
            Description = $description; Parameters = $schema; OutputMustFit = $true
            Script = $script
        }
    }
    $tools
}
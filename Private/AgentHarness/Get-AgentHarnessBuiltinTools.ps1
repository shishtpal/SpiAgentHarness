function Get-AgentHarnessBuiltinTools {
    # Each tool: Description, Parameters (JSON schema), Script { param($a, $ctx) }
    param(
        [switch]$AllowWrite = $true,
        [switch]$AllowShell = $true,
        [switch]$AllowSubAgents = $true,
        [switch]$AllowSkills = $true
    )

    $tools = [ordered]@{}
    if ($AllowSkills) {
        $skillTools = Get-AgentHarnessSkillTools
        foreach ($name in $skillTools.Keys) { $tools[$name] = $skillTools[$name] }
    }

    $tools['get_datetime'] = @{
        Description = 'Get the current local date, time and time zone.'
        Parameters  = @{ type = 'object'; properties = @{} }
        Script      = { param($a, $ctx) '{0} ({1})' -f (Get-Date).ToString('o'), [TimeZoneInfo]::Local.Id }
    }

    $menuProperties = @{
        title        = @{ type = 'string'; minLength = 1; description = 'Question or prompt shown above the choices' }
        options      = @{ type = 'array'; minItems = 1; uniqueItems = $true; items = @{ type = 'string'; minLength = 1 }; description = 'Distinct, nonblank option labels' }
        multi_select = @{ type = 'boolean'; description = 'Allow multiple selections. Default false' }
    }
    $questionProperties = $menuProperties.Clone()
    $questionProperties.id = @{ type = 'string'; minLength = 1; description = 'Distinct, nonblank question ID used to identify its answer' }
    $batchMenuProperties = $menuProperties.Clone()
    $batchMenuProperties.questions = @{
        type = 'array'; minItems = 1; description = 'Ask these questions in order in one call. Do not combine with top-level title, options or multi_select.'
        items = @{ type = 'object'; properties = $questionProperties; required = @('id', 'title', 'options') }
    }
    $tools['show_interactive_menu'] = @{
        Description = 'Ask one question with title/options or several sequential questions with a questions array. Each supports single or multiple selections. Single returns cancelled/selections; batch returns cancelled/answers with id, cancelled and selections per question. Cancellation stops remaining questions. Always waits, including in Quiet and YOLO. Never treat cancellation as approval.'
        Parameters  = @{
            type       = 'object'
            properties = $batchMenuProperties
            oneOf      = @(
                @{ required = @('title', 'options'); not = @{ required = @('questions') } },
                @{ required = @('questions'); not = @{ anyOf = @(@{ required = @('title') }, @{ required = @('options') }, @{ required = @('multi_select') }) } }
            )
        }
        Script      = { param($a, $ctx) Invoke-AgentHarnessMenu -Arguments $a -Context $ctx }
    }

    $tools['list_directory'] = @{
        Description = 'List files and folders in a directory (relative to the working directory).'
        Parameters  = @{
            type       = 'object'
            properties = @{ path = @{ type = 'string'; description = 'Directory path. Default "."' } }
        }
        Script      = {
            param($a, $ctx)
            $dir = Resolve-AgentHarnessPath $ctx.Root $a.path
            Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 200 | ForEach-Object {
                if ($_.PSIsContainer) { "$($_.Name)/" } else { '{0}  ({1} bytes)' -f $_.Name, $_.Length }
            }
        }
    }

    $tools['read_file'] = @{
        Description = 'Read a text file with line numbers (relative to the working directory).'
        Parameters  = @{
            type       = 'object'
            properties = @{
                path       = @{ type = 'string'; description = 'File path' }
                start_line = @{ type = 'integer'; description = '1-based first line. Default 1' }
                max_lines  = @{ type = 'integer'; description = 'Max lines to return. Default 400, cap 2000' }
            }
            required   = @('path')
        }
        Script      = {
            param($a, $ctx)
            $file = Resolve-AgentHarnessPath $ctx.Root $a.path
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "File not found: $($a.path)" }
            $start = [Math]::Max(1, [int]($a.start_line ?? 1))
            $max = [Math]::Max(1, [Math]::Min(2000, [int]($a.max_lines ?? 400)))
            $i = $start
            foreach ($l in (Get-Content -LiteralPath $file -TotalCount ($start + $max - 1) | Select-Object -Skip ($start - 1))) {
                '{0,5}: {1}' -f $i, $l
                $i++
            }
        }
    }

    $tools['search_files'] = @{
        Description = 'Recursive regex search of a directory (file paths are rejected). Skips .git, node_modules, dist, bin, Initialize.ps1, detected binary files and files larger than 10 MiB. ignore_dirs/exclude_files add literal names at any depth. Returns up to 50 matching lines as path:line: text, followed by limit/skip notices. Scan budget 10s; regex budget 250ms per line. Narrow path/glob on timeout.'
        Parameters  = @{
            type       = 'object'
            properties = @{
                pattern     = @{ type = 'string'; description = 'Regular expression' }
                path        = @{ type = 'string'; description = 'Directory to search. Default "."' }
                glob        = @{ type = 'string'; description = 'File name filter, e.g. *.ps1. Default *' }
                ignore_dirs = @{ type = 'array'; items = @{ type = 'string' }; description = 'Additional literal directory names to skip at any depth (case-insensitive). Extends defaults .git, node_modules, dist, bin. No paths or wildcards.' }
                exclude_files = @{ type = 'array'; items = @{ type = 'string' }; description = 'Additional literal file names to skip at any depth (case-insensitive). Initialize.ps1 is always excluded. No paths or wildcards.' }
            }
            required   = @('pattern')
        }
        Script      = {
            param($a, $ctx)
            if (-not $a.pattern) { throw 'pattern is required' }
            $dir = Resolve-AgentHarnessPath $ctx.Root $a.path
            Find-AgentHarnessFileText -Root $ctx.Root -Path $dir -Pattern $a.pattern -Filter ($a.glob ?? '*') `
                -IgnoreDirectories ($a.ignore_dirs ?? @()) -ExcludeFiles ($a.exclude_files ?? @())
        }
    }

    $tools['view_image'] = @{
        Description = 'View an image file (relative to the working directory) and return its visual content for analysis. Supported formats: PNG, JPEG, GIF, WebP, BMP, TIFF, SVG, HEIC, AVIF. Maximum file size: 10 MiB. Requires a vision-capable model.'
        Parameters  = @{
            type       = 'object'
            properties = @{
                path = @{ type = 'string'; description = 'Image file path, relative to the working directory' }
            }
            required   = @('path')
        }
        Script      = {
            param($a, $ctx)
            $file = Resolve-AgentHarnessPath $ctx.Root $a.path
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "File not found: $($a.path)" }
            $item = Get-Item -LiteralPath $file -Force
            $maxBytes = 10 * 1024 * 1024
            if ($item.Length -gt $maxBytes) {
                throw "Image too large ($([Math]::Round($item.Length / 1MB, 1)) MiB). Maximum: 10 MiB."
            }
            $mimeTypes = @{
                '.png'  = 'image/png';   '.jpg'  = 'image/jpeg'; '.jpeg' = 'image/jpeg'
                '.gif'  = 'image/gif';   '.webp' = 'image/webp'; '.bmp'  = 'image/bmp'
                '.tif'  = 'image/tiff';  '.tiff' = 'image/tiff'; '.svg'  = 'image/svg+xml'
                '.heic' = 'image/heic';  '.avif' = 'image/avif'
            }
            $ext = $item.Extension.ToLowerInvariant()
            $mimeType = $mimeTypes[$ext]
            if (-not $mimeType) {
                throw "Unsupported image format '$ext'. Supported: $($mimeTypes.Keys -join ', ')"
            }
            $bytes = [IO.File]::ReadAllBytes($item.FullName)
            $dataUrl = "data:${mimeType};base64,$([Convert]::ToBase64String($bytes))"
            @{
                ContentParts = @(
                    @{ type = 'text'; text = "Image: $($item.Name) ($($item.Length) bytes, $mimeType)" }
                    @{ type = 'image_url'; image_url = @{ url = $dataUrl } }
                )
            }
        }
    }

    if ($AllowWrite) {
        $tools['edit_file'] = @{
            Description = 'Edit an existing text file with ordered, exact, case-sensitive replacements. Each nonempty old_text must match exactly once in the current candidate, including line endings; new_text may be empty to delete it. All edits succeed together or nothing is written. Shows a replacement diff and asks for approval unless YOLO. Preserves encoding/BOM and untouched newlines. Maximum file size 1 MiB; no links or junctions.'
            RequiresApproval = $true
            Parameters  = @{
                type = 'object'; additionalProperties = $false
                properties = @{
                    path = @{ type = 'string'; minLength = 1 }
                    edits = @{
                        type = 'array'; minItems = 1; maxItems = 100
                        items = @{
                            type = 'object'; additionalProperties = $false
                            properties = @{
                                old_text = @{ type = 'string'; minLength = 1 }
                                new_text = @{ type = 'string' }
                            }
                            required = @('old_text', 'new_text')
                        }
                    }
                }
                required = @('path', 'edits')
            }
            Script = { param($a, $ctx) Invoke-AgentHarnessEditFile -Arguments $a -Context $ctx }
        }

        $tools['write_file'] = @{
            Description = 'Create or overwrite a text file relative to the working directory. The user confirms each write unless YOLO mode is enabled.'
            RequiresApproval = $true
            Parameters  = @{
                type       = 'object'
                properties = @{
                    path    = @{ type = 'string' }
                    content = @{ type = 'string' }
                }
                required   = @('path', 'content')
            }
            Script      = {
                param($a, $ctx)
                $file = Resolve-AgentHarnessPath $ctx.Root $a.path
                if (-not (Confirm-AgentHarnessAction $ctx "write $($a.path):`n$([string]$a.content)")) { return 'ERROR: the user denied this write.' }
                $null = New-Item -ItemType Directory -Force -Path (Split-Path $file -Parent)
                Set-Content -LiteralPath $file -Value ([string]$a.content) -Encoding utf8NoBOM
                'Wrote {0} chars to {1}' -f ([string]$a.content).Length, $a.path
            }
        }
    }

    if ($AllowShell) {
        $tools['run_powershell'] = @{
            Description = 'Execute raw PowerShell code in the working directory (60s timeout). The user confirms each command unless YOLO mode is enabled. Returns exit code, stdout and stderr.'
            RequiresApproval = $true
            Parameters  = @{
                type       = 'object'
                properties = @{ command = @{ type = 'string'; description = 'PowerShell command text' } }
                required   = @('command')
            }
            Script      = {
                param($a, $ctx)
                if (-not $a.command) { throw 'command is required' }
                if (-not (Confirm-AgentHarnessAction $ctx "run PowerShell: $($a.command)")) { return 'ERROR: the user denied this command.' }

                Invoke-AgentHarnessShell -Command $a.command -WorkingDirectory $ctx.Root
            }
        }
    }

    if ($AllowSubAgents) {
        $agentTools = Get-AgentHarnessSubAgentTools -AllowSpawn:$AllowShell
        foreach ($name in $agentTools.Keys) { $tools[$name] = $agentTools[$name] }
    }
    $tools
}
# Dot-sourced by Invoke-AgentHarness.Tests.ps1; all skills and providers are synthetic.
$skillRoot = Join-Path $fixture 'skill-fixture'
$null = New-Item -ItemType Directory -Path $skillRoot

function New-SkillFixture {
    param([string]$Root, [string]$Name, [string]$Body = 'Synthetic skill instructions.', [string]$Description = 'Synthetic skill description.', [string]$Folder = $Name)
    $directory = Join-Path $Root $Folder
    $null = New-Item -ItemType Directory -Path $directory -Force
    [IO.File]::WriteAllText((Join-Path $directory 'SKILL.md'), "---`nname: $Name`ndescription: $Description`n---`n$Body")
    $directory
}

function New-SkillFixtureState {
    [CmdletBinding()]
    param([string[]]$Paths = @(), [string[]]$Names = @(), [string]$UserRoot = '')
    & $module {
        param($root, $paths, $names, $userRoot)
        New-AgentHarnessSkillState -WorkingDirectory $root -SkillPath $paths -Skill $names -GlobalSkillPath $userRoot
    } $skillRoot $Paths $Names $UserRoot
}

function Invoke-SkillFixtureTool {
    param([string]$Name, [object]$Arguments = @{}, [hashtable]$Context, [string]$Preference = 'Stop', [int]$MaxOutput = 8000)
    $json = ConvertTo-Json -InputObject $Arguments -Depth 10 -Compress
    & $module {
        param($name, $json, $context, $preference, $maxOutput)
        $ErrorActionPreference = $preference
        Invoke-AgentHarnessToolCall -Call @{ id = 'skill_test'; function = @{ name = $name; arguments = $json } } `
            -ToolTable (Get-AgentHarnessBuiltinTools) -Context $context -MaxOutputChars $maxOutput
    } $Name $json $Context $Preference $MaxOutput
}

$projectSkills = Join-Path $skillRoot '.agents/skills'
$userSkills = Join-Path $skillRoot 'user-skills'
$extraSkills = Join-Path $skillRoot 'extra-skills'
$otherSkills = Join-Path $skillRoot 'other-skills'
$null = New-SkillFixture $projectSkills shared 'Project guidance.'
$null = New-SkillFixture $userSkills shared 'User guidance.'
$chosen = New-SkillFixture $extraSkills shared 'Explicit guidance.'
$review = New-SkillFixture $projectSkills review-ps 'UNIQUE_BODY_NOT_IN_CATALOG' 'Review PowerShell.'
$null = New-Item -ItemType Directory -Path (Join-Path $review 'references')
[IO.File]::WriteAllText((Join-Path $review 'references/notes [1].md'), 'supporting reference')

$state = New-SkillFixtureState -UserRoot $userSkills
Assert-Harness ($state.Catalog.Count -eq 2 -and $state.Catalog.shared.Directory -eq (Join-Path $projectSkills 'shared')) 'Project roots override global roots'
$state = New-SkillFixtureState -Paths @($extraSkills, $extraSkills) -Names shared -UserRoot $userSkills
Assert-Harness ($state.Catalog.shared.Directory -eq $chosen -and $state.ExplicitText.Contains('Explicit guidance.')) 'Explicit root overrides defaults and duplicate root paths scan once'
Assert-Harness (-not $state.Catalog.shared.PSObject.Properties['Body']) 'Catalog retains metadata without instruction bodies'
$context = @{ Root = $skillRoot; Quiet = $true; SkillState = $state }
$catalog = Invoke-SkillFixtureTool list_skills -Context $context
Assert-Harness ($catalog.content.Contains('Review PowerShell.') -and -not $catalog.content.Contains('UNIQUE_BODY_NOT_IN_CATALOG')) 'Catalog tool returns descriptions without loading bodies'
$loaded = Invoke-SkillFixtureTool load_skill @{ name = 'review-ps' } -Context $context
Assert-Harness ($loaded.content.Contains('next_offset=end') -and $loaded.content.Contains('UNIQUE_BODY_NOT_IN_CATALOG')) 'load_skill resolves its own operation and module-private helpers'
$resource = Invoke-SkillFixtureTool read_skill_resource @{ name = 'review-ps'; path = 'references/notes [1].md' } -Context $context
Assert-Harness ($resource.content.EndsWith('supporting reference')) 'Resource reads handle literal square brackets'
$null = New-Item -ItemType Directory -Path (Join-Path $review 'scripts')
[IO.File]::WriteAllText((Join-Path $review 'scripts/helper.ps1'), "throw 'This script must only be read.'")
$scriptResource = Invoke-SkillFixtureTool read_skill_resource @{ name = 'review-ps'; path = 'scripts/helper.ps1' } -Context $context
Assert-Harness ($scriptResource.content.EndsWith("throw 'This script must only be read.'")) 'Reading a script resource returns text without executing it'
$first = Invoke-SkillFixtureTool load_skill @{ name = 'review-ps'; max_chars = 6 } -Context $context
$second = Invoke-SkillFixtureTool load_skill @{ name = 'review-ps'; offset = 6; max_chars = 6 } -Context $context
Assert-Harness ($first.content.Contains('next_offset=6;') -and $first.content.EndsWith('UNIQUE') -and $second.content.EndsWith('_BODY_')) 'Character pagination has explicit continuation without losing content'
$limited = Invoke-SkillFixtureTool load_skill @{ name = 'review-ps' } -Context $context -MaxOutput 30
Assert-Harness ($limited.content -like 'ERROR: Skill page exceeds*' -and -not $limited.content.Contains('UNIQUE_BODY')) 'Small output limit returns an explicit error instead of a partial workflow'

$null = New-SkillFixture $otherSkills shared 'Ambiguous guidance.'
$warnings = @()
$ambiguous = New-SkillFixtureState -Paths @($extraSkills, $otherSkills) -UserRoot $userSkills -WarningVariable warnings 3>$null
Assert-Harness (-not $ambiguous.Catalog.Contains('shared')) 'Same-priority conflicts cannot silently fall back to a lower-priority skill'
Assert-Harness (@($warnings).Count -gt 0) 'Ambiguous names produce a visible diagnostic'
Assert-HarnessThrows { New-SkillFixtureState -Paths @($extraSkills, $otherSkills) -Names shared 3>$null } '*unavailable or invalid*'
Assert-HarnessThrows { New-SkillFixtureState -Paths @('missing-root') } '*directory is missing*'
Assert-HarnessThrows { New-SkillFixtureState -Names missing } '*unavailable or invalid*'

# Strict frontmatter subset: quoted strings, folded/literal descriptions and safe unused metadata.
$formatRoot = Join-Path $skillRoot 'format-skills'
$format = New-SkillFixture $formatRoot quoted
foreach ($description in @('"Quoted: description"', "'It''s quoted'", ">-`n  Folded description`n  continues here", "|-`n  Literal description`n  continues here")) {
    [IO.File]::WriteAllText((Join-Path $format 'SKILL.md'), "---`nname: quoted`ndescription: $description`nmetadata:`n  nested: ignored`n---`nBody.")
    $parsed = & $module { param($path) Read-AgentHarnessSkill -Directory $path } $format
    Assert-Harness ($parsed.Name -eq 'quoted' -and $parsed.Description.Length -gt 5) 'Supported frontmatter strings parse without evaluation'
}
foreach ($header in @('name: BadName', "name: quoted`ndescription: [array]", "name: quoted`ndescription: null", "name: quoted`ndescription: ok`nname: other", "name: quoted`ndescription: 'unclosed", "name: quoted`ndescription: unquoted: colon")) {
    [IO.File]::WriteAllText((Join-Path $format 'SKILL.md'), "---`n$header`n---`nBody.")
    Assert-HarnessThrows { & $module { param($path) Read-AgentHarnessSkill -Directory $path } $format } '*'
}
$invalidState = New-SkillFixtureState -Paths @($formatRoot) 3>$null
Assert-Harness (-not $invalidState.Catalog.Contains('quoted')) 'Discovery skips malformed skills'
$emptyRoot = Join-Path $skillRoot 'empty-project'
$null = New-Item -ItemType Directory -Path $emptyRoot
$emptyState = & $module { param($root) New-AgentHarnessSkillState -WorkingDirectory $root -UserSkillPath '' } $emptyRoot
$emptyPage = Invoke-SkillFixtureTool list_skills -Context @{ Root = $emptyRoot; Quiet = $true; SkillState = $emptyState }
Assert-Harness ($emptyPage.content.EndsWith('[]')) 'An empty catalog is a JSON array'
$largeBody = New-SkillFixture $formatRoot large-body ('x' * 65537)
Assert-HarnessThrows { New-SkillFixtureState -Paths @($formatRoot) -Names large-body 3>$null } '*Explicit skill instructions exceed*'

foreach ($preference in 'Continue', 'Stop') {
    foreach ($arguments in @($null, @(), @(@{ name = 'review-ps' }), @{}, @{ name = 5 }, @{ name = 'REVIEW-PS' }, @{ name = 'missing' }, @{ name = 'review-ps'; offset = -1 }, @{ name = 'review-ps'; offset = 99999 }, @{ name = 'review-ps'; offset = '0' }, @{ name = 'review-ps'; max_chars = $null }, @{ name = 'review-ps'; max_chars = 0 }, @{ name = 'review-ps'; max_chars = 16001 }, @{ name = 'review-ps'; unexpected = $true })) {
        $bad = Invoke-SkillFixtureTool load_skill -Arguments $arguments -Context $context -Preference $preference
        Assert-Harness ($bad.content -like 'ERROR:*') "Invalid skill arguments return a tool error under $preference"
    }
    foreach ($path in @('../shared/SKILL.md', (Join-Path $skillRoot 'outside.txt'), 'missing.md', '.', 'references', 'Initialize.ps1')) {
        $bad = Invoke-SkillFixtureTool read_skill_resource @{ name = 'review-ps'; path = $path } -Context $context -Preference $preference
        Assert-Harness ($bad.content -like 'ERROR:*') "Missing, sensitive or escaping resources are rejected under $preference"
    }
}
$binary = Join-Path $review 'binary.dat'
[IO.File]::WriteAllBytes($binary, [byte[]]@(0, 255, 1))
$bad = Invoke-SkillFixtureTool read_skill_resource @{ name = 'review-ps'; path = 'binary.dat' } -Context $context
Assert-Harness ($bad.content -like 'ERROR:*') 'Binary resources are rejected'
[IO.File]::WriteAllText((Join-Path $review 'large.txt'), ('x' * (1MB + 1)))
$bad = Invoke-SkillFixtureTool read_skill_resource @{ name = 'review-ps'; path = 'large.txt' } -Context $context
Assert-Harness ($bad.content -like 'ERROR:*at most 1 MiB*') 'Oversized resource reads fail before loading the contents'

if ($IsWindows) {
    $junction = Join-Path $review 'linked'
    $null = New-Item -ItemType Junction -Path $junction -Target $chosen
    try {
        $bad = Invoke-SkillFixtureTool read_skill_resource @{ name = 'review-ps'; path = 'linked/SKILL.md' } -Context $context
        Assert-Harness ($bad.content -like 'ERROR:*reparse points*') 'Resource traversal through a junction is rejected'
        $badRoot = New-SkillFixtureState -Paths @($junction) 3>$null
        Assert-Harness ($false) 'An explicit linked root must fail'
    }
    catch { Assert-Harness ($_.Exception.Message -like '*reparse points*') 'Explicit skill roots reject junction ancestry' }
    finally { [IO.Directory]::Delete($junction) }
}

# Adding and editing skills needs no module reload. Refresh also rebuilds explicit instructions.
$null = New-SkillFixture $projectSkills added 'New guidance.'
$refreshed = Invoke-SkillFixtureTool refresh_skills -Context $context
Assert-Harness ($context.SkillPromptDirty -and $state.Catalog.Contains('added') -and $refreshed.content.Contains('added')) 'Refresh discovers a new folder in the existing invocation'
[IO.File]::WriteAllText((Join-Path $chosen 'SKILL.md'), "---`nname: shared`ndescription: Updated description.`n---`nUpdated explicit body.")
$null = Invoke-SkillFixtureTool refresh_skills -Context $context
Assert-Harness ($state.ExplicitText.Contains('Updated explicit body.') -and -not $state.ExplicitText.Contains('Explicit guidance.')) 'Refresh replaces explicitly preloaded guidance'
$removed = New-SkillFixture $projectSkills removed 'Temporary guidance.'
$null = Invoke-SkillFixtureTool refresh_skills -Context $context
[IO.File]::Delete((Join-Path $removed 'SKILL.md'))
$null = Invoke-SkillFixtureTool refresh_skills -Context $context
Assert-Harness (-not $state.Catalog.Contains('removed')) 'Refresh removes deleted skill definitions'

# Public wiring and prompt/tool contracts use only synthetic roots and mocked API calls.
$skillOptions = @{ Model = 'custom-model'; ChatUri = 'https://provider.invalid/chat'; WorkingDirectory = $skillRoot; Quiet = $true; NoAgentsFile = $true; NoModelRecovery = $true; NoSkills = $false; GlobalSkillPath = ''; NoSubAgents = $true }
$globalDefaultRoot = Join-Path $fixture '.agents/skills'
$null = New-SkillFixture $globalDefaultRoot global-workflow 'Default global workflow body.' 'GLOBAL_DEFAULT_DESCRIPTION'
$defaultGlobalState = & $module { param($root) New-AgentHarnessSkillState -WorkingDirectory $root } $skillRoot
Assert-Harness ($defaultGlobalState.Catalog['global-workflow'].Directory -eq (Join-Path $globalDefaultRoot 'global-workflow')) 'Default global root resolves under the module, independent of WorkingDirectory'
$globalOptions = $skillOptions.Clone(); $globalOptions.Remove('GlobalSkillPath')
Set-HarnessResponses @((New-HarnessResponse 'global completed'))
$globalRun = Invoke-AgentHarness 'Discover default global skills' @globalOptions -PassThru
Assert-Harness ($globalRun.Messages[0].content.Contains('GLOBAL_DEFAULT_DESCRIPTION')) 'Public default discovers the module global skill folder from another project'
. (Join-Path $PSScriptRoot 'AgentHarness.SkillModuleLinks.Tests.ps1')
$aliasOptions = $skillOptions.Clone(); $aliasOptions.Remove('GlobalSkillPath'); $aliasOptions.UserSkillPath = ''
Set-HarnessResponses @((New-HarnessResponse 'global disabled by alias'))
$aliasRun = Invoke-AgentHarness 'Skip global root' @aliasOptions -PassThru
Assert-Harness (-not $aliasRun.Messages[0].content.Contains('GLOBAL_DEFAULT_DESCRIPTION')) 'UserSkillPath alias still controls the global root'
Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall load_skill '{"name":"review-ps"}'))), (New-HarnessResponse 'skill completed'))
$run = Invoke-AgentHarness 'Review the fixture' @skillOptions -PassThru
$requests = @(Get-HarnessRequests)
Assert-Harness ($run.Answer -eq 'skill completed' -and @($run.Messages | Where-Object role -eq tool)[0].content.Contains('UNIQUE_BODY')) 'Public entry point wires skill state through the normal tool loop'
Assert-Harness ($requests[0].Body.messages[0].content.Contains('Review PowerShell.') -and -not $requests[0].Body.messages[0].content.Contains('UNIQUE_BODY')) 'Initial system prompt contains only metadata for implicit skills'
Assert-Harness ($requests[0].Body.tools.function.name -contains 'load_skill' -and $requests[0].Body.tools.function.name -contains 'refresh_skills') 'Skill tools reach the provider schemas'

Set-HarnessResponses @((New-HarnessResponse 'explicit completed'))
$explicitRun = Invoke-AgentHarness 'Use selected skill' @skillOptions -Skill review-ps -PassThru
Assert-Harness ($explicitRun.Messages[0].content.Contains('UNIQUE_BODY_NOT_IN_CATALOG')) 'Explicit skill instructions are preloaded'
$disabledOptions = $skillOptions.Clone(); $disabledOptions.NoSkills = $true
Set-HarnessResponses @((New-HarnessResponse 'disabled'))
$disabledRun = Invoke-AgentHarness 'Disabled' @disabledOptions -PassThru
Assert-Harness (-not $disabledRun.Messages[0].content.Contains('Folder skills') -and @(Get-HarnessRequests)[0].Body.tools.function.name -notcontains 'load_skill') 'NoSkills removes both discovery context and skill tools'
Set-HarnessResponses @((New-HarnessResponse 'no builtins'))
$null = Invoke-AgentHarness 'No builtins' @skillOptions -NoBuiltinTools
Assert-Harness (-not @(Get-HarnessRequests)[0].Body.PSObject.Properties['tools']) 'NoBuiltinTools disables skills along with other built-ins'
Assert-HarnessThrows { Invoke-AgentHarness 'Conflicting options' @disabledOptions -Skill review-ps } '*cannot be combined*'
Assert-HarnessThrows { Invoke-AgentHarness 'Conflicting options' @skillOptions -NoBuiltinTools -Skill review-ps } '*cannot be combined*'

$customSkill = @{ load_skill = @{ Description = 'Custom override.'; Parameters = @{ type = 'object'; properties = @{} }; Script = { param($a, $ctx) 'custom skill result' } } }
Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall load_skill))), (New-HarnessResponse 'custom completed'))
$customRun = Invoke-AgentHarness 'Custom tool' @skillOptions -Tools $customSkill -PassThru
Assert-Harness (@($customRun.Messages | Where-Object role -eq tool)[0].content -eq 'custom skill result') 'Existing custom tool override behavior is preserved'

# Simulate a tool that edits a folder, followed by a real refresh in the same task.
$dynamic = @{ add_fixture_skill = @{ Parameters = @{ type = 'object'; properties = @{} }; Script = {
    param($a, $ctx)
    $directory = Join-Path $ctx.Root '.agents/skills/dynamic'
    $null = New-Item -ItemType Directory -Path $directory -Force
    [IO.File]::WriteAllText((Join-Path $directory 'SKILL.md'), "---`nname: dynamic`ndescription: Dynamic fixture description.`n---`nDynamic fixture instructions.")
    'Added fixture.'
} } }
Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall add_fixture_skill))), (New-HarnessResponse '' @((New-HarnessCall refresh_skills))), (New-HarnessResponse 'refreshed'))
$null = Invoke-AgentHarness 'Refresh while running' @skillOptions -Tools $dynamic
$requests = @(Get-HarnessRequests)
Assert-Harness (-not $requests[0].Body.messages[0].content.Contains('Dynamic fixture description.') -and $requests[-1].Body.messages[0].content.Contains('Dynamic fixture description.')) 'Explicit refresh updates the system catalog before the next model request'

# Continuation drops implicit tool results, refreshes the catalog and reloads explicit bodies.
$savedSkillNextPrompt = & $module { ${function:Read-AgentHarnessNextPrompt} }
try {
    & $module {
        $script:SkillContinuationCount = 0
        function script:Read-AgentHarnessNextPrompt {
            param($Answer, $NoPromptSound, $SkipAnswer)
            $script:SkillContinuationCount++
            if ($script:SkillContinuationCount -gt 1) { return $null }
            $directory = Join-Path $script:SkillContinuationRoot '.agents/skills/review-ps'
            [IO.File]::WriteAllText((Join-Path $directory 'SKILL.md'), "---`nname: review-ps`ndescription: Changed between tasks.`n---`nRELOADED_EXPLICIT_BODY")
            'Continue the fixture'
        }
    }
    & $module { param($root) $script:SkillContinuationRoot = $root } $skillRoot
    Set-HarnessResponses @((New-HarnessResponse '' @((New-HarnessCall load_skill '{"name":"shared"}'))), (New-HarnessResponse 'first answer'), (New-HarnessResponse 'second answer'))
    $continued = Invoke-AgentHarness 'First fixture task' @skillOptions -Skill review-ps -NoCompletionPrompt:$false -PassThru
    $requests = @(Get-HarnessRequests)
    Assert-Harness ($continued.Answer -eq 'second answer' -and $requests[-1].Body.messages[0].content.Contains('RELOADED_EXPLICIT_BODY') -and -not $requests[-1].Body.messages[0].content.Contains('UNIQUE_BODY')) 'Continuation reloads explicit skills after filesystem edits'
    Assert-Harness (@($requests[-1].Body.messages | Where-Object role -eq tool).Count -eq 0) 'Implicit skill pages are removed by ordinary continuation compaction'
}
finally { & $module { param($reader) Set-Item Function:script:Read-AgentHarnessNextPrompt -Value $reader } $savedSkillNextPrompt }
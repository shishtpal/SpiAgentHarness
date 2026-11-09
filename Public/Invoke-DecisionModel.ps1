#requires -Version 7.0
<#
.SYNOPSIS
    Evaluate state with a typed decision model through configurable protocol adapters.
.DESCRIPTION
    Supply text or JSON context and named choice, noul (yes/no probability), or
    score questions. Returns structured answers, probabilities and request metadata.
    Uses the provider registry's DecisionUri and key environment variable. Explicit
    model IDs bypass the bundled catalogue. -Pick defaults to free model variants;
    add -All to include paid variants. No model fallback or continuation prompts.
    Use -QuestionsFile or -StateFile to load JSON instead of supplying objects.
    The console shows one row per question; the Summary property holds those rows.
    -OutFile also saves the result as JSON (without RawResponse) and still returns it.
    -Attachment adds image files (PNG, JPEG, GIF or WebP) to the state. The state then
    becomes an ordered content array: the context as text, followed by the images.
    ExperientialLabs routes Luna to openai_decisions and Clef to systemone.
    -Protocol selects an adapter explicitly; -KeyEnvVar overrides the credential
    environment-variable name. Native protocols default to zero retries.
.EXAMPLE
    $questions = @{ relevant = @{ type = 'noul'; instructions = 'Is this about billing?'; criteria = @{ 'true' = 'Billing or payments'; 'false' = 'Other topics' } } }
    Invoke-DecisionModel -State 'Where is my invoice?' -Questions $questions -Model 'inception/mercury-decide:free'
.EXAMPLE
    Invoke-DecisionModel -State $ticket -Questions $questions -Pick -All
.EXAMPLE
    Invoke-DecisionModel -State 'Where is my invoice?' -QuestionsFile './questions.json' -Pick -All
.EXAMPLE
    Invoke-DecisionModel -StateFile './state.json' -QuestionsFile './questions.json' -Model 'typesafe/jev-1.14'
.EXAMPLE
    Invoke-DecisionModel -StateFile './state.json' -QuestionsFile './questions.json' -Pick -All -OutFile './result.json'
.EXAMPLE
    Invoke-DecisionModel -State 'Is this receipt a refund?' -Questions $questions -Model 'openai/gpt-6-luna-decisions' -Attachment './receipt.png'
#>
function Invoke-DecisionModel {
    [CmdletBinding(DefaultParameterSetName = 'Model')]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][AllowEmptyCollection()][object]$State,
        [AllowNull()][AllowEmptyCollection()][object]$Questions,
        [Parameter(ParameterSetName = 'Model')][ValidateNotNullOrEmpty()][string]$Model,
        [Parameter(ParameterSetName = 'Pick')][switch]$Pick,
        [Parameter(ParameterSetName = 'Pick')][string]$ModelFilter = '*',
        [Parameter(ParameterSetName = 'Pick')][switch]$All,
        [AllowNull()][AllowEmptyCollection()][string[]]$Attachment,
        [ValidateNotNullOrEmpty()][string]$Provider = 'OpenRouter',
        [string]$DecisionUri,
        [string]$ApiKey,
        [ValidateSet('openrouter', 'openai_decisions', 'systemone')][string]$Protocol,
        [ValidateNotNullOrEmpty()][string]$KeyEnvVar,
        [ValidateRange(1, [int]::MaxValue)][int]$TimeoutSec = 120,
        [ValidateRange(0, 5)][int]$MaxRetries = 3,
        [switch]$Quiet,
        [Alias('QuestionsPath')][ValidateNotNullOrEmpty()][string]$QuestionsFile,
        [Alias('StatePath')][ValidateNotNullOrEmpty()][string]$StateFile,
        [ValidateNotNullOrEmpty()][string]$OutFile
    )

    if ([string]::IsNullOrWhiteSpace($Model) -and -not $Pick) { throw 'Specify -Model <id> or -Pick.' }
    if ($PSBoundParameters.ContainsKey('State') -eq $PSBoundParameters.ContainsKey('StateFile')) {
        throw 'Specify exactly one of -State or -StateFile.'
    }
    if ($PSBoundParameters.ContainsKey('Questions') -eq $PSBoundParameters.ContainsKey('QuestionsFile')) {
        throw 'Specify exactly one of -Questions or -QuestionsFile.'
    }
    if ($PSBoundParameters.ContainsKey('QuestionsFile')) {
        $Questions = Read-DecisionModelJsonFile -LiteralPath $QuestionsFile -Name 'QuestionsFile'
    }
    if ($PSBoundParameters.ContainsKey('StateFile')) {
        $State = Read-DecisionModelJsonFile -LiteralPath $StateFile -Name 'StateFile'
    }
    # Validate the output path, context and questions before opening a picker or making a request.
    $outPath = $null
    if ($PSBoundParameters.ContainsKey('OutFile')) { $outPath = Resolve-DecisionModelOutFile -Path $OutFile }
    if ($Pick) {
        # Validate evidence before displaying a menu, without assuming the selected protocol.
        $null = New-DecisionModelRequest -State $State -Questions $Questions -Model $Model -Attachment $Attachment
        $null = Get-DecisionModelProviderConfig -Provider $Provider -DecisionUri $DecisionUri -ApiKey $ApiKey -KeyEnvVar $KeyEnvVar
        $Model = Select-DecisionModel -Provider $Provider -ModelFilter $ModelFilter -All:$All
    }
    $route = Resolve-DecisionModelProtocol -Provider $Provider -Model $Model -Protocol $Protocol -DecisionUri $DecisionUri
    $Protocol = $route.Protocol
    if ($Protocol -ne 'openrouter' -and -not $PSBoundParameters.ContainsKey('MaxRetries')) { $MaxRetries = 0 }
    $request = New-DecisionModelRequest -State $State -Questions $Questions -Model $Model -Attachment $Attachment -Protocol $Protocol
    $config = Get-DecisionModelProviderConfig -Provider $Provider -DecisionUri $route.DecisionUri -ApiKey $ApiKey -KeyEnvVar $KeyEnvVar
    # Capture the module-bound helper before creating a dynamic closure.
    $writeLogMessage = ${function:Write-LogMessage}
    $log = {
        param([string]$Text, [string]$Color = 'Gray')
        & $writeLogMessage -Message $Text -Color $Color -NoTimestamp -Silent:$Quiet
    }.GetNewClosure()
    & $log "Decision model: [$Provider] $Model" 'Cyan'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-DecisionModelRequest -Uri $config.Uri -ApiKey $config.ApiKey -Json $request.Json `
            -TimeoutSec $TimeoutSec -MaxRetries $MaxRetries -Log $log
    }
    finally { $timer.Stop() }
    $normalized = ConvertFrom-DecisionModelProtocolResponse -Response $response -Questions $request.Questions -Protocol $Protocol
    $result = ConvertFrom-DecisionModelResponse -Response $normalized -Questions $request.Questions `
        -RequestedModel $Model -Provider $Provider -ElapsedMilliseconds $timer.Elapsed.TotalMilliseconds `
        -AllowMissingProbabilities:($Protocol -ne 'openrouter') -AllowRefusal:($Protocol -ne 'openrouter')
    $result.RawResponse = $response
    & $log ("Decision request completed in {0:N0} ms." -f $result.ElapsedMilliseconds) 'DarkGray'
    if ($outPath) {
        # The request already succeeded (and may have cost credits); warn and still return the result.
        try {
            Export-DecisionModelResult -Result $result -LiteralPath $outPath
            & $log "Decision result saved to $outPath" 'DarkGray'
        }
        catch { Write-Warning 'Cannot write OutFile. Check the path and permissions; the result is still returned.' }
    }
    $result
}
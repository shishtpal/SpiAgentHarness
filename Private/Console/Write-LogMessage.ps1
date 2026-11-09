<#
.SYNOPSIS
    Writes formatted log messages to console and/or log file with advanced formatting and log levels.

.DESCRIPTION
    The Write-LogMessage function provides comprehensive logging capabilities with support for different
    log levels, colored console output, file logging, timestamps, and advanced formatting options.
    It supports multiple log levels (DEBUG, INFO, WARNING, ERROR, CRITICAL) and can write to both
    console and log files simultaneously.

.PARAMETER Message
    The message to log. This parameter is mandatory and supports pipeline input.

.PARAMETER LogFile
    The path to the log file where messages should be written. If the directory doesn't exist,
    it will be created automatically. Supports both relative and absolute paths.

.PARAMETER Level
    The log level for the message. Valid values are:
    - DEBUG: Detailed diagnostic information
    - INFO: General information messages (default)
    - WARNING: Warning messages for potentially harmful situations
    - ERROR: Error messages for serious problems
    - CRITICAL: Critical error messages for system-level failures

.PARAMETER Silent
    If specified, suppresses console output. Log file writing (if specified) continues normally.

.PARAMETER NoTimestamp
    If specified, omits the timestamp from the log entry.

.PARAMETER Color
    The console text color for the message. Defaults based on log level:
    - DEBUG: DarkGray
    - INFO: White
    - WARNING: Yellow
    - ERROR: Red
    - CRITICAL: DarkRed

.PARAMETER PassThru
    If specified, returns a log entry object for further processing.

.PARAMETER CreateDirectory
    If specified, creates the log file directory if it doesn't exist.

.EXAMPLE
    Write-LogMessage -Message "Application started successfully"
    Writes an info-level message to console with default formatting.

.EXAMPLE
    Write-LogMessage -Message "Configuration file not found" -Level WARNING -LogFile "C:\logs\app.log"
    Writes a warning message to both console (in yellow) and log file.

.EXAMPLE
    Write-LogMessage -Message "Database connection failed" -Level ERROR -Silent
    Writes an error message only to the log file (console output suppressed).

.EXAMPLE
    Write-LogMessage -Message "Detailed debug information" -Level DEBUG -Color DarkGray
    Writes a debug message with custom color settings.

.EXAMPLE
    "Processing item 1", "Processing item 2" | Write-LogMessage -LogFile "process.log" -PassThru
    Processes multiple messages from pipeline and returns log entry objects.

.NOTES
    Author: SpiAgentHarness Module
    Version: 2.0
    Requirements: PowerShell 5.1 or higher

    The function automatically creates log directories if they don't exist and the -CreateDirectory
    parameter is specified. Log files are encoded in UTF-8 format for maximum compatibility.
#>
function Write-LogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$LogFile,

        [Parameter(Mandatory = $false)]
        [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [switch]$NoTimestamp,

        [Parameter(Mandatory = $false)]
        [string]$Color,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [switch]$CreateDirectory
    )

    begin {
        # Define default colors for each log level
        $defaultColors = @{
            'DEBUG'    = 'DarkGray'
            'INFO'     = 'White'
            'WARNING'  = 'Yellow'
            'ERROR'    = 'Red'
            'CRITICAL' = 'DarkRed'
        }

        # Use specified color or default for the level
        $outputColor = if ($Color) { $Color } else { $defaultColors[$Level] }

        Write-Verbose "Log message initialization - Level: $Level, Color: $outputColor"
    }

    process {
        foreach ($msg in $Message) {
            try {
                # Generate timestamp if not suppressed
                $timestamp = if (-not $NoTimestamp) {
                    Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                } else {
                    ""
                }

                # Format log entry based on level and timestamp
                $logEntry = if ($NoTimestamp) {
                    "[$Level] $msg"
                } elseif ($timestamp) {
                    "[$timestamp] [$Level] $msg"
                } else {
                    "[$Level] $msg"
                }

                # Write to console unless silent
                if (-not $Silent) {
                    Write-Host $logEntry -ForegroundColor $outputColor
                }

                # Write to log file if specified
                if ($LogFile) {
                    try {
                        # Resolve and validate log file path
                        $resolvedLogFile = $LogFile

                        # Handle relative paths
                        if (-not [System.IO.Path]::IsPathRooted($LogFile)) {
                            $resolvedLogFile = Join-Path (Get-Location) $LogFile
                        }

                        # Create directory if requested and doesn't exist
                        $logDir = Split-Path $resolvedLogFile -Parent
                        if ($CreateDirectory -and $logDir -and -not (Test-Path $logDir)) {
                            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
                            Write-Verbose "Created log directory: $logDir"
                        }

                        # Validate log directory exists
                        if ($logDir -and -not (Test-Path $logDir)) {
                            throw "Log directory does not exist: $logDir"
                        }

                        # Write to log file
                        $logEntry | Out-File -FilePath $resolvedLogFile -Append -Encoding UTF8

                        Write-Verbose "Successfully wrote to log file: $resolvedLogFile"
                    }
                    catch {
                        $errorMsg = "Failed to write to log file '$LogFile': $($_.Exception.Message)"

                        if (-not $Silent) {
                            Write-Warning $errorMsg
                        }

                        Write-Error $errorMsg
                    }
                }

                # Return log entry object if PassThru is specified
                if ($PassThru) {
                    [PSCustomObject]@{
                        Timestamp = $timestamp
                        Level = $Level
                        Message = $msg
                        LogFile = $LogFile
                        Color = $outputColor
                        Silent = $Silent.IsPresent
                    }
                }
            }
            catch {
                $errorMsg = "Failed to process log message: $($_.Exception.Message)"

                if (-not $Silent) {
                    Write-Warning $errorMsg
                }

                Write-Error $errorMsg
            }
        }
    }

    end {
        Write-Verbose "Log message processing completed"
    }
}
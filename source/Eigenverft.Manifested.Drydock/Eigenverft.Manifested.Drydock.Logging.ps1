function Write-ConsoleLog {
<#
.SYNOPSIS
Minimal console logger for PowerShell 5 (space layout), UTC by default.

.DESCRIPTION
Emits: "[yyyy-MM-dd HH:mm:ss:fff LEVEL] [file.ps1] [function] message"
- Time is UTC by default. Use -LocalTime to log in local time.
- Auto-resolves caller script file and function from the call stack.
- Plain text, deterministic output (no colors).

.PARAMETER Message
The message to log. Mandatory and non-empty.

.PARAMETER Level
Severity tag. One of: TRC, DBG, INF, WRN, ERR, FTL. Defaults to INF.

.PARAMETER LocalTime
When present, uses local time instead of UTC.

.PARAMETER ContinueOnError
When present, do NOT exit on ERR/FTL. By default the function exits on ERR (code 1) and FTL (code 2).

.PARAMETER QuietExceptCritical
Suppress all output except ERR and FTL.

.PARAMETER QuietExceptWarning
Suppress all output except WRN, ERR, and FTL.

.EXAMPLE
function MakeDirs {
    Write-ConsoleLog -Level INF -Message 'Dirscreated.'
}
MakeDirs
# -> [2025-10-12 04:47:17:265 INF] [out.ps1] [makedirs] Dirscreated.

.EXAMPLE
# Use in try/catch; include the error message via $_ and keep running.
try {
    Throw "Something went wrong."
}
catch {
    # Default would exit on ERR; add -ContinueOnError to log and continue.
    # Write-ConsoleLog -Level ERR -ContinueOnError -Message ("Caught error: {0}" -f $_.Exception.Message)
    # Alternatively include the whole error record:
    # Write-ConsoleLog -Level ERR -ContinueOnError -Message ("Caught error: {0}" -f $_)
}

.EXAMPLE
Write-ConsoleLog -Message 'customtext.' -Level WRN -LocalTime
# -> [2025-10-12 06:47:17:265 WRN] [fileofthefunction] [functionnameinfile] customtext.

.NOTES
- Default: exit on ERR (1) and FTL (2). Use -ContinueOnError to keep going.
- If both quiet switches are supplied, QuietExceptCritical takes precedence.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')]
        [string]$Level = 'INF',

        [Parameter()]
        [switch]$LocalTime,

        [Parameter()]
        [switch]$ContinueOnError,

        [Parameter()]
        [switch]$QuietExceptCritical,

        [Parameter()]
        [switch]$QuietExceptWarning
    )

    # Timestamp (UTC by default).
    $now = if ($LocalTime.IsPresent) { Get-Date } else { [DateTime]::UtcNow }
    $ts  = $now.ToString('yyyy-MM-dd HH:mm:ss:fff')

    # Resolve file/function from call stack.
    $self   = $MyInvocation.MyCommand.Name
    $caller = Get-PSCallStack | Where-Object { $_.FunctionName -ne $self } | Select-Object -First 1
    if (-not $caller) {
        $caller = [pscustomobject]@{
            ScriptName   = $PSCommandPath
            FunctionName = '<scriptblock>'
            Location     = $null
            Command      = $null
        }
    }

    $file =
        if ($caller.ScriptName) { Split-Path -Leaf $caller.ScriptName }
        elseif ($caller.Location -and $caller.Location -match '^(.*?):\d+') { Split-Path -Leaf $Matches[1] }
        else { 'console' }

    $func =
        if ($caller.FunctionName) { $caller.FunctionName }
        elseif ($caller.Command)  { $caller.Command }
        else { '<scriptblock>' }

    $lvl = $Level.ToUpperInvariant()

    # Severity ranking.
    $sevMap = @{ TRC=0; DBG=1; INF=2; WRN=3; ERR=4; FTL=5 }
    $sev    = $sevMap[$lvl]

    # Quieting rules (QuietExceptCritical is stricter; give it precedence).
    $shouldWrite = $true
    if ($QuietExceptCritical.IsPresent) {
        if ($sev -lt 4) { $shouldWrite = $false }
    }
    elseif ($QuietExceptWarning.IsPresent) {
        if ($sev -lt 3) { $shouldWrite = $false }
    }

    # Format the line.
    $line = "[{0} {1}] [{2}] [{3}] {4}" -f $ts, $lvl, $file, $func.ToLower(), $Message

    if ($shouldWrite) {
        Write-Host $line
    }

    # Default: stop on ERR/FTL unless -ContinueOnError is specified.
    if (-not $ContinueOnError.IsPresent -and $sev -ge 4) {
        exit (if ($sev -ge 5) { 2 } else { 1 })
    }
}


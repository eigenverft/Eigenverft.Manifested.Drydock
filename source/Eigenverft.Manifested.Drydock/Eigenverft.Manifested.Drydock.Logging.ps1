function Write-ConsoleLog {
    <#
    .SYNOPSIS
    Writes a standardized log message with level, timestamp, and caller context.

    .DESCRIPTION
    Formats and writes console messages with a severity level, including timestamp and caller file/line info.
    Uses an effective minimum log level from the MinLevel parameter or the global ConsoleLogMinLevel variable.
    For ERR/FTL messages and ErrorActionPreference 'Stop', an exception is thrown after writing.

    .PARAMETER Message
    The message text to write.

    .PARAMETER Level
    The severity level of the message. Valid: TRC, DBG, INF, WRN, ERR, FTL.

    .PARAMETER MinLevel
    The minimum severity level required to output a message. If omitted, ConsoleLogMinLevel or INF is used.

    .EXAMPLE
    Write-ConsoleLog -Message 'Initialization complete.' -Level INF

    Writes an informational message including timestamp, level, and caller context.
    #>

    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
    # This function is globally exempt from the GENERAL POWERSHELL REQUIREMENTS unless explicitly stated otherwise.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')]
        [string]$Level = 'INF',

        [Parameter()]
        [ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')]
        [string]$MinLevel
    )

    # Normalize null input defensively.
    if ($null -eq $Message) {
        $Message = [string]::Empty
    }

    # Severity mapping for gating.
    $sevMap = @{
        TRC = 0
        DBG = 1
        INF = 2
        WRN = 3
        ERR = 4
        FTL = 5
    }

    # Resolve effective minimum level (parameter > global var > default).
    if (-not $PSBoundParameters.ContainsKey('MinLevel')) {
        $gv = Get-Variable ConsoleLogMinLevel -Scope Global -ErrorAction SilentlyContinue
        $MinLevel = if ($gv -and $gv.Value -and -not [string]::IsNullOrEmpty([string]$gv.Value)) {
            [string]$gv.Value
        }
        else {
            'INF'
        }
    }

    $lvl = $Level.ToUpperInvariant()
    $min = $MinLevel.ToUpperInvariant()

    $sev = $sevMap[$lvl]
    if ($null -eq $sev) {
        $lvl = 'INF'
        $sev = $sevMap['INF']
    }

    $gate = $sevMap[$min]
    if ($null -eq $gate) {
        $min = 'INF'
        $gate = $sevMap['INF']
    }

    # If configuration demands a higher error-level minimum, align upward.
    if ($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4) {
        $lvl = $min
        $sev = $gate
    }

    # Below threshold: do nothing.
    if ($sev -lt $gate) {
        return
    }

    $ts = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss:fff')

    # Caller resolution: first frame that is not this function.
    $helperName = $MyInvocation.MyCommand.Name
    $stack      = Get-PSCallStack
    $caller     = $null

    if ($stack) {
        foreach ($frame in $stack) {
            if ($frame.FunctionName -and $frame.FunctionName -ne $helperName) {
                $caller = $frame
                break
            }
        }
    }

    if (-not $caller) {
        # Fallback when called from script/host directly.
        $caller = [pscustomobject]@{
            ScriptName   = $PSCommandPath
            FunctionName = $null
        }
    }

    # Try multiple strategies to get a line number from the caller metadata.
    $lineNumber = $null

    $p = $caller.PSObject.Properties['ScriptLineNumber']
    if ($p -and $p.Value) {
        $lineNumber = [string]$p.Value
    }

    if (-not $lineNumber) {
        $p = $caller.PSObject.Properties['Position']
        if ($p -and $p.Value) {
            $sp = $p.Value.PSObject.Properties['StartLineNumber']
            if ($sp -and $sp.Value) {
                $lineNumber = [string]$sp.Value
            }
        }
    }

    if (-not $lineNumber) {
        $p = $caller.PSObject.Properties['Location']
        if ($p -and $p.Value) {
            $m = [regex]::Match([string]$p.Value, ':(\d+)\s+char:', 'IgnoreCase')
            if ($m.Success -and $m.Groups.Count -gt 1) {
                $lineNumber = $m.Groups[1].Value
            }
        }
    }

    $file = if ($caller.ScriptName) { Split-Path -Leaf $caller.ScriptName } else { 'cmd' }

    if ($file -ne 'console' -and $lineNumber) {
        $file = '{0}:{1}' -f $file, $lineNumber
    }

    $prefix = "[$ts "
    $suffix = "] [$file] $Message"

    # Level-to-color configuration.
    $cfg = @{
        TRC = @{ Fore = 'DarkGray'; Back = $null     }
        DBG = @{ Fore = 'Cyan';     Back = $null     }
        INF = @{ Fore = 'Green';    Back = $null     }
        WRN = @{ Fore = 'Yellow';   Back = $null     }
        ERR = @{ Fore = 'Red';      Back = $null     }
        FTL = @{ Fore = 'Red';      Back = 'DarkRed' }
    }[$lvl]

    $fore = $cfg.Fore
    $back = $cfg.Back

    $isInteractive = [System.Environment]::UserInteractive

    if ($isInteractive -and ($fore -or $back)) {
        Write-Host -NoNewline $prefix

        if ($fore -and $back) {
            Write-Host -NoNewline $lvl -ForegroundColor $fore -BackgroundColor $back
        }
        elseif ($fore) {
            Write-Host -NoNewline $lvl -ForegroundColor $fore
        }
        elseif ($back) {
            Write-Host -NoNewline $lvl -BackgroundColor $back
        }

        Write-Host $suffix
    }
    else {
        Write-Host "$prefix$lvl$suffix"
    }

    # For high severities with strict error handling, escalate via exception.
    if ($sev -ge 4 -and $ErrorActionPreference -eq 'Stop') {
        throw ("ConsoleLog.{0}: {1}" -f $lvl, $Message)
    }
}

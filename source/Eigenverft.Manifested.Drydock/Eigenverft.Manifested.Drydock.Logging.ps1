function Write-ConsoleLog {
<#
.SYNOPSIS
Deterministic logger gated ONLY by MinLevel; non-errors use Output, errors use Error.

.DESCRIPTION
Formats: "[yyyy-MM-dd HH:mm:ss:fff LEVEL] [file.ps1] [function] message"
Visibility is controlled solely by MinLevel (TRC..FTL). Preferences like Verbose/Debug/Warning do not affect output.
Streams:
  - TRC/DBG/INF/WRN -> Write-Output
  - ERR/FTL         -> Write-Error (terminates when $ErrorActionPreference = 'Stop')
If an error is requested (ERR/FTL) but MinLevel is stricter (e.g., FTL), the function auto-escalates to match MinLevel
so it isn’t filtered out (useful in catch).

.PARAMETER Message
Text to log.

.PARAMETER Level
TRC | DBG | INF | WRN | ERR | FTL. Default: INF.

.PARAMETER MinLevel
TRC | DBG | INF | WRN | ERR | FTL. Defaults to $Global:ConsoleLogMinLevel or 'INF'.

.PARAMETER LocalTime
Use local time (UTC is default).

.EXAMPLE
# Global config (only these matter)
$ErrorActionPreference     = 'Stop'   # errors become terminating
$Global:ConsoleLogMinLevel = 'INF'    # gate: TRC/DBG/INF/WRN/ERR/FTL

.EXAMPLE
# 1) Normal flow
Write-ConsoleLog -Level INF -Message 'started'     # goes to Output

.EXAMPLE
# 2) Try/Catch – you just say ERR in catch
try {
    Write-ConsoleLog -Level INF -Message 'work ok'
}
catch {
    Write-ConsoleLog -Level ERR -Message 'not ok'   # goes to Error; terminates because EAPref=Stop
}

.EXAMPLE
# 3) Gate to warnings and above (no preferences involved)
$Global:ConsoleLogMinLevel = 'WRN'
Write-ConsoleLog -Level INF -Message 'hidden'
Write-ConsoleLog -Level WRN -Message 'shown (Output)'

.EXAMPLE
# 4) Gate to fatal only; catch auto-escalates
$Global:ConsoleLogMinLevel = 'FTL'
try { throw 'boom' } catch { Write-ConsoleLog -Level ERR -Message 'fatal path' }  # escalates to FTL → Error → Stop
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
        [ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')]
        [string]$MinLevel,

        [Parameter()]
        [switch]$LocalTime
    )

    # Resolve MinLevel: explicit > global > default
    if (-not $PSBoundParameters.ContainsKey('MinLevel')) {
        $MinLevel = if ($Global:ConsoleLogMinLevel) { $Global:ConsoleLogMinLevel } else { 'INF' }
    }

    $sevMap = @{ TRC=0; DBG=1; INF=2; WRN=3; ERR=4; FTL=5 }
    $lvl = $Level.ToUpperInvariant()
    $min = $MinLevel.ToUpperInvariant()
    $sev = $sevMap[$lvl]
    $gate= $sevMap[$min]

    # Auto-escalate requested errors to meet strict MinLevel (e.g., MinLevel=FTL)
    if ($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4) {
        $lvl = $min
        $sev = $gate
    }

    # Drop below gate
    if ($sev -lt $gate) { return }

    # Format line
    $now = if ($LocalTime) { Get-Date } else { [DateTime]::UtcNow }
    $ts  = $now.ToString('yyyy-MM-dd HH:mm:ss:fff')

    # Resolve caller (external reviewer perspective)
    $self   = $MyInvocation.MyCommand.Name
    $caller = Get-PSCallStack | Where-Object { $_.FunctionName -ne $self } | Select-Object -First 1
    if (-not $caller) { $caller = [pscustomobject]@{ ScriptName=$PSCommandPath; FunctionName='<scriptblock>' } }

    $file = if ($caller.ScriptName) { Split-Path -Leaf $caller.ScriptName } else { 'console' }
    $func = if ($caller.FunctionName) { $caller.FunctionName } else { '<scriptblock>' }
    $line = "[{0} {1}] [{2}] [{3}] {4}" -f $ts, $lvl, $file, $func.ToLower(), $Message

    # Emit: Output for non-errors; Error for ERR/FTL. Termination via $ErrorActionPreference.
    if ($sev -ge 4) {
        if ($ErrorActionPreference -eq 'Stop') {
            Write-Error -Message $line -ErrorId ("ConsoleLog.{0}" -f $lvl) -Category NotSpecified -ErrorAction Stop
        } else {
            Write-Error -Message $line -ErrorId ("ConsoleLog.{0}" -f $lvl) -Category NotSpecified
        }
    } else {
        Write-Information -MessageData $line -InformationAction Continue
    }
}




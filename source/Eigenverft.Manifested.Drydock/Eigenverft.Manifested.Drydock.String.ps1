function Join-Text {
<#
.SYNOPSIS
Joins values into one string, skipping null, empty, or whitespace-only entries.

.DESCRIPTION
Accepts an array of input values, converts each to string, optionally trims, filters out
null/empty/whitespace-only strings using [string]::IsNullOrWhiteSpace, and joins the remaining
entries using the specified separator. Designed to be idempotent and StrictMode level 3 safe.

.PARAMETER InputObject
Array of values to join. Elements may be of any type. Nulls are ignored.

.PARAMETER Separator
Text to insert between kept items. Defaults to ", ". Empty string is allowed.

.PARAMETER Normalization
Whether to keep each item as-is or trim it before testing/output.
Allowed values:
- Keep : Do not trim values (default).
- Trim : Trim each value before testing and output.

.PARAMETER LogLevel
Optional console log emission using the inline _Write-StandardMessage helper.
Allowed values:
- None (default): Emit no log lines.
- TRC|DBG|INF|WRN|ERR|FTL: Emit a single summary line at the chosen severity.

.EXAMPLE
Join-Text -InputObject @('a', '', '  ', $null, 'b') -Separator ', '
# Returns: "a, b"

.EXAMPLE
Join-Text -InputObject @(' a ', '', '  ', $null, ' b ') -Separator '; ' -Normalization Trim
# Returns: "a; b"

.EXAMPLE
Join-Text -InputObject @(1, $null, 2, ' ', 3) -Separator '|'
# Returns: "1|2|3"

.EXAMPLE
Join-Text -InputObject @('x', '', 'y') -LogLevel INF
# Emits one information line (on the Information stream) and returns: "x, y"

.NOTES
- Compatible with Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
- No ValueFromPipeline usage; no SupportsShouldProcess.
- Avoids reading automatic/reserved variables in the function body.
- Idempotent: repeated calls with the same inputs yield the same output without side effects.
- StrictMode level 3 safe by construction.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object[]]$InputObject,

        [AllowEmptyString()]
        [string]$Separator = ', ',

        [ValidateSet('Keep', 'Trim')]
        [string]$Normalization = 'Keep',

        [ValidateSet('None','TRC','DBG','INF','WRN','ERR','FTL')]
        [string]$LogLevel = 'None'
    )

    # Inline helper for minimal, structured console messages.
    # NOTE: This helper is explicitly allowed to deviate from some rules per your spec.
    function _Write-StandardMessage {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$Message,
            [Parameter(Mandatory = $false)]
            [ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')]
            [string]$Level = 'INF',
            [Parameter(Mandatory = $false)]
            [ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')]
            [string]$MinLevel
        )
        if (-not $PSBoundParameters.ContainsKey('MinLevel')) {
            $gv = Get-Variable -Name 'ConsoleLogMinLevel' -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $gv -and $null -ne $gv.Value -and -not [string]::IsNullOrEmpty([string]$gv.Value)) {
                $MinLevel = [string]$gv.Value
            } else {
                $MinLevel = 'INF'
            }
        }
        $sevMap = @{ TRC=0; DBG=1; INF=2; WRN=3; ERR=4; FTL=5 }
        $lvl  = $Level.ToUpperInvariant()
        $min  = $MinLevel.ToUpperInvariant()
        $sev  = $sevMap[$lvl]
        $gate = $sevMap[$min]
        if ($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4) { $lvl = $min ; $sev = $gate }
        if ($sev -lt $gate) { return }
        $ts = ([DateTime]::UtcNow).ToString('yyyy-MM-dd HH:mm:ss:fff')
        $stack      = Get-PSCallStack
        $helperName = $MyInvocation.MyCommand.Name
        $orgFunc    = $null
        $caller     = $null
        if ($stack) {
            $orgIdx = -1
            for ($i = 0; $i -lt $stack.Count; $i++) {
                if ($stack[$i].FunctionName -ne $helperName) { $orgFunc = $stack[$i]; $orgIdx = $i; break }
            }
            if ($orgIdx -ge 0) {
                $callerIdx = $orgIdx + 1
                if ($stack.Count -gt $callerIdx) { $caller = $stack[$callerIdx] } else { $caller = $orgFunc }
            }
        }
        if (-not $caller) { $caller = [pscustomobject]@{ ScriptName = $PSCommandPath; FunctionName = '<scriptblock>' } }
        $file = if ($caller.ScriptName) { Split-Path -Leaf $caller.ScriptName } else { 'console' }
        $func = if ($caller.FunctionName) { $caller.FunctionName } else { '<scriptblock>' }
        $line = "[{0} {1}] [{2}] [{3}] {4}" -f $ts, $lvl, $file, $func, $Message
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

    # Reviewer note: keep implementation simple; no pipeline binding; no use of $_ or $PSItem.
    $kept = New-Object 'System.Collections.Generic.List[string]'

    if ($null -ne $InputObject) {
        foreach ($item in $InputObject) {
            if ($null -eq $item) { continue }

            # Convert to string once; avoids implicit ToString() surprises later.
            $s = [string]$item
            if ('Trim' -eq $Normalization) {
                $s = $s.Trim()
            }

            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            [void]$kept.Add($s)
        }
    }

    # Optional minimal logging (Information/Error streams) when requested.
    if ('None' -ne $LogLevel) {
        $inputCount = if ($null -eq $InputObject) { 0 } else { $InputObject.Length }
        $retained   = $kept.Count
        $skipped    = $inputCount - $retained
        _Write-StandardMessage -Message ("Join-Text retained {0} item(s), skipped {1} null/empty/whitespace." -f $retained, $skipped) -Level $LogLevel
    }

    # Join with safe separator (treat null as empty).
    $sepToUse = if ($null -eq $Separator) { '' } else { $Separator }
    return [string]::Join($sepToUse, $kept.ToArray())
}


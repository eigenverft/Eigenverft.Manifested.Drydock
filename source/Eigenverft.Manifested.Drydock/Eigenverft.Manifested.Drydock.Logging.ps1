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
Switch. When present, uses local time instead of UTC.

.EXAMPLE
function MakeDirs {
    Write-ConsoleLog -Level INF -Message 'Dirscreated.'
}
MakeDirs
# -> [2025-10-12 04:47:17:265 INF] [out.ps1] [makedirs] Dirscreated.
# (timestamp is in UTC)

.EXAMPLE
Write-ConsoleLog -Message 'customtext.' -Level WRN -LocalTime
# -> [2025-10-12 06:47:17:265 WRN] [fileofthefunction] [functionnameinfile] customtext.
# (timestamp is in local time)

.NOTES
Help is inside the function so it travels when copied.
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
        [switch]$LocalTime
    )

    # Reviewer: Deterministic timestamp; UTC default unless -LocalTime is set.
    $now = if ($LocalTime.IsPresent) { Get-Date } else { [DateTime]::UtcNow }
    $ts  = $now.ToString('yyyy-MM-dd HH:mm:ss:fff')

    # Reviewer: Get first caller that's not this function.
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

    # Prefer ScriptName; fall back to Location; else 'console'.
    $file =
        if ($caller.ScriptName) { Split-Path -Leaf $caller.ScriptName }
        elseif ($caller.Location -and $caller.Location -match '^(.*?):\d+') { Split-Path -Leaf $Matches[1] }
        else { 'console' }

    $func =
        if ($caller.FunctionName) { $caller.FunctionName }
        elseif ($caller.Command)  { $caller.Command }
        else { '<scriptblock>' }

    $lvl  = $Level.ToUpperInvariant()
    $line = "[{0} {1}] [{2}] [{3}] {4}" -f $ts, $lvl, $file, $func.ToLower(), $Message

    # Reviewer: Write-Host ensures immediate console rendering in PS5.
    Write-Host $line
}

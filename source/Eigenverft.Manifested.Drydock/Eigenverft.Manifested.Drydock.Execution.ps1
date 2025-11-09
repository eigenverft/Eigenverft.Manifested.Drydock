function Invoke-Exec {
<#
.SYNOPSIS
Run an external executable with merged per-call and shared arguments, optional timing/output capture, strict exit-code validation, and configurable return shaping.

.DESCRIPTION
This function invokes an external process and enforces a clear separation between:
- Arguments        - Command-specific parameters (subcommands, positional paths, call-specific flags).
- CommonArguments  - Stable, shared parameters reused across many calls.

Combination order: Arguments first, then CommonArguments (keeps subcommands/positionals early; shared flags last).

Behavior
- If -CaptureOutput is true, returns the command's output; else streams to host and returns $null.
- If -MeasureTime is true, prints elapsed time.
- Exit code must be in AllowedExitCodes. If not:
  - If the code is 0 but 0 is disallowed, map to custom code 99; otherwise exit with the actual code.
- Diagnostics include a "Full Command" line and, on error, optional echo of captured output.

Return shaping (applies only when -CaptureOutput:$true)
- Objects : Preserve native objects (PowerShell may auto-collapse a single item).
- Strings : Force string[] (each item cast to [string]).
- Text    : Single string with all (stringified) lines joined by the platform newline. (Default)

Tip for single-value “true”/“false” outputs from a CLI:
- Use `-ReturnType Objects` to keep native typing and then coerce explicitly when needed, e.g.:
  `[bool]::Parse([string](Invoke-Exec2 ... -ReturnType Objects))`

.PARAMETER Executable
The program to run (path or name resolvable via PATH).

.PARAMETER Arguments
Per-invocation arguments (subcommands, positional paths, and flags unique to this call). Preserves order and precedes CommonArguments.

.PARAMETER CommonArguments
Reusable, environment- or pipeline-wide arguments appended after Arguments. Intended for consistency and DRY usage across calls.

.PARAMETER HideValues
String values to mask in diagnostic command displays. These do not affect actual execution. Any substring match in arguments is replaced with "[HIDDEN]" for display.

.PARAMETER MeasureTime
When true (default), measures and prints elapsed execution time.

.PARAMETER CaptureOutput
When true (default), captures and returns process output; when false, streams to the host and returns $null.

.PARAMETER CaptureOutputDump
When true and -CaptureOutput:$false, suppresses streaming and discards process output.

.PARAMETER AllowedExitCodes
Exit codes considered successful; defaults to @(0). If 0 is excluded and occurs, it is treated as an error and mapped to 99.

.PARAMETER ReturnType
Shapes the return value when output is captured (ignored if -CaptureOutput:$false).
Allowed: Objects | Strings | Text (default: Text)

.OUTPUTS
System.String            (when -CaptureOutput and -ReturnType Text)
System.String[]          (when -CaptureOutput and -ReturnType Strings)
System.Object[] or scalar (when -CaptureOutput and -ReturnType Objects; PowerShell may collapse single item)
System.Object            ($null when -CaptureOutput:$false)

.EXAMPLE
# Reuse shared flags; keep default shaping as a single text blob
$common = @("--verbosity","minimal","-c","Release")
$txt = Invoke-Exec -Executable "dotnet" -Arguments @("build","MyApp.csproj") -CommonArguments $common -ReturnType Text

.EXAMPLE
# Capture a single boolean-like value robustly
$raw = Invoke-Exec -Executable "cmd" -Arguments @("/c","echo","True") -ReturnType Objects
$ok  = [bool]::Parse([string]$raw)   # $ok = $true

.EXAMPLE
# Mask a password sourced from a CI pipeline environment variable (e.g., Azure DevOps, GitHub Actions)
# The real value is used for execution, but the displayed command is scrubbed.

$pwd = $env:TOOL_PASSWORD  # Provided by the pipeline as a secret env var
Invoke-Exec -Executable "tool" -Arguments @("--password=$pwd") -HideValues @($pwd)
# Displays: ==> Full Command: tool --password=[HIDDEN]

.EXAMPLE
# Variant: CLI expects the value as a separate argument (no inline '=' form)
$pwd = $env:TOOL_PASSWORD
Invoke-Exec -Executable "tool" -Arguments @("--password", $pwd) -HideValues @($pwd)
# Displays: ==> Full Command: tool --password [HIDDEN]

.EXAMPLE
# Variant: multiple sensitive tokens (e.g., token + url with embedded token)
$token = $env:API_TOKEN
$url   = "https://api.example.com?access_token=$token"
Invoke-Exec -Executable "curl" -Arguments @("-H", "Authorization: Bearer $token", $url) -HideValues @($token)
# Displays: ==> Full Command: curl -H Authorization: Bearer [HIDDEN] https://api.example.com?access_token=[HIDDEN]
#>
    [CmdletBinding()]
    [Alias('iexec')]
    param(
        [Alias('exe')]
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Alias('args')]
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Alias('argsc')]
        [Parameter(Mandatory = $false)]
        [string[]]$CommonArguments,

        [Alias('hide','mask','hidevalue','maskval')]
        [Parameter(Mandatory = $false)]
        [string[]]$HideValues = @(),

        [Alias('mt')]
        [bool]$MeasureTime = $true,

        [Alias('co')]
        [bool]$CaptureOutput = $true,

        [Alias('cod')]
        [bool]$CaptureOutputDump = $false,

        [Alias('ok')]
        [int[]]$AllowedExitCodes = @(0),

        [Alias('rt')]
        [ValidateSet('Objects','Strings','Text')]
        [string]$ReturnType = 'Text'
    )

    # Internal fixed values for custom error handling
    $ExtraErrorMessage = "Disallowed exit code 0 exitcode encountered."
    $CustomErrorCode   = 99

    # Combine CommonArguments and Arguments (handle null or empty)
    $finalArgs = @()
    if ($Arguments -and $Arguments.Count -gt 0) { $finalArgs += $Arguments }
    if ($CommonArguments -and $CommonArguments.Count -gt 0) { $finalArgs += $CommonArguments }

    # Build display-only args with masking (execution still uses $finalArgs)
    $displayArgs = @($finalArgs)
    if ($HideValues -and $HideValues.Count -gt 0) {
        foreach ($h in $HideValues) {
            if ([string]::IsNullOrWhiteSpace($h)) { continue }
            $pattern = [regex]::Escape($h)
            $displayArgs = $displayArgs | ForEach-Object { $_ -replace $pattern, '[HIDDEN]' }
        }
    }

    Write-Host "===> Before Command (Executable: $Executable, Args Count: $($finalArgs.Count)) ==============================================" -ForegroundColor Yellow
    Write-Host "===> Full Command: $Executable $($displayArgs -join ' ')" -ForegroundColor Cyan

    if ($MeasureTime) { $stopwatch = [System.Diagnostics.Stopwatch]::StartNew() }

    if ($CaptureOutput) {
        $result = & $Executable @finalArgs
    } else {
        if ($CaptureOutputDump) {
            & $Executable @finalArgs | Out-Null
        } else {
            & $Executable @finalArgs
        }
        $result = $null
    }

    if ($MeasureTime) { $stopwatch.Stop() }

    # Check if the actual exit code is allowed.
    if (-not ($AllowedExitCodes -contains $LASTEXITCODE)) {
        if ($CaptureOutput -and $result) {
            Write-Host "===> Captured Output:" -ForegroundColor Yellow
            $result | ForEach-Object { Write-Host $_ -ForegroundColor Gray }
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Error "Command '$Executable $($displayArgs -join ' ')' returned exit code 0, which is disallowed. $ExtraErrorMessage Translated to custom error code $CustomErrorCode."
            if ($MeasureTime) {
                Write-Host "===> After Command (Execution time: $($stopwatch.Elapsed)) ==============================================" -ForegroundColor DarkGreen
            } else {
                Write-Host "===> After Command ==============================================" -ForegroundColor DarkGreen
            }
            exit $CustomErrorCode
        } else {
            Write-Error "Command '$Executable $($displayArgs -join ' ')' returned disallowed exit code $LASTEXITCODE. Exiting script with exit code $LASTEXITCODE."
            if ($MeasureTime) {
                Write-Host "===> After Command (Execution time: $($stopwatch.Elapsed)) ==============================================" -ForegroundColor DarkGreen
            } else {
                Write-Host "===> After Command ==============================================" -ForegroundColor DarkGreen
            }
            exit $LASTEXITCODE
        }
    }

    if ($MeasureTime) {
        Write-Host "===> After Command (Execution time: $($stopwatch.Elapsed)) ==============================================" -ForegroundColor DarkGreen
    } else {
        Write-Host "===> After Command ==============================================" -ForegroundColor DarkGreen
    }

    # Return shaping
    if (-not $CaptureOutput) { return $null }
    switch ($ReturnType.ToLowerInvariant()) {
        'objects' {
            if ($null -eq $result) { return @() }
            return @($result)
        }
        'strings' {
            if ($null -eq $result) { return @() }
            return @($result | ForEach-Object { [string]$_ })
        }
        'text' {
            if ($null -eq $result) { return '' }
            $lines = $result | ForEach-Object { [string]$_ }
            return ($lines -join [Environment]::NewLine)
        }
    }
}


function Invoke-ProcessTyped {
<#
.SYNOPSIS
Executes an external command with merged specific and shared arguments, optional output capture, timing, exit-code validation, and controlled return shaping.

.DESCRIPTION
Invoke-ProcessTyped standardizes external command execution across platforms.

Behavior:
- Arguments are combined as: Arguments first, then CommonArguments.
- Validates that the specified executable exists; fails fast with a clear error when missing.
- Supports masking sensitive values in the displayed command line (does not affect real execution).
- Supports optional execution time measurement.
- Exit code must be in AllowedExitCodes; otherwise:
  - If the exit code is 0 but 0 is not allowed, it is translated to CustomErrorCode (default 99).
  - For any other disallowed code, the function terminates with that exit code.
- When CaptureOutput is:
  - $true  : Captures stdout and stderr and shapes according to ReturnType.
  - $false : Streams directly or is discarded when CaptureOutputDump is $true.

ReturnType (only when CaptureOutput is $true):
- Objects : Returns all output items as a single array (stdout + stderr), converted to base types where possible.
- Strings : Returns all output as a single string[].
- Text    : Returns a single string with joined lines (default).

.PARAMETER Executable
Name or path of the executable to invoke. Must resolve via PATH or be a valid path.

.PARAMETER Arguments
Command-specific arguments for this invocation (subcommands, positionals, flags).

.PARAMETER CommonArguments
Shared, reusable arguments appended after Arguments.

.PARAMETER HideValues
One or more sensitive substrings to mask in the displayed command line.

.PARAMETER MeasureTime
When $true, measures and logs elapsed execution time. Default: $true.

.PARAMETER CaptureOutput
When $true, captures and returns process output. When $false, streams to host or is discarded. Default: $true.

.PARAMETER CaptureOutputDump
When $true and CaptureOutput is $false, discards all process output (stdout + stderr). Default: $false.

.PARAMETER AllowedExitCodes
List of exit codes treated as success. Default: 0. If 0 occurs but is not in the list, it is mapped to CustomErrorCode.

.PARAMETER ReturnType
Controls shape of captured output. Allowed: Objects, Strings, Text. Default: Text.
#>
    [CmdletBinding()]
    [Alias('ipt')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [string[]]$CommonArguments,

        [Alias('hide','mask','hidevalue','maskval')]
        [Parameter(Mandatory = $false)]
        [string[]]$HideValues,

        [Parameter(Mandatory = $false)]
        [bool]$MeasureTime = $true,

        [Parameter(Mandatory = $false)]
        [bool]$CaptureOutput = $true,

        [Parameter(Mandatory = $false)]
        [bool]$CaptureOutputDump = $false,

        [Parameter(Mandatory = $false)]
        [int[]]$AllowedExitCodes = @(0),

        [Parameter(Mandatory = $false)]
        [ValidateSet('Objects','Strings','Text')]
        [string]$ReturnType = 'Text'
    )

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
            }
            else {
                $MinLevel = 'INF'
            }
        }

        $sevMap = @{
            TRC = 0
            DBG = 1
            INF = 2
            WRN = 3
            ERR = 4
            FTL = 5
        }

        $lvl = $Level.ToUpperInvariant()
        $min = $MinLevel.ToUpperInvariant()

        $sev  = $sevMap[$lvl]
        $gate = $sevMap[$min]

        if ($null -eq $sev) {
            $sev = $sevMap['INF']
            $lvl = 'INF'
        }
        if ($null -eq $gate) {
            $gate = $sevMap['INF']
            $min = 'INF'
        }

        if ($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4) {
            $lvl = $min
            $sev = $gate
        }

        if ($sev -lt $gate) {
            return
        }

        $ts = ([DateTime]::UtcNow).ToString('yyyy-MM-dd HH:mm:ss:fff')

        $stack      = Get-PSCallStack
        $helperName = $MyInvocation.MyCommand.Name
        $orgFunc    = $null
        $caller     = $null

        if ($null -ne $stack -and $stack.Count -gt 0) {
            $orgIdx = -1
            for ($i = 0; $i -lt $stack.Count; $i++) {
                if ($stack[$i].FunctionName -ne $helperName) {
                    $orgFunc = $stack[$i]
                    $orgIdx  = $i
                    break
                }
            }

            if ($orgIdx -ge 0) {
                $callerIdx = $orgIdx + 1
                if ($stack.Count -gt $callerIdx) {
                    $caller = $stack[$callerIdx]
                }
                else {
                    $caller = $orgFunc
                }
            }
        }

        if ($null -eq $caller) {
            $caller = [pscustomobject]@{
                ScriptName   = $PSCommandPath
                FunctionName = '<ScriptBlock>'
            }
        }

        $file = 'console'
        if ($caller.PSObject.Properties.Match('ScriptName').Count -gt 0) {
            $scriptNameValue = $caller.ScriptName
            if ($null -ne $scriptNameValue -and $scriptNameValue -ne '') {
                $file = Split-Path -Leaf $scriptNameValue
            }
        }

        $func = '<ScriptBlock>'
        if ($caller.PSObject.Properties.Match('FunctionName').Count -gt 0) {
            $fn = $caller.FunctionName
            if ($null -ne $fn -and $fn -ne '') {
                $func = $fn
            }
        }

        $lineNumber = ''

        $lineProp = $caller.PSObject.Properties.Match('ScriptLineNumber')
        if ($lineProp.Count -gt 0 -and $null -ne $lineProp[0].Value) {
            $lineNumber = [string]$lineProp[0].Value
        }

        if ([string]::IsNullOrEmpty($lineNumber)) {
            $posProp = $caller.PSObject.Properties.Match('Position')
            if ($posProp.Count -gt 0 -and $null -ne $posProp[0].Value) {
                $position = $posProp[0].Value
                if ($null -ne $position) {
                    $startLineProp = $position.PSObject.Properties.Match('StartLineNumber')
                    if ($startLineProp.Count -gt 0 -and $null -ne $startLineProp[0].Value) {
                        $lineNumber = [string]$startLineProp[0].Value
                    }
                }
            }
        }

        if ([string]::IsNullOrEmpty($lineNumber)) {
            $locProp = $caller.PSObject.Properties.Match('Location')
            if ($locProp.Count -gt 0 -and $null -ne $locProp[0].Value) {
                $locText = [string]$locProp[0].Value
                if ($locText -ne '') {
                    $match = [regex]::Match($locText, '[:](\d+)\s+char[:]', 'IgnoreCase')
                    if ($match.Success -and $match.Groups.Count -gt 1) {
                        $lineNumber = $match.Groups[1].Value
                    }
                }
            }
        }

        $fileSegment = $file
        if (-not [string]::IsNullOrEmpty($lineNumber)) {
            $fileSegment = '{0}:{1}' -f $file, $lineNumber
        }

        $line = '[{0} {1}] [{2}] [{3}] {4}' -f $ts, $lvl, $fileSegment, $func, $Message

        if ($sev -ge 4) {
            if ($ErrorActionPreference -eq 'Stop') {
                Write-Error -Message $line -ErrorId ("ConsoleLog.{0}" -f $lvl) -Category NotSpecified -ErrorAction Stop
            }
            else {
                Write-Error -Message $line -ErrorId ("ConsoleLog.{0}" -f $lvl) -Category NotSpecified
            }
        }
        else {
            Write-Information -MessageData $line -InformationAction Continue
        }
    }

    function _InvokeExecBuildArgs {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string[]]$Primary,
            [string[]]$Shared
        )

        $combined = @()
        if ($null -ne $Primary -and $Primary.Count -gt 0) {
            $combined += $Primary
        }
        if ($null -ne $Shared -and $Shared.Count -gt 0) {
            $combined += $Shared
        }
        return ,@($combined)
    }

    function _InvokeExecMaskArgs {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string[]]$ArgsToMask,
            [string[]]$SensitiveValues
        )

        if ($null -eq $ArgsToMask -or $ArgsToMask.Count -gt 0 -eq $false) {
            return ,@()
        }

        $current = @($ArgsToMask)

        if ($null -ne $SensitiveValues -and $SensitiveValues.Count -gt 0) {
            foreach ($sensitive in $SensitiveValues) {
                if ($null -eq $sensitive) { continue }

                $sensitiveText = [string]$sensitive
                if ([string]::IsNullOrWhiteSpace($sensitiveText)) { continue }

                $pattern = [regex]::Escape($sensitiveText)
                $next = @()

                foreach ($argValue in $current) {
                    if ($null -eq $argValue) {
                        $next += $argValue
                    }
                    else {
                        $next += ($argValue -replace $pattern, '[HIDDEN]')
                    }
                }

                $current = $next
            }
        }

        return ,@($current)
    }

    function _InvokeExecBuildArgumentString {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string[]]$Arguments
        )

        if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
            return ''
        }

        $sb = New-Object System.Text.StringBuilder
        $specialChars = @(
            [char]' ',
            [char]"`t",
            [char]"`r",
            [char]"`n",
            [char]'"'
        )

        foreach ($argument in $Arguments) {
            if ($null -eq $argument) { continue }

            if ($sb.Length -gt 0) {
                [void]$sb.Append(' ')
            }

            $s = [string]$argument

            if ($s.Length -eq 0) {
                [void]$sb.Append('""')
                continue
            }

            if ($s.IndexOfAny($specialChars) -ge 0) {
                $escaped = $s.Replace('"', '\"')
                [void]$sb.Append('"')
                [void]$sb.Append($escaped)
                [void]$sb.Append('"')
            }
            else {
                [void]$sb.Append($s)
            }
        }

        return $sb.ToString()
    }

    function _InvokeExecConvertFromString {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$InputObject,

            [Parameter()]
            [switch]$TreatEmptyAsNull
        )

        if ($null -eq $InputObject) {
            return $null
        }

        if ($InputObject -isnot [string]) {
            return $InputObject
        }

        $cultureEnUs   = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
        $integerStyles = [System.Globalization.NumberStyles]::Integer
        $floatStyles   = [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands
        $dateStyles    = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
        $nullLiterals  = @('null','<null>','none','n/a')

        $raw  = $InputObject
        $text = $raw.Trim()

        if ($text.Length -eq 0) {
            if ($TreatEmptyAsNull) { return $null }
            return $raw
        }

        $lower = $text.ToLowerInvariant()

        # 1) Null-like
        if ($nullLiterals -contains $lower) {
            return $null
        }

        # 2) Boolean
        $boolResult = $false
        if ([bool]::TryParse($text, [ref]$boolResult)) {
            return $boolResult
        }

        # 3) JSON (only clearly structured)
        if (
            ($text.StartsWith('{') -and $text.EndsWith('}')) -or
            ($text.StartsWith('[') -and $text.EndsWith(']'))
        ) {
            try {
                $json = $text | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $json) {
                    return $json
                }
            }
            catch { }
        }

        # 4) Guid
        $guidResult = [guid]::Empty
        if ([guid]::TryParse($text, [ref]$guidResult)) {
            return $guidResult
        }

        # 5) Int32
        $int32Result = 0
        if ([int]::TryParse($text, $integerStyles, $cultureEnUs, [ref]$int32Result)) {
            return $int32Result
        }

        # 6) Int64
        $int64Result = 0L
        if ([long]::TryParse($text, $integerStyles, $cultureEnUs, [ref]$int64Result)) {
            return $int64Result
        }

        # 7) BigInteger
        if ($text -match '^[\+\-]?\d+$') {
            try {
                $bigInt = [System.Numerics.BigInteger]::Parse($text, $cultureEnUs)
                return $bigInt
            }
            catch { }
        }

        # 8) Floating specials
        switch ($lower) {
            'nan'        { return [double]::NaN }
            'infinity'   { return [double]::PositiveInfinity }
            '+infinity'  { return [double]::PositiveInfinity }
            '-infinity'  { return [double]::NegativeInfinity }
        }

        # 9) Decimal (fixed-point)
        if ($text -match '^[\+\-]?\d+(\.\d+)?$') {
            $decimalResult = 0m
            if ([decimal]::TryParse($text, $floatStyles, $cultureEnUs, [ref]$decimalResult)) {
                return $decimalResult
            }
        }

        # 10) Double
        $doubleResult = 0.0
        if ([double]::TryParse($text, $floatStyles, $cultureEnUs, [ref]$doubleResult)) {
            return $doubleResult
        }

        # 11) DateTime (en-US)
        $dateResult = [datetime]::MinValue
        if ([datetime]::TryParse($text, $cultureEnUs, $dateStyles, [ref]$dateResult)) {
            return $dateResult
        }

        # 12) DateTime (ISO / roundtrip)
        $dateIsoResult = [datetime]::MinValue
        if ([datetime]::TryParse(
                $text,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$dateIsoResult
            )) {
            return $dateIsoResult
        }

        # 13) TimeSpan
        $timeSpanResult = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse($text, $cultureEnUs, [ref]$timeSpanResult)) {
            return $timeSpanResult
        }

        # 14) Version (only if nothing else matched)
        if ($text -match '^\d+(\.\d+){1,3}$') {
            try {
                $ver = New-Object System.Version($text)
                return $ver
            }
            catch { }
        }

        return $raw
    }

    $extraErrorMessage = 'Disallowed exit code 0 exitcode encountered.'
    $customErrorCode   = 99

    if ($null -eq $HideValues) {
        $HideValues = @()
    }

    $resolvedExecutable = Get-Command -Name $Executable -ErrorAction SilentlyContinue
    if ($null -eq $resolvedExecutable) {
        _Write-StandardMessage -Message "Executable '$Executable' was not found. Install it, add it to PATH, or specify a valid full path." -Level ERR
        return $null
    }

    $resolvedName = $resolvedExecutable.Name
    $resolvedPath = $Executable

    $hasPath = $resolvedExecutable.PSObject.Properties.Match('Path').Count -gt 0
    if ($hasPath -and -not [string]::IsNullOrEmpty([string]$resolvedExecutable.Path)) {
        $resolvedPath = [string]$resolvedExecutable.Path
    }
    else {
        $hasDef = $resolvedExecutable.PSObject.Properties.Match('Definition').Count -gt 0
        if ($hasDef -and -not [string]::IsNullOrEmpty([string]$resolvedExecutable.Definition)) {
            $resolvedPath = [string]$resolvedExecutable.Definition
        }
    }

    $finalArgs          = _InvokeExecBuildArgs -Primary $Arguments -Shared $CommonArguments
    $displayArgs        = _InvokeExecMaskArgs -ArgsToMask $finalArgs -SensitiveValues $HideValues
    $normalizedReturnType = $ReturnType.ToLowerInvariant()

    _Write-StandardMessage -Message ("Before Command : (Executable: {0}, Args Count: {1})" -f $resolvedName, $finalArgs.Count) -Level DBG
    _Write-StandardMessage -Message ("Full Command   : {0} {1}" -f $resolvedName, ($displayArgs -join ' ')) -Level INF

    $stopwatch = $null
    if ($MeasureTime) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $resolvedPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    $supportsArgumentList = $psi.PSObject.Properties.Match('ArgumentList').Count -gt 0
    if ($supportsArgumentList) {
        foreach ($argument in $finalArgs) {
            if ($null -ne $argument) {
                [void]$psi.ArgumentList.Add([string]$argument)
            }
        }
    }
    else {
        $psi.Arguments = _InvokeExecBuildArgumentString -Args $finalArgs
    }

    if ($CaptureOutput -or $CaptureOutputDump) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
    }
    else {
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError  = $false
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        if ($MeasureTime -and $null -ne $stopwatch) {
            $stopwatch.Stop()
        }
        _Write-StandardMessage -Message ("Failed to start process '{0}'." -f $resolvedName) -Level ERR
        return $null
    }

    $collected = New-Object 'System.Collections.Generic.List[object]'

    if ($CaptureOutput) {
        # Read both stdout and stderr until process exits and streams are drained.
        while (-not $process.HasExited -or -not $process.StandardOutput.EndOfStream -or -not $process.StandardError.EndOfStream) {
            if (-not $process.StandardOutput.EndOfStream) {
                $line = $process.StandardOutput.ReadLine()
                if ($null -ne $line) {
                    if ($normalizedReturnType -eq 'objects') {
                        $typed = _InvokeExecConvertFromString -InputObject $line
                        [void]$collected.Add($typed)
                    }
                    else {
                        [void]$collected.Add($line)
                    }
                }
            }

            if (-not $process.StandardError.EndOfStream) {
                $line = $process.StandardError.ReadLine()
                if ($null -ne $line) {
                    if ($normalizedReturnType -eq 'objects') {
                        $typed = _InvokeExecConvertFromString -InputObject $line
                        [void]$collected.Add($typed)
                    }
                    else {
                        [void]$collected.Add($line)
                    }
                }
            }
        }
    }
    elseif ($CaptureOutputDump) {
        while (-not $process.HasExited -or -not $process.StandardOutput.EndOfStream -or -not $process.StandardError.EndOfStream) {
            if (-not $process.StandardOutput.EndOfStream) {
                $null = $process.StandardOutput.ReadLine()
            }
            if (-not $process.StandardError.EndOfStream) {
                $null = $process.StandardError.ReadLine()
            }
        }
    }

    if (-not ($process.HasExited))
    {
        $process.WaitForExit()
    }

    if ($MeasureTime -and $null -ne $stopwatch) {
        $stopwatch.Stop()
    }

    $exitCode = $process.ExitCode
    $Global:LASTEXITCODE = $exitCode
    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    $result = $null
    if ($CaptureOutput) {
        $result = $collected.ToArray()
    }

    $isAllowed = $false
    if ($null -ne $AllowedExitCodes -and $AllowedExitCodes.Count -gt 0) {
        if ($AllowedExitCodes -contains $exitCode) {
            $isAllowed = $true
        }
    }

    if (-not $isAllowed) {
        if ($CaptureOutput -and $null -ne $result) {
            _Write-StandardMessage -Message 'Captured Output (non-success exit code):' -Level WRN
            foreach ($line in $result) {
                _Write-StandardMessage -Message ([string]$line) -Level INF
            }
        }

        $elapsedSuffix = ''
        if ($MeasureTime -and $null -ne $stopwatch) {
            $elapsedSuffix = " (Execution time: $($stopwatch.Elapsed))"
        }

        if ($exitCode -eq 0) {
            $errorMessage = ("Command '{0} {1}' returned exit code 0, which is disallowed. {2} Translated to custom error code {3}." -f $resolvedName, ($displayArgs -join ' '), $extraErrorMessage, $customErrorCode)
            _Write-StandardMessage -Message ($errorMessage + $elapsedSuffix) -Level ERR
            exit $customErrorCode
        }
        else {
            $errorMessage = ("Command '{0} {1}' returned disallowed exit code {2}. Exiting script with exit code {2}." -f $resolvedName, ($displayArgs -join ' '), $exitCode)
            _Write-StandardMessage -Message ($errorMessage + $elapsedSuffix) -Level ERR
            exit $exitCode
        }
    }

    $afterMessage = 'After Command'
    if ($MeasureTime -and $null -ne $stopwatch) {
        $afterMessage = "After Command  : (Execution time: $($stopwatch.Elapsed))"
    }
    _Write-StandardMessage -Message $afterMessage -Level DBG

    if (-not $CaptureOutput) {
        return $null
    }

    switch ($normalizedReturnType) {
        'objects' {
            if ($null -eq $result) { return @() }
            return @($result)
        }
        'strings' {
            if ($null -eq $result) { return ,@() }
            $stringItems = @()
            foreach ($item in $result) {
                if ($null -eq $item) {
                    $stringItems += ''
                }
                else {
                    $stringItems += [string]$item
                }
            }
            return ,@($stringItems)
        }
        default {
            if ($null -eq $result) { return '' }
            $lines = @()
            foreach ($rawLine in $result) {
                if ($null -eq $rawLine) {
                    $lines += ''
                }
                else {
                    $lines += [string]$rawLine
                }
            }
            return ($lines -join [Environment]::NewLine)
        }
    }
}

#with credential needs review testing
function Invoke-ProcessTyped2 {
<#
.SYNOPSIS
Executes an external command with merged specific and shared arguments, optional output capture, timing, exit-code validation, controlled return shaping, and optional alternate credentials.

.DESCRIPTION
Invoke-ProcessTyped standardizes external command execution across platforms.

Behavior:
- Arguments are combined as: Arguments first, then CommonArguments.
- Validates that the specified executable exists; fails fast with a clear error when missing.
- Supports masking sensitive values in the displayed command line (does not affect real execution).
- Supports optional execution time measurement.
- Supports optional alternate credentials on Windows (when -Credential is supplied).
- Exit code must be in AllowedExitCodes; otherwise:
  - If the exit code is 0 but 0 is not allowed, it is translated to CustomErrorCode (default 99).
  - For any other disallowed code, the function terminates with that exit code.
- When CaptureOutput is:
  - $true  : Captures stdout and stderr and shapes according to ReturnType.
  - $false : Streams directly or is discarded when CaptureOutputDump is $true.

ReturnType (only when CaptureOutput is $true):
- Objects : Returns all output items as a single array (stdout + stderr), converted to base types where possible.
- Strings : Returns all output as a single string[].
- Text    : Returns a single string with joined lines (default).

.PARAMETER Executable
Name or path of the executable to invoke. Must resolve via PATH or be a valid path.

.PARAMETER Arguments
Command-specific arguments for this invocation (subcommands, positionals, flags).

.PARAMETER CommonArguments
Shared, reusable arguments appended after Arguments.

.PARAMETER HideValues
One or more sensitive substrings to mask in the displayed command line.

.PARAMETER MeasureTime
When $true, measures and logs elapsed execution time. Default: $true.

.PARAMETER CaptureOutput
When $true, captures and returns process output. When $false, streams to host or is discarded. Default: $true.

.PARAMETER CaptureOutputDump
When $true and CaptureOutput is $false, discards all process output (stdout + stderr). Default: $false.

.PARAMETER AllowedExitCodes
List of exit codes treated as success. Default: 0. If 0 occurs but is not in the list, it is mapped to CustomErrorCode.

.PARAMETER ReturnType
Controls shape of captured output. Allowed: Objects, Strings, Text. Default: Text.

.PARAMETER Credential
Optional Windows-only credential under which to start the process.
Requires UseShellExecute = $false (already enforced) and is ignored on non-Windows (with an error).
#>
    [CmdletBinding()]
    [Alias('iexec2')]
    param(
        [Alias('exe')]
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Executable,

        [Alias('cmd')]
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [string[]]$Arguments,

        [Alias('shared')]
        [Parameter(Mandatory = $false)]
        [string[]]$CommonArguments,

        [Alias('hide','mask','hidevalue','maskval')]
        [Parameter(Mandatory = $false)]
        [string[]]$HideValues,

        [Alias('mt')]
        [Parameter(Mandatory = $false)]
        [bool]$MeasureTime = $true,

        [Alias('co')]
        [Parameter(Mandatory = $false)]
        [bool]$CaptureOutput = $true,

        [Alias('cod')]
        [Parameter(Mandatory = $false)]
        [bool]$CaptureOutputDump = $false,

        [Alias('ok')]
        [Parameter(Mandatory = $false)]
        [int[]]$AllowedExitCodes = @(0),

        [Alias('rt')]
        [Parameter(Mandatory = $false)]
        [ValidateSet('Objects','Strings','Text')]
        [string]$ReturnType = 'Text',

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

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
            }
            else {
                $MinLevel = 'INF'
            }
        }

        $sevMap = @{
            TRC = 0
            DBG = 1
            INF = 2
            WRN = 3
            ERR = 4
            FTL = 5
        }

        $lvl = $Level.ToUpperInvariant()
        $min = $MinLevel.ToUpperInvariant()

        $sev  = $sevMap[$lvl]
        $gate = $sevMap[$min]

        if ($null -eq $sev) {
            $sev = $sevMap['INF']
            $lvl = 'INF'
        }
        if ($null -eq $gate) {
            $gate = $sevMap['INF']
            $min = 'INF'
        }

        if ($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4) {
            $lvl = $min
            $sev = $gate
        }

        if ($sev -lt $gate) {
            return
        }

        $ts = ([DateTime]::UtcNow).ToString('yyyy-MM-dd HH:mm:ss:fff')

        $stack      = Get-PSCallStack
        $helperName = $MyInvocation.MyCommand.Name
        $orgFunc    = $null
        $caller     = $null

        if ($null -ne $stack -and $stack.Count -gt 0) {
            $orgIdx = -1
            for ($i = 0; $i -lt $stack.Count; $i++) {
                if ($stack[$i].FunctionName -ne $helperName) {
                    $orgFunc = $stack[$i]
                    $orgIdx  = $i
                    break
                }
            }

            if ($orgIdx -ge 0) {
                $callerIdx = $orgIdx + 1
                if ($stack.Count -gt $callerIdx) {
                    $caller = $stack[$callerIdx]
                }
                else {
                    $caller = $orgFunc
                }
            }
        }

        if ($null -eq $caller) {
            $caller = [pscustomobject]@{
                ScriptName   = $PSCommandPath
                FunctionName = '<ScriptBlock>'
            }
        }

        $file = 'console'
        if ($caller.PSObject.Properties.Match('ScriptName').Count -gt 0) {
            $scriptNameValue = $caller.ScriptName
            if ($null -ne $scriptNameValue -and $scriptNameValue -ne '') {
                $file = Split-Path -Leaf $scriptNameValue
            }
        }

        $func = '<ScriptBlock>'
        if ($caller.PSObject.Properties.Match('FunctionName').Count -gt 0) {
            $fn = $caller.FunctionName
            if ($null -ne $fn -and $fn -ne '') {
                $func = $fn
            }
        }

        $lineNumber = ''

        $lineProp = $caller.PSObject.Properties.Match('ScriptLineNumber')
        if ($lineProp.Count -gt 0 -and $null -ne $lineProp[0].Value) {
            $lineNumber = [string]$lineProp[0].Value
        }

        if ([string]::IsNullOrEmpty($lineNumber)) {
            $posProp = $caller.PSObject.Properties.Match('Position')
            if ($posProp.Count -gt 0 -and $null -ne $posProp[0].Value) {
                $position = $posProp[0].Value
                if ($null -ne $position) {
                    $startLineProp = $position.PSObject.Properties.Match('StartLineNumber')
                    if ($startLineProp.Count -gt 0 -and $null -ne $startLineProp[0].Value) {
                        $lineNumber = [string]$startLineProp[0].Value
                    }
                }
            }
        }

        if ([string]::IsNullOrEmpty($lineNumber)) {
            $locProp = $caller.PSObject.Properties.Match('Location')
            if ($locProp.Count -gt 0 -and $null -ne $locProp[0].Value) {
                $locText = [string]$locProp[0].Value
                if ($locText -ne '') {
                    $match = [regex]::Match($locText, '[:](\d+)\s+char[:]', 'IgnoreCase')
                    if ($match.Success -and $match.Groups.Count -gt 1) {
                        $lineNumber = $match.Groups[1].Value
                    }
                }
            }
        }

        $fileSegment = $file
        if (-not [string]::IsNullOrEmpty($lineNumber)) {
            $fileSegment = '{0}:{1}' -f $file, $lineNumber
        }

        $line = '[{0} {1}] [{2}] [{3}] {4}' -f $ts, $lvl, $fileSegment, $func, $Message

        if ($sev -ge 4) {
            if ($ErrorActionPreference -eq 'Stop') {
                Write-Error -Message $line -ErrorId ("ConsoleLog.{0}" -f $lvl) -Category NotSpecified -ErrorAction Stop
            }
            else {
                Write-Error -Message $line -ErrorId ("ConsoleLog.{0}" -f $lvl) -Category NotSpecified
            }
        }
        else {
            Write-Information -MessageData $line -InformationAction Continue
        }
    }

    function _InvokeExecBuildArgs {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string[]]$Primary,
            [string[]]$Shared
        )

        $combined = @()
        if ($null -ne $Primary -and $Primary.Count -gt 0) {
            $combined += $Primary
        }
        if ($null -ne $Shared -and $Shared.Count -gt 0) {
            $combined += $Shared
        }
        return ,@($combined)
    }

    function _InvokeExecMaskArgs {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string[]]$ArgsToMask,
            [string[]]$SensitiveValues
        )

        if ($null -eq $ArgsToMask -or $ArgsToMask.Count -gt 0 -eq $false) {
            return ,@()
        }

        $current = @($ArgsToMask)

        if ($null -ne $SensitiveValues -and $SensitiveValues.Count -gt 0) {
            foreach ($sensitive in $SensitiveValues) {
                if ($null -eq $sensitive) { continue }

                $sensitiveText = [string]$sensitive
                if ([string]::IsNullOrWhiteSpace($sensitiveText)) { continue }

                $pattern = [regex]::Escape($sensitiveText)
                $next = @()

                foreach ($argValue in $current) {
                    if ($null -eq $argValue) {
                        $next += $argValue
                    }
                    else {
                        $next += ($argValue -replace $pattern, '[HIDDEN]')
                    }
                }

                $current = $next
            }
        }

        return ,@($current)
    }

    function _InvokeExecBuildArgumentString {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string[]]$Arguments
        )

        if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
            return ''
        }

        $sb = New-Object System.Text.StringBuilder
        $specialChars = @(
            [char]' ',
            [char]"`t",
            [char]"`r",
            [char]"`n",
            [char]'"'
        )

        foreach ($argument in $Arguments) {
            if ($null -eq $argument) { continue }

            if ($sb.Length -gt 0) {
                [void]$sb.Append(' ')
            }

            $s = [string]$argument

            if ($s.Length -eq 0) {
                [void]$sb.Append('""')
                continue
            }

            if ($s.IndexOfAny($specialChars) -ge 0) {
                $escaped = $s.Replace('"', '\"')
                [void]$sb.Append('"')
                [void]$sb.Append($escaped)
                [void]$sb.Append('"')
            }
            else {
                [void]$sb.Append($s)
            }
        }

        return $sb.ToString()
    }

    function _InvokeExecConvertFromString {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$InputObject,

            [Parameter()]
            [switch]$TreatEmptyAsNull
        )

        if ($null -eq $InputObject) {
            return $null
        }

        if ($InputObject -isnot [string]) {
            return $InputObject
        }

        $cultureEnUs   = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
        $integerStyles = [System.Globalization.NumberStyles]::Integer
        $floatStyles   = [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands
        $dateStyles    = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
        $nullLiterals  = @('null','<null>','none','n/a')

        $raw  = $InputObject
        $text = $raw.Trim()

        if ($text.Length -eq 0) {
            if ($TreatEmptyAsNull) { return $null }
            return $raw
        }

        $lower = $text.ToLowerInvariant()

        if ($nullLiterals -contains $lower) {
            return $null
        }

        $boolResult = $false
        if ([bool]::TryParse($text, [ref]$boolResult)) {
            return $boolResult
        }

        if (
            ($text.StartsWith('{') -and $text.EndsWith('}')) -or
            ($text.StartsWith('[') -and $text.EndsWith(']'))
        ) {
            try {
                $json = $text | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $json) {
                    return $json
                }
            }
            catch { }
        }

        $guidResult = [guid]::Empty
        if ([guid]::TryParse($text, [ref]$guidResult)) {
            return $guidResult
        }

        $int32Result = 0
        if ([int]::TryParse($text, $integerStyles, $cultureEnUs, [ref]$int32Result)) {
            return $int32Result
        }

        $int64Result = 0L
        if ([long]::TryParse($text, $integerStyles, $cultureEnUs, [ref]$int64Result)) {
            return $int64Result
        }

        if ($text -match '^[\+\-]?\d+$') {
            try {
                $bigInt = [System.Numerics.BigInteger]::Parse($text, $cultureEnUs)
                return $bigInt
            }
            catch { }
        }

        switch ($lower) {
            'nan'        { return [double]::NaN }
            'infinity'   { return [double]::PositiveInfinity }
            '+infinity'  { return [double]::PositiveInfinity }
            '-infinity'  { return [double]::NegativeInfinity }
        }

        if ($text -match '^[\+\-]?\d+(\.\d+)?$') {
            $decimalResult = 0m
            if ([decimal]::TryParse($text, $floatStyles, $cultureEnUs, [ref]$decimalResult)) {
                return $decimalResult
            }
        }

        $doubleResult = 0.0
        if ([double]::TryParse($text, $floatStyles, $cultureEnUs, [ref]$doubleResult)) {
            return $doubleResult
        }

        $dateResult = [datetime]::MinValue
        if ([datetime]::TryParse($text, $cultureEnUs, $dateStyles, [ref]$dateResult)) {
            return $dateResult
        }

        $dateIsoResult = [datetime]::MinValue
        if ([datetime]::TryParse(
                $text,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$dateIsoResult
            )) {
            return $dateIsoResult
        }

        $timeSpanResult = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse($text, $cultureEnUs, [ref]$timeSpanResult)) {
            return $timeSpanResult
        }

        if ($text -match '^\d+(\.\d+){1,3}$') {
            try {
                $ver = New-Object System.Version($text)
                return $ver
            }
            catch { }
        }

        return $raw
    }

    $extraErrorMessage = 'Disallowed exit code 0 exitcode encountered.'
    $customErrorCode   = 99

    if ($null -eq $HideValues) {
        $HideValues = @()
    }

    $resolvedExecutable = Get-Command -Name $Executable -ErrorAction SilentlyContinue
    if ($null -eq $resolvedExecutable) {
        _Write-StandardMessage -Message "Executable '$Executable' was not found. Install it, add it to PATH, or specify a valid full path." -Level ERR
        return $null
    }

    $resolvedName = $resolvedExecutable.Name
    $resolvedPath = $Executable

    $hasPath = $resolvedExecutable.PSObject.Properties.Match('Path').Count -gt 0
    if ($hasPath -and -not [string]::IsNullOrEmpty([string]$resolvedExecutable.Path)) {
        $resolvedPath = [string]$resolvedExecutable.Path
    }
    else {
        $hasDef = $resolvedExecutable.PSObject.Properties.Match('Definition').Count -gt 0
        if ($hasDef -and -not [string]::IsNullOrEmpty([string]$resolvedExecutable.Definition)) {
            $resolvedPath = [string]$resolvedExecutable.Definition
        }
    }

    $finalArgs            = _InvokeExecBuildArgs -Primary $Arguments -Shared $CommonArguments
    $displayArgs          = _InvokeExecMaskArgs -ArgsToMask $finalArgs -SensitiveValues $HideValues
    $normalizedReturnType = $ReturnType.ToLowerInvariant()

    _Write-StandardMessage -Message ("Before Command : (Executable: {0}, Args Count: {1})" -f $resolvedName, $finalArgs.Count) -Level INF
    _Write-StandardMessage -Message ("Full Command   : {0} {1}" -f $resolvedName, ($displayArgs -join ' ')) -Level INF

    $stopwatch = $null
    if ($MeasureTime) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $resolvedPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    # Optional alternate credentials (Windows only)
    if ($PSBoundParameters.ContainsKey('Credential') -and $null -ne $Credential) {
        $onWindows = $true
        try {
            $onWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
        }
        catch { $onWindows = $true }

        if (-not $onWindows) {
            if ($MeasureTime -and $null -ne $stopwatch) { $stopwatch.Stop() }
            _Write-StandardMessage -Message "Credential parameter is only supported on Windows platforms." -Level ERR
            return $null
        }

        $userName = $Credential.UserName
        $domain   = $null

        if ($userName -like '*\*') {
            $parts   = $userName.Split('\', 2)
            $domain  = $parts[0]
            $userName = $parts[1]
        }
        elseif ($userName -like '*@*') {
            # UPN-style: leave domain empty, username is full UPN
            $domain = ''
        }

        $psi.UserName = $userName

        if ($null -ne $domain) {
            $psi.Domain = $domain
        }

        # On Windows PowerShell / .NET Framework: Password is SecureString
        $psi.Password = $Credential.Password
    }

    $supportsArgumentList = $psi.PSObject.Properties.Match('ArgumentList').Count -gt 0
    if ($supportsArgumentList) {
        foreach ($argument in $finalArgs) {
            if ($null -ne $argument) {
                [void]$psi.ArgumentList.Add([string]$argument)
            }
        }
    }
    else {
        $psi.Arguments = _InvokeExecBuildArgumentString -Args $finalArgs
    }

    if ($CaptureOutput -or $CaptureOutputDump) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
    }
    else {
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError  = $false
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        if ($MeasureTime -and $null -ne $stopwatch) {
            $stopwatch.Stop()
        }
        _Write-StandardMessage -Message ("Failed to start process '{0}'." -f $resolvedName) -Level ERR
        return $null
    }

    $collected = New-Object 'System.Collections.Generic.List[object]'

    if ($CaptureOutput) {
        while (-not $process.HasExited -or -not $process.StandardOutput.EndOfStream -or -not $process.StandardError.EndOfStream) {
            if (-not $process.StandardOutput.EndOfStream) {
                $line = $process.StandardOutput.ReadLine()
                if ($null -ne $line) {
                    if ($normalizedReturnType -eq 'objects') {
                        $typed = _InvokeExecConvertFromString -InputObject $line
                        [void]$collected.Add($typed)
                    }
                    else {
                        [void]$collected.Add($line)
                    }
                }
            }

            if (-not $process.StandardError.EndOfStream) {
                $line = $process.StandardError.ReadLine()
                if ($null -ne $line) {
                    if ($normalizedReturnType -eq 'objects') {
                        $typed = _InvokeExecConvertFromString -InputObject $line
                        [void]$collected.Add($typed)
                    }
                    else {
                        [void]$collected.Add($line)
                    }
                }
            }
        }
    }
    elseif ($CaptureOutputDump) {
        while (-not $process.HasExited -or -not $process.StandardOutput.EndOfStream -or -not $process.StandardError.EndOfStream) {
            if (-not $process.StandardOutput.EndOfStream) {
                $null = $process.StandardOutput.ReadLine()
            }
            if (-not $process.StandardError.EndOfStream) {
                $null = $process.StandardError.ReadLine()
            }
        }
    }

    $process.WaitForExit()

    if ($MeasureTime -and $null -ne $stopwatch) {
        $stopwatch.Stop()
    }

    $exitCode = $process.ExitCode
    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    $result = $null
    if ($CaptureOutput) {
        $result = $collected.ToArray()
    }

    $isAllowed = $false
    if ($null -ne $AllowedExitCodes -and $AllowedExitCodes.Count -gt 0) {
        if ($AllowedExitCodes -contains $exitCode) {
            $isAllowed = $true
        }
    }

    if (-not $isAllowed) {
        if ($CaptureOutput -and $null -ne $result) {
            _Write-StandardMessage -Message 'Captured Output (non-success exit code):' -Level WRN
            foreach ($line in $result) {
                _Write-StandardMessage -Message ([string]$line) -Level DBG
            }
        }

        $elapsedSuffix = ''
        if ($MeasureTime -and $null -ne $stopwatch) {
            $elapsedSuffix = " (Execution time: $($stopwatch.Elapsed))"
        }

        if ($exitCode -eq 0) {
            $errorMessage = ("Command '{0} {1}' returned exit code 0, which is disallowed. {2} Translated to custom error code {3}." -f $resolvedName, ($displayArgs -join ' '), $extraErrorMessage, $customErrorCode)
            _Write-StandardMessage -Message ($errorMessage + $elapsedSuffix) -Level ERR
            exit $customErrorCode
        }
        else {
            $errorMessage = ("Command '{0} {1}' returned disallowed exit code {2}. Exiting script with exit code {2}." -f $resolvedName, ($displayArgs -join ' '), $exitCode)
            _Write-StandardMessage -Message ($errorMessage + $elapsedSuffix) -Level ERR
            exit $exitCode
        }
    }

    $afterMessage = 'After Command'
    if ($MeasureTime -and $null -ne $stopwatch) {
        $afterMessage = "After Command  : (Execution time: $($stopwatch.Elapsed))"
    }
    _Write-StandardMessage -Message $afterMessage -Level INF

    if (-not $CaptureOutput) {
        return $null
    }

    switch ($normalizedReturnType) {
        'objects' {
            if ($null -eq $result) { return @() }
            return @($result)
        }
        'strings' {
            if ($null -eq $result) { return ,@() }
            $stringItems = @()
            foreach ($item in $result) {
                if ($null -eq $item) {
                    $stringItems += ''
                }
                else {
                    $stringItems += [string]$item
                }
            }
            return ,@($stringItems)
        }
        default {
            if ($null -eq $result) { return '' }
            $lines = @()
            foreach ($rawLine in $result) {
                if ($null -eq $rawLine) {
                    $lines += ''
                }
                else {
                    $lines += [string]$rawLine
                }
            }
            return ($lines -join [Environment]::NewLine)
        }
    }
}

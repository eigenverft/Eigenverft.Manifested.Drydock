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

.PARAMETER MeasureTime
When true (default), measures and prints elapsed execution time.

.PARAMETER CaptureOutput
When true (default), captures and returns process output; when false, streams to the host and returns $null.

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
$txt = Invoke-Exec2 -Executable "dotnet" -Arguments @("build","MyApp.csproj") -CommonArguments $common -ReturnType Text

.EXAMPLE
# Capture a single boolean-like value robustly
$raw = Invoke-Exec2 -Executable "cmd" -Arguments @("/c","echo","True") -ReturnType Objects
$ok  = [bool]::Parse([string]$raw)   # $ok = $true

.EXAMPLE
# Force string[] lines
$lines = Invoke-Exec2 -Executable "git" -Arguments @("status","--porcelain") -ReturnType Strings
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

    Write-Host "===> Before Command (Executable: $Executable, Args Count: $($finalArgs.Count)) ==============================================" -ForegroundColor Yellow
    Write-Host "===> Full Command: $Executable $($finalArgs -join ' ')" -ForegroundColor Cyan

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
            Write-Error "Command '$Executable $($finalArgs -join ' ')' returned exit code 0, which is disallowed. $ExtraErrorMessage Translated to custom error code $CustomErrorCode."
            if ($MeasureTime) {
                Write-Host "===> After Command (Execution time: $($stopwatch.Elapsed)) ==============================================" -ForegroundColor DarkGreen
            } else {
                Write-Host "===> After Command ==============================================" -ForegroundColor DarkGreen
            }
            exit $CustomErrorCode
        } else {
            Write-Error "Command '$Executable $($finalArgs -join ' ')' returned disallowed exit code $LASTEXITCODE. Exiting script with exit code $LASTEXITCODE."
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

function Invoke-OrgExec {
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

.PARAMETER MeasureTime
When true (default), measures and prints elapsed execution time.

.PARAMETER CaptureOutput
When true (default), captures and returns process output; when false, streams to the host and returns $null.

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
$txt = Invoke-Exec2 -Executable "dotnet" -Arguments @("build","MyApp.csproj") -CommonArguments $common -ReturnType Text

.EXAMPLE
# Capture a single boolean-like value robustly
$raw = Invoke-Exec2 -Executable "cmd" -Arguments @("/c","echo","True") -ReturnType Objects
$ok  = [bool]::Parse([string]$raw)   # $ok = $true

.EXAMPLE
# Force string[] lines
$lines = Invoke-Exec2 -Executable "git" -Arguments @("status","--porcelain") -ReturnType Strings
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

        [Alias('mt')]
        [bool]$MeasureTime = $true,

        [Alias('co')]
        [bool]$CaptureOutput = $true,

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

    Write-Host "===> Before Command (Executable: $Executable, Args Count: $($finalArgs.Count)) ==============================================" -ForegroundColor DarkCyan
    Write-Host "===> Full Command: $Executable $($finalArgs -join ' ')" -ForegroundColor Cyan

    if ($MeasureTime) { $stopwatch = [System.Diagnostics.Stopwatch]::StartNew() }

    if ($CaptureOutput) {
        $result = & $Executable @finalArgs
    } else {
        & $Executable @finalArgs
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
            Write-Error "Command '$Executable $($finalArgs -join ' ')' returned exit code 0, which is disallowed. $ExtraErrorMessage Translated to custom error code $CustomErrorCode."
            if ($MeasureTime) {
                Write-Host "===> After Command (Execution time: $($stopwatch.Elapsed)) ==============================================" -ForegroundColor DarkGreen
            } else {
                Write-Host "===> After Command ==============================================" -ForegroundColor DarkGreen
            }
            exit $CustomErrorCode
        } else {
            Write-Error "Command '$Executable $($finalArgs -join ' ')' returned disallowed exit code $LASTEXITCODE. Exiting script with exit code $LASTEXITCODE."
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


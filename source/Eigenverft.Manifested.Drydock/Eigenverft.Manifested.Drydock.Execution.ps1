function Invoke-Exec {
<#
    .SYNOPSIS
    Run an external executable with merged per-call and shared arguments, optional timing/output capture, and strict exit-code validation.

    .DESCRIPTION
    This function invokes an external process and enforces a clear separation between:
      • Arguments        – Command-specific or per-invocation parameters (e.g., subcommands, positional paths, flags unique to this call).
      • CommonArguments  – Stable, shared parameters reused across many calls (e.g., verbosity, configuration, global properties).

    How they are combined:
      • The function appends CommonArguments after Arguments (final order: Arguments then CommonArguments).
      • This keeps subcommands and positional items early (reducing parsing ambiguity) while still applying consistent, shared flags last.

    Why it’s implemented this way:
      1) Maintainability/DRY: Shared flags live in one place and are reused, minimizing duplication across many Invoke-Exec calls.
      2) Predictable parsing: Many CLIs expect subcommand + positional inputs first; appending shared flags later avoids collisions.
      3) Auditability: Logs show a stable, recognizable tail of common options, making diffs and diagnostics easier.
      4) Flexibility: Per-call Arguments can override intent locally; CommonArguments enforce environment-wide defaults.
         (Note: If a CLI honors “last one wins”, values in CommonArguments can intentionally finalize defaults. If your CLI prefers
          the first occurrence, move critical overrides into Arguments or adjust your common set accordingly.)

    Behavior:
      • If -CaptureOutput is true, the function returns the command’s output; else it streams to host and returns $null.
      • If -MeasureTime is true, it prints elapsed time.
      • Exit code must be in AllowedExitCodes. If not:
          - If the actual code is 0 but 0 is not allowed, the function emits an error and exits the script with custom code 99.
          - Otherwise, it exits the script with the disallowed code.
      • Diagnostics include a “Full Command” line and optional echo of captured output on error.

    Usage guidance:
      • Put subcommands/positional paths in Arguments (e.g., "build", "path/to/project").
      • Put global, stable flags in CommonArguments (e.g., verbosity, configuration, feature toggles, build metadata).
      • Keep CommonArguments reusable across multiple Invoke-Exec calls in your pipeline or script.

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

    .OUTPUTS
    System.Object[]. Returns captured output when -CaptureOutput is true; otherwise returns $null.

    .EXAMPLE
    # Define a reusable set of shared flags, then call with per-invocation specifics.
    $common = @("--verbosity","minimal","-c","Release","-p:BuildChannel=Public")
    Invoke-Exec -Executable "dotnet" -Arguments @("build","MyApp.csproj") -CommonArguments $common

    .EXAMPLE
    # Run a different subcommand with the same shared flags.
    $common = @("--verbosity","normal","-c","Debug","-p:TelemetryOptOut=true")
    Invoke-Exec -Executable "dotnet" -Arguments @("test","MyApp.Tests.csproj","--no-build") -CommonArguments $common

    .EXAMPLE
    # Stream output live (no capture) and enforce a stricter set of allowed exit codes.
    $shared = @("--nologo")
    Invoke-Exec -Executable "toolX" -Arguments @("run","input.txt") -CommonArguments $shared -CaptureOutput:$false -AllowedExitCodes @(0,2)

    .NOTES
    If your CLI gives precedence to the first occurrence of a flag, ensure critical per-call overrides appear only in Arguments
    or adjust the common set to avoid duplicates.
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
        [int[]]$AllowedExitCodes = @(0)
    )

    # Internal fixed values for custom error handling
    $ExtraErrorMessage = "Disallowed exit code 0 exitcode encountered."
    $CustomErrorCode   = 99

    # Combine CommonArguments and Arguments (handle null or empty)
    $finalArgs = @()
    if ($Arguments -and $Arguments.Count -gt 0) {
        $finalArgs += $Arguments
    }
    if ($CommonArguments -and $CommonArguments.Count -gt 0) {
        $finalArgs += $CommonArguments
    }

    Write-Host "===> Before Command (Executable: $Executable, Args Count: $($finalArgs.Count)) ==============================================" -ForegroundColor DarkCyan
    Write-Host "===> Full Command: $Executable $($finalArgs -join ' ')" -ForegroundColor Cyan

    if ($MeasureTime) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    if ($CaptureOutput) {
        $result = & $Executable @finalArgs
    }
    else {
        & $Executable @finalArgs
        $result = $null
    }

    if ($MeasureTime) {
        $stopwatch.Stop()
    }

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
            }
            else {
                Write-Host "===> After Command ==============================================" -ForegroundColor DarkGreen
            }
            exit $CustomErrorCode
        }
        else {
            Write-Error "Command '$Executable $($finalArgs -join ' ')' returned disallowed exit code $LASTEXITCODE. Exiting script with exit code $LASTEXITCODE."
            if ($MeasureTime) {
                Write-Host "===> After Command (Execution time: $($stopwatch.Elapsed)) ==============================================" -ForegroundColor DarkGreen
            }
            else {
                Write-Host "===> After Command ==============================================" -ForegroundColor DarkGreen
            }
            exit $LASTEXITCODE
        }
    }

    if ($MeasureTime) {
        Write-Host "===> After Command (Execution time: $($stopwatch.Elapsed)) ==============================================" -ForegroundColor DarkGreen
    }
    else {
        Write-Host "===> After Command ==============================================" -ForegroundColor DarkGreen
    }
    return $result
}

function Test-WindowsPathLimits {
<#
.SYNOPSIS
Diagnose Windows long-path policy and runtime path create behavior.

.DESCRIPTION
Public standalone Drydock diagnostic. Reports:
- OS LongPathsEnabled registry policy
- Current PowerShell / .NET host identity
- Empirical FileStream create probes around and above 260 characters
- Optional analysis of concrete paths from error logs (e.g. Package depot partial paths)

Use this when logs show opaque FileStream ".ctor" failures such as
"Could not find a part of the path" to distinguish missing parent directories from
classic MAX_PATH limits and per-component length limits.

Does not call other Drydock module functions.

.PARAMETER Path
Optional concrete path(s) to classify (from an error log). No file is created for these
unless -TryOpenPath is also specified.

.PARAMETER TryOpenPath
When set with -Path, attempts a real FileStream create for each analyzed path
(under the existing parent only; does not create missing parents).

.PARAMETER ProbeRoot
Root directory for empirical length probes. Default: %TEMP%\Evf.PathLimitProbe

.PARAMETER SkipProbe
Skip empirical create probes; only report policy and optional -Path analysis.

.EXAMPLE
Test-WindowsPathLimits

.EXAMPLE
Test-WindowsPathLimits -Path 'C:\Users\Administrator\AppData\Local\Programs\Evf.Package\PkgDepot\evf\CursorCli\stable\2026.07.16-899851b\win32-x64\agent-cli-package-2026.07.16-899851b-win32-x64.zip.partial.5a7bbeca2c6478936978e25da0939d453aec63120c22d21836ce1d3f112ba328.ca28a3d1399349bd98422a12b102cdb3'

.EXAMPLE
Test-WindowsPathLimits -Path $failedPartial -TryOpenPath

.NOTES
Self-contained public command. Helpers are local to this function.
#>
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter()]
        [string[]]$Path,

        [Parameter()]
        [switch]$TryOpenPath,

        [Parameter()]
        [string]$ProbeRoot = (Join-Path $env:TEMP 'Evf.PathLimitProbe'),

        [Parameter()]
        [switch]$SkipProbe
    )

    function local:Get-WindowsLongPathsPolicy {
        $keyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        $valueName = 'LongPathsEnabled'
        $result = [ordered]@{
            RegistryPath        = $keyPath
            ValueName           = $valueName
            ValuePresent        = $false
            LongPathsEnabled    = $false
            LongPathsEnabledRaw = $null
            ReadError           = $null
        }

        try {
            $item = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction Stop
            $raw = [int]$item.$valueName
            $result.ValuePresent = $true
            $result.LongPathsEnabledRaw = $raw
            $result.LongPathsEnabled = ($raw -ne 0)
        }
        catch {
            $result.ReadError = $_.Exception.Message
        }

        [pscustomobject]$result
    }

    function local:Resolve-PathIoFailureHint {
        param(
            [Parameter(Mandatory)]
            [string]$TargetPath,

            [Parameter()]
            [System.Exception]$Exception
        )

        $normalized = $TargetPath.Trim()
        if ($normalized.StartsWith('\\?\', [StringComparison]::Ordinal)) {
            $normalized = $normalized.Substring(4)
        }

        $parent = [System.IO.Path]::GetDirectoryName($normalized)
        $fileName = [System.IO.Path]::GetFileName($normalized)
        $parentExists = if ([string]::IsNullOrWhiteSpace($parent)) {
            $false
        }
        else {
            Test-Path -LiteralPath $parent -PathType Container
        }
        $pathLength = $normalized.Length
        $fileNameLength = if ($null -eq $fileName) { 0 } else { $fileName.Length }
        $parentLength = if ($null -eq $parent) { 0 } else { $parent.Length }

        $exceptionText = if ($Exception) {
            if ($Exception.InnerException) { $Exception.InnerException.Message } else { $Exception.Message }
        }
        else {
            $null
        }

        $hints = New-Object System.Collections.Generic.List[string]
        $likelyCause = 'Unknown'
        $secondaryRisks = New-Object System.Collections.Generic.List[string]

        if ($fileNameLength -gt 255) {
            $likelyCause = 'ComponentTooLong'
            [void]$hints.Add(("File name length {0} exceeds Windows per-component limit 255." -f $fileNameLength))
        }
        elseif (-not $parentExists) {
            $likelyCause = 'MissingParentDirectory'
            [void]$hints.Add(("Parent directory does not exist: '{0}'." -f $parent))
            [void]$hints.Add('Same Win32/HRESULT text often appears for missing parents and for overlong paths.')
            if ($pathLength -gt 259) {
                [void]$secondaryRisks.Add('ClassicMaxPathOverflow')
                [void]$hints.Add(("Secondary risk: full path length {0} also exceeds classic MAX_PATH (~259 usable). After creating the parent, create may still fail on non-long-path-aware hosts." -f $pathLength))
            }
        }
        elseif ($pathLength -gt 259) {
            $likelyCause = 'ClassicMaxPathOverflow'
            [void]$hints.Add(("Full path length {0} exceeds classic MAX_PATH usable limit (~259 chars, API often reports 260 including NUL)." -f $pathLength))
            [void]$hints.Add('Parent exists, so missing-folder is unlikely; host may still be limited to legacy MAX_PATH.')
        }
        else {
            $likelyCause = 'OtherIoFailure'
            [void]$hints.Add('Path length and parent look OK; failure is likely ACL, sharing, invalid chars, or another IO condition.')
        }

        [pscustomobject]@{
            Path                  = $normalized
            PathLength            = $pathLength
            ParentDirectory       = $parent
            ParentDirectoryLength = $parentLength
            ParentExists          = $parentExists
            FileName              = $fileName
            FileNameLength        = $fileNameLength
            ExceedsClassicMaxPath = ($pathLength -gt 259)
            ExceedsComponentLimit = ($fileNameLength -gt 255)
            LikelyCause           = $likelyCause
            SecondaryRisks        = @($secondaryRisks.ToArray())
            Hints                 = @($hints.ToArray())
            ExceptionMessage      = $exceptionText
        }
    }

    function local:New-ProbeFilePath {
        param(
            [Parameter(Mandatory)]
            [string]$Root,

            [Parameter(Mandatory)]
            [int]$TargetFullLength
        )

        $prefix = Join-Path $Root 'probe'
        $prefixWithSep = $prefix + [System.IO.Path]::DirectorySeparatorChar
        $remaining = $TargetFullLength - $prefixWithSep.Length
        if ($remaining -lt 8) {
            throw ("ProbeRoot too long for target length {0}: '{1}'" -f $TargetFullLength, $Root)
        }

        $stemLen = $remaining - 4
        if ($stemLen -lt 1) {
            throw ("Cannot build probe name for target length {0}." -f $TargetFullLength)
        }

        $stem = ('a' * $stemLen)
        $candidate = Join-Path $prefix ($stem + '.bin')
        if ($candidate.Length -ne $TargetFullLength) {
            $delta = $TargetFullLength - $candidate.Length
            if ($delta -gt 0) {
                $stem = $stem + ('b' * $delta)
            }
            elseif ($delta -lt 0 -and $stem.Length -gt -$delta) {
                $stem = $stem.Substring(0, $stem.Length + $delta)
            }
            $candidate = Join-Path $prefix ($stem + '.bin')
        }

        return $candidate
    }

    function local:Test-FileStreamCreate {
        param(
            [Parameter(Mandatory)]
            [string]$TargetPath,

            [Parameter()]
            [switch]$UseExtendedSyntax
        )

        $openPath = if ($UseExtendedSyntax -and -not $TargetPath.StartsWith('\\?\', [StringComparison]::Ordinal)) {
            '\\?\' + $TargetPath
        }
        else {
            $TargetPath
        }

        $created = $false
        $errorMessage = $null
        try {
            $parent = [System.IO.Path]::GetDirectoryName($TargetPath)
            if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }

            $fs = [System.IO.FileStream]::new(
                $openPath,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None,
                4096,
                [System.IO.FileOptions]::None
            )
            try {
                $fs.WriteByte(1)
            }
            finally {
                $fs.Dispose()
            }
            $created = $true
        }
        catch {
            $errorMessage = if ($_.Exception.InnerException) {
                $_.Exception.InnerException.Message
            }
            else {
                $_.Exception.Message
            }
        }
        finally {
            if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
                Remove-Item -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue
            }
        }

        $exceptionForHint = $null
        if ($errorMessage) {
            $exceptionForHint = [System.IO.IOException]::new($errorMessage)
        }
        $hint = Resolve-PathIoFailureHint -TargetPath $TargetPath -Exception $exceptionForHint

        [pscustomobject]@{
            TargetPath        = $TargetPath
            OpenPath          = $openPath
            TargetPathLength  = $TargetPath.Length
            UseExtendedSyntax = [bool]$UseExtendedSyntax
            CreateSucceeded   = $created
            ErrorMessage      = $errorMessage
            LikelyCause       = if ($created) { 'None' } else { $hint.LikelyCause }
            Hints             = if ($created) { @() } else { $hint.Hints }
        }
    }

    $policy = Get-WindowsLongPathsPolicy

    $runtime = [ordered]@{
        PSVersion            = $PSVersionTable.PSVersion.ToString()
        PSEdition            = [string]$PSVersionTable.PSEdition
        OSVersion            = [System.Environment]::OSVersion.VersionString
        FrameworkDescription = $null
        IsWindows            = $true
        ClassicMaxPathLimit  = 260
        ClassicMaxPathUsable = 259
        ComponentLengthLimit = 255
    }

    try {
        $runtime.FrameworkDescription = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    }
    catch {
        $runtime.FrameworkDescription = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    }

    try {
        $runtime.IsWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows
        )
    }
    catch {
        $runtime.IsWindows = ($env:OS -eq 'Windows_NT')
    }

    $pathAnalyses = @()
    foreach ($candidate in @($Path)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        $analysis = Resolve-PathIoFailureHint -TargetPath $candidate
        $openResult = $null

        if ($TryOpenPath) {
            $parent = $analysis.ParentDirectory
            if (-not $analysis.ParentExists) {
                $openResult = [pscustomobject]@{
                    CreateSucceeded   = $false
                    UseExtendedSyntax = $false
                    ErrorMessage      = ("Skipped create: parent directory missing ('{0}')." -f $parent)
                    LikelyCause       = 'MissingParentDirectory'
                }
            }
            else {
                $openResult = Test-FileStreamCreate -TargetPath $analysis.Path
                if (-not $openResult.CreateSucceeded) {
                    $openExt = Test-FileStreamCreate -TargetPath $analysis.Path -UseExtendedSyntax
                    $openResult = [pscustomobject]@{
                        CreateSucceeded         = $openResult.CreateSucceeded
                        ErrorMessage            = $openResult.ErrorMessage
                        LikelyCause             = $openResult.LikelyCause
                        ExtendedCreateSucceeded = $openExt.CreateSucceeded
                        ExtendedErrorMessage    = $openExt.ErrorMessage
                        ExtendedLikelyCause     = $openExt.LikelyCause
                    }
                }
            }
        }

        $pathAnalyses += [pscustomobject]@{
            Analysis  = $analysis
            OpenProbe = $openResult
            Summary   = @(
                ("PathLength={0}" -f $analysis.PathLength)
                ("ParentExists={0}" -f $analysis.ParentExists)
                ("LikelyCause={0}" -f $analysis.LikelyCause)
                ($analysis.Hints -join ' ')
            ) -join '; '
        }
    }

    $probes = @()
    if (-not $SkipProbe) {
        New-Item -ItemType Directory -Force -Path $ProbeRoot | Out-Null
        try {
            foreach ($len in 200, 240, 259, 260, 261, 273, 300) {
                try {
                    $target = New-ProbeFilePath -Root $ProbeRoot -TargetFullLength $len
                }
                catch {
                    $probes += [pscustomobject]@{
                        TargetPathLength  = $len
                        CreateSucceeded   = $false
                        UseExtendedSyntax = $false
                        ErrorMessage      = $_.Exception.Message
                        LikelyCause       = 'ProbeSetupFailed'
                        Hints             = @($_.Exception.Message)
                        OpenPath          = $null
                        TargetPath        = $null
                    }
                    continue
                }

                $normal = Test-FileStreamCreate -TargetPath $target
                $probes += $normal

                if (-not $normal.CreateSucceeded) {
                    $extended = Test-FileStreamCreate -TargetPath $target -UseExtendedSyntax
                    $probes += $extended
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $ProbeRoot -PathType Container) {
                Remove-Item -LiteralPath $ProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $probeVerdict = 'Skipped'
    if (-not $SkipProbe) {
        $over = @($probes | Where-Object { $_.TargetPathLength -ge 261 -and -not $_.UseExtendedSyntax })
        $overOk = @($over | Where-Object { $_.CreateSucceeded })
        $overFail = @($over | Where-Object { -not $_.CreateSucceeded })
        if ($overOk.Count -gt 0 -and $overFail.Count -eq 0) {
            $probeVerdict = 'RuntimeAllowsPathsBeyondClassicMaxPath'
        }
        elseif ($overOk.Count -gt 0) {
            $probeVerdict = 'RuntimePartiallyAllowsLongPaths'
        }
        elseif ($overFail.Count -gt 0) {
            $probeVerdict = 'RuntimeBlockedByClassicMaxPath'
        }
        else {
            $probeVerdict = 'Inconclusive'
        }
    }

    $policyVerdict = if ($policy.LongPathsEnabled) {
        'OsPolicyAllowsLongPaths'
    }
    elseif ($policy.ValuePresent) {
        'OsPolicyDisallowsLongPaths'
    }
    else {
        'OsPolicyUnset(defaultsToClassicMaxPath)'
    }

    $combinedParts = New-Object System.Collections.Generic.List[string]
    [void]$combinedParts.Add($policyVerdict)
    [void]$combinedParts.Add($probeVerdict)
    if ($policy.LongPathsEnabled -and $probeVerdict -eq 'RuntimeBlockedByClassicMaxPath') {
        [void]$combinedParts.Add('IMPORTANT: LongPathsEnabled=1 but this host still cannot create >260 paths (app/runtime not long-path aware).')
    }
    elseif (-not $policy.LongPathsEnabled -and $probeVerdict -eq 'RuntimeAllowsPathsBeyondClassicMaxPath') {
        [void]$combinedParts.Add('NOTE: OS policy off/unset, but this runtime still created long paths (unusual; verify probe results).')
    }

    [pscustomobject]@{
        Policy          = $policy
        Runtime         = [pscustomobject]$runtime
        PolicyVerdict   = $policyVerdict
        ProbeVerdict    = $probeVerdict
        CombinedVerdict = ($combinedParts.ToArray() -join ' | ')
        PathAnalyses    = $pathAnalyses
        Probes          = $probes
    }
}

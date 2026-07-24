# Private helpers for Windows path-limit diagnostics (not exported).

function Get-WindowsLongPathsPolicy {
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

function Resolve-PathIoFailureHint {
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,

        [Parameter()]
        [System.Exception]$Exception
    )

    $normalized = $TargetPath.Trim()
    if ($normalized.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(4)
        if ($normalized.StartsWith('UNC\', [StringComparison]::OrdinalIgnoreCase)) {
            $normalized = '\\' + $normalized.Substring(4)
        }
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

function ConvertTo-WindowsExtendedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        return $Path
    }

    if ($Path.StartsWith('\\', [StringComparison]::Ordinal)) {
        return '\\?\UNC\' + $Path.Substring(2)
    }

    return '\\?\' + $Path
}

function New-ProbeFilePath {
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

function Test-FileStreamCreate {
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,

        [Parameter()]
        [switch]$UseExtendedSyntax
    )

    $openPath = if ($UseExtendedSyntax) {
        ConvertTo-WindowsExtendedPath -Path $TargetPath
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

function Invoke-WindowsPathLimitsCore {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Classic', 'Extended')]
        [string]$Mode,

        [Parameter()]
        [string[]]$Path,

        [Parameter()]
        [switch]$TryOpenPath,

        [Parameter()]
        [string]$ProbeRoot = (Join-Path $env:TEMP 'Evf.PathLimitProbe'),

        [Parameter()]
        [switch]$SkipProbe
    )

    $useExtended = ($Mode -eq 'Extended')
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
        PathOpenMode         = $Mode
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
        $status = 'NotProbed'
        $workaroundHint = $null

        if ($TryOpenPath) {
            $parent = $analysis.ParentDirectory
            if (-not $analysis.ParentExists) {
                $openResult = [pscustomobject]@{
                    CreateSucceeded   = $false
                    UseExtendedSyntax = $useExtended
                    OpenPath          = if ($useExtended) { ConvertTo-WindowsExtendedPath -Path $analysis.Path } else { $analysis.Path }
                    ErrorMessage      = ("Skipped create: parent directory missing ('{0}')." -f $parent)
                    LikelyCause       = 'MissingParentDirectory'
                }
                $status = 'BlockedMissingParent'
                $workaroundHint = 'Create the parent directory first, then re-run both Test-WindowsPathLimits and Test-WindowsPathLimitsWithExtendedPath.'
            }
            else {
                $openResult = Test-FileStreamCreate -TargetPath $analysis.Path -UseExtendedSyntax:$useExtended
                if ($openResult.CreateSucceeded) {
                    $status = if ($useExtended) { 'ExtendedCreateSucceeded' } else { 'ClassicCreateSucceeded' }
                    $workaroundHint = if ($useExtended) {
                        'Extended path open works for this path on this host.'
                    }
                    else {
                        'Classic path open works; extended-path workaround is not required for this path.'
                    }
                }
                else {
                    $status = if ($useExtended) { 'ExtendedCreateFailed' } else { 'ClassicCreateFailed' }
                    if (-not $useExtended) {
                        $workaroundHint = 'Classic open failed. Run Test-WindowsPathLimitsWithExtendedPath -Path <same> -TryOpenPath to check whether \\?\ is a viable workaround.'
                    }
                    else {
                        $workaroundHint = 'Extended path open also failed. Likely missing parent, ACL, share lock, or component-too-long — not a simple MAX_PATH issue.'
                    }
                }
            }
        }

        $pathAnalyses += [pscustomobject]@{
            Analysis       = $analysis
            OpenProbe      = $openResult
            Status         = $status
            WorkaroundHint = $workaroundHint
            Summary        = @(
                ("Mode={0}" -f $Mode)
                ("PathLength={0}" -f $analysis.PathLength)
                ("ParentExists={0}" -f $analysis.ParentExists)
                ("LikelyCause={0}" -f $analysis.LikelyCause)
                ("Status={0}" -f $status)
                ($analysis.Hints -join ' ')
            ) -join '; '
        }
    }

    $probes = @()
    if (-not $SkipProbe) {
        $modeProbeRoot = Join-Path $ProbeRoot $Mode
        New-Item -ItemType Directory -Force -Path $modeProbeRoot | Out-Null
        try {
            foreach ($len in 200, 240, 259, 260, 261, 273, 300) {
                try {
                    $target = New-ProbeFilePath -Root $modeProbeRoot -TargetFullLength $len
                }
                catch {
                    $probes += [pscustomobject]@{
                        TargetPathLength  = $len
                        CreateSucceeded   = $false
                        UseExtendedSyntax = $useExtended
                        ErrorMessage      = $_.Exception.Message
                        LikelyCause       = 'ProbeSetupFailed'
                        Hints             = @($_.Exception.Message)
                        OpenPath          = $null
                        TargetPath        = $null
                    }
                    continue
                }

                $probes += (Test-FileStreamCreate -TargetPath $target -UseExtendedSyntax:$useExtended)
            }
        }
        finally {
            if (Test-Path -LiteralPath $modeProbeRoot -PathType Container) {
                Remove-Item -LiteralPath $modeProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $probeVerdict = 'Skipped'
    if (-not $SkipProbe) {
        $over = @($probes | Where-Object { $_.TargetPathLength -ge 261 })
        $overOk = @($over | Where-Object { $_.CreateSucceeded })
        $overFail = @($over | Where-Object { -not $_.CreateSucceeded })
        if ($overOk.Count -gt 0 -and $overFail.Count -eq 0) {
            $probeVerdict = if ($useExtended) {
                'ExtendedRuntimeAllowsPathsBeyondClassicMaxPath'
            }
            else {
                'ClassicRuntimeAllowsPathsBeyondClassicMaxPath'
            }
        }
        elseif ($overOk.Count -gt 0) {
            $probeVerdict = 'RuntimePartiallyAllowsLongPaths'
        }
        elseif ($overFail.Count -gt 0) {
            $probeVerdict = if ($useExtended) {
                'ExtendedRuntimeBlockedBeyondClassicMaxPath'
            }
            else {
                'ClassicRuntimeBlockedByClassicMaxPath'
            }
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
    [void]$combinedParts.Add(("Mode={0}" -f $Mode))
    [void]$combinedParts.Add($policyVerdict)
    [void]$combinedParts.Add($probeVerdict)
    if ($Mode -eq 'Classic' -and $probeVerdict -eq 'ClassicRuntimeBlockedByClassicMaxPath') {
        [void]$combinedParts.Add('NEXT: run Test-WindowsPathLimitsWithExtendedPath to test \\?\ workaround.')
    }
    elseif ($Mode -eq 'Extended' -and $probeVerdict -eq 'ExtendedRuntimeAllowsPathsBeyondClassicMaxPath') {
        [void]$combinedParts.Add('Workaround potential: extended paths bypass classic MAX_PATH on this host.')
    }
    elseif ($Mode -eq 'Extended' -and $probeVerdict -eq 'ExtendedRuntimeBlockedBeyondClassicMaxPath') {
        [void]$combinedParts.Add('Extended paths do not help on this host for probed lengths.')
    }

    [pscustomobject]@{
        Mode            = $Mode
        Policy          = $policy
        Runtime         = [pscustomobject]$runtime
        PolicyVerdict   = $policyVerdict
        ProbeVerdict    = $probeVerdict
        CombinedVerdict = ($combinedParts.ToArray() -join ' | ')
        PathAnalyses    = $pathAnalyses
        Probes          = $probes
    }
}

function Test-WindowsPathLimits {
<#
.SYNOPSIS
Diagnose classic (non-extended) Windows path create behavior.

.DESCRIPTION
Public Drydock diagnostic for legacy/plain path opens (no \\?\ prefix).
Reports OS LongPathsEnabled policy, host identity, empirical FileStream probes,
and optional analysis of concrete paths from error logs.

Pair with Test-WindowsPathLimitsWithExtendedPath on the same -Path to compare
status vs potential \\?\ workaround when logs show "Could not find a part of the path".

.PARAMETER Path
Optional concrete path(s) to classify (from an error log).

.PARAMETER TryOpenPath
When set with -Path, attempts a real classic FileStream create (parent must exist).

.PARAMETER ProbeRoot
Root directory for empirical length probes. Default: %TEMP%\Evf.PathLimitProbe

.PARAMETER SkipProbe
Skip empirical create probes; only report policy and optional -Path analysis.

.EXAMPLE
Test-WindowsPathLimits

.EXAMPLE
Test-WindowsPathLimits -Path $failedPartial -TryOpenPath
Test-WindowsPathLimitsWithExtendedPath -Path $failedPartial -TryOpenPath
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

    Invoke-WindowsPathLimitsCore -Mode Classic -Path $Path -TryOpenPath:$TryOpenPath -ProbeRoot $ProbeRoot -SkipProbe:$SkipProbe
}

function Test-WindowsPathLimitsWithExtendedPath {
<#
.SYNOPSIS
Diagnose Windows path create behavior using extended \\?\ path syntax.

.DESCRIPTION
Public Drydock diagnostic identical in shape to Test-WindowsPathLimits, but every
FileStream open uses the extended path prefix (\\?\ or \\?\UNC\...).

Use after a classic failure to check whether extended paths are a viable workaround
on this host (Status + WorkaroundHint on PathAnalyses).

.PARAMETER Path
Optional concrete path(s) to classify (from an error log).

.PARAMETER TryOpenPath
When set with -Path, attempts a real extended FileStream create (parent must exist).

.PARAMETER ProbeRoot
Root directory for empirical length probes. Default: %TEMP%\Evf.PathLimitProbe

.PARAMETER SkipProbe
Skip empirical create probes; only report policy and optional -Path analysis.

.EXAMPLE
Test-WindowsPathLimitsWithExtendedPath

.EXAMPLE
$failed = '...zip.partial....'
Test-WindowsPathLimits -Path $failed -TryOpenPath
Test-WindowsPathLimitsWithExtendedPath -Path $failed -TryOpenPath
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

    Invoke-WindowsPathLimitsCore -Mode Extended -Path $Path -TryOpenPath:$TryOpenPath -ProbeRoot $ProbeRoot -SkipProbe:$SkipProbe
}

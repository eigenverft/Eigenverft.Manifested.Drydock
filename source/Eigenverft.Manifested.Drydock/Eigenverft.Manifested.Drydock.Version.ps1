function Convert-DateTimeTo64SecVersionComponents {
<#
.SYNOPSIS
  Encode DateTime to 64s-packed version (Build.Major.Minor.Revision), UTC-internal.
.DESCRIPTION
  Seconds since Jan 1 (UTC) >> 6, split: HighPart (0..7), LowPart (16-bit).
  Minor = (Year * 10) + HighPart. Valid for years where Minor ≤ 65535.
#>
  [CmdletBinding()]
  [Alias('cdv64')]
  param(
    [Parameter(Mandatory=$true)][int]$VersionBuild,
    [Parameter(Mandatory=$true)][int]$VersionMajor,
    [Parameter()][datetime]$InputDate = (Get-Date).ToUniversalTime()
  )

  $dtUtc = $InputDate.ToUniversalTime()
  if ($dtUtc.Year -lt 1 -or $dtUtc.Year -gt 9999) { throw "Year must be 1..9999." }

  $startOfYear = New-Object datetime ($dtUtc.Year,1,1,0,0,0,[datetimekind]::Utc)
  $elapsedSeconds = [int](([timespan]($dtUtc - $startOfYear)).TotalSeconds)
  $shifted = $elapsedSeconds -shr 6

  $low  = $shifted -band 0xFFFF
  $high = $shifted -shr 16
  if ($high -lt 0 -or $high -gt 7) { throw "Internal HighPart=$high out of 0..7." }

  $minor = ($dtUtc.Year * 10) + $high
  if ($minor -gt 65535) { throw "VersionMinor=$minor (>65535). Use year ≤ 6552 or change packing." }

  @{
    VersionFull     = "$($VersionBuild).$($VersionMajor).$minor.$low"
    VersionBuild    = "$VersionBuild"
    VersionMajor    = "$VersionMajor"
    VersionMinor    = "$minor"
    VersionRevision = "$low"
  }
}

function Convert-64SecVersionComponentsToDateTime {
<#
.SYNOPSIS
  Decode 64s-packed version back to approximate UTC DateTime.
.DESCRIPTION
  Expects: Minor = Year*10 + HighPart, Revision = Low 16 bits.
  Robust year extraction (integer decade + normalization) to avoid rounding bugs.
#>
  [CmdletBinding()]
  [Alias('cdv64r')]
  param(
    [Parameter(Mandatory=$true)][int]$VersionBuild,
    [Parameter(Mandatory=$true)][int]$VersionMajor,
    [Parameter(Mandatory=$true)][int]$VersionMinor,
    [Parameter(Mandatory=$true)][int]$VersionRevision
  )

  if ($VersionMinor -lt 0) { throw "VersionMinor must be >= 0." }

  # --- Robust decade split (avoid rounding-to-nearest bugs) ---
  # Use integer truncation then normalize remainder into 0..9.
  $year = [int]($VersionMinor / 10)          # truncates toward zero for positives
  $high = $VersionMinor - ($year * 10)
  if ($high -lt 0) { $year -= 1; $high += 10 }
  elseif ($high -gt 9) { $year += 1; $high -= 10 }

  if ($year -lt 1 -or $year -gt 9999) { throw "Decoded year $year out of 1..9999." }
  if ($high -lt 0 -or $high -gt 7)    { throw "HighPart $high out of range 0..7 not an encoded 64s version." }

  $low = $VersionRevision -band 0xFFFF
  if ($VersionRevision -ne $low) { throw "VersionRevision $VersionRevision exceeds 16 bits." }

  $shifted = ($high -shl 16) -bor $low

  $isLeap = [datetime]::IsLeapYear($year)
  $secondsInYear = if ($isLeap) { 31622400 } else { 31536000 }
  $maxShifted = [int][math]::Floor(($secondsInYear - 1) / 64)
  if ($shifted -gt $maxShifted) {
    throw "ShiftedSeconds $shifted exceeds max $maxShifted for year $year components invalid."
  }

  $startOfYearUtc = New-Object datetime ($year,1,1,0,0,0,[datetimekind]::Utc)
  $computed = $startOfYearUtc.AddSeconds($shifted * 64)

  @{
    VersionBuild     = $VersionBuild
    VersionMajor     = $VersionMajor
    ComputedDateTime = $computed
  }
}

function Convert-DateTimeTo64SecPowershellVersion {
    <#
    .SYNOPSIS
        Converts a DateTime to a simplified three-part version string using 64-second encoding.
        
    .DESCRIPTION
        This function wraps Convert-DateTimeTo64SecVersionComponents and remaps its four-part version
        into a simplified three-part version. The mapping is:
          - New Build remains the same.
          - New Major is the original VersionMinor.
          - New Minor is the original VersionRevision.
        The resulting version is in the form: "Build.NewMajor.NewMinor"
        (e.g., if the original output is 1.0.20250.1234, the simplified version becomes "1.20250.1234").
        
    .PARAMETER VersionBuild
        An integer representing the build version component.
        
    .PARAMETER InputDate
        An optional UTC DateTime. If not provided, the current UTC time is used.
        
    .EXAMPLE
        PS C:\> Convert-DateTimeTo64SecPowershellVersion -VersionBuild 1 -InputDate (Get-Date)
    #>
    [CmdletBinding()]
    [alias("cdv64ps")]
    param(
        [Parameter(Mandatory = $true)]
        [int]$VersionBuild,
        [Parameter(Mandatory = $false)]
        [datetime]$InputDate = (Get-Date).ToUniversalTime()
    )

    # Call the original conversion function, assuming VersionMajor is 0.
    $original = Convert-DateTimeTo64SecVersionComponents -VersionBuild $VersionBuild -VersionMajor 0 -InputDate $InputDate

    # Remap: New Major = original VersionMinor, New Minor = original VersionRevision.
    $newMajor = $original.VersionMinor
    $newMinor = $original.VersionRevision

    $versionFull = "$($original.VersionBuild).$newMajor.$newMinor"

    return @{
        VersionFull  = $versionFull;
        VersionBuild = $original.VersionBuild;
        VersionMajor = $newMajor;
        VersionMinor = $newMinor
    }
}

function Convert-64SecPowershellVersionToDateTime {
    <#
    .SYNOPSIS
        Reconstructs an approximate DateTime from a simplified three-part version using 64-second encoding.
        
    .DESCRIPTION
        This function reverses the mapping performed by Convert-DateTimeTo64SecPowershellVersion.
        It expects the simplified version in the form:
            VersionBuild.NewMajor.NewMinor
        where:
          - NewMajor corresponds to the original VersionMinor (encoding the high part of the DateTime).
          - NewMinor corresponds to the original VersionRevision (encoding the low part of the DateTime).
        Since the original VersionMajor is not preserved in the simplified version, it is assumed to be 0.
        The function calls Convert-64SecVersionComponentsToDateTime with these mapped values to reconstruct
        the approximate DateTime.
        
    .PARAMETER VersionBuild
        An integer representing the build component of the version.
        
    .PARAMETER VersionMajor
        An integer representing the major component of the simplified version,
        which is mapped from the original VersionMinor.
        
    .PARAMETER VersionMinor
        An integer representing the minor component of the simplified version,
        which is mapped from the original VersionRevision.
        
    .EXAMPLE
        PS C:\> Convert-64SecPowershellVersionToDateTime -VersionBuild 1 -VersionMajor 20250 -VersionMinor 1234
        Returns a hashtable containing the simplified version string, the VersionBuild, and the computed DateTime.
    #>
    [CmdletBinding()]
    [alias("cdv64psr")]
    param(
        [Parameter(Mandatory = $true)]
        [int]$VersionBuild,
        [Parameter(Mandatory = $true)]
        [int]$VersionMajor,  # Represents the original VersionMinor.
        [Parameter(Mandatory = $true)]
        [int]$VersionMinor   # Represents the original VersionRevision.
    )

    # Since the original VersionMajor is not included in the simplified version, we assume it to be 0.
    $result = Convert-64SecVersionComponentsToDateTime -VersionBuild $VersionBuild -VersionMajor 0 -VersionMinor $VersionMajor -VersionRevision $VersionMinor

    # Rebuild the simplified version string for clarity.
    $versionFull = "$VersionBuild.$VersionMajor.$VersionMinor"

    return @{
        VersionFull      = $versionFull;
        VersionBuild     = $VersionBuild;
        ComputedDateTime = $result.ComputedDateTime
    }
}


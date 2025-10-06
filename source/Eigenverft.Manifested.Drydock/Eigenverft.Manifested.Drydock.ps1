function Get-GitTopLevelDirectory {
    <#
    .SYNOPSIS
        Retrieves the top-level directory of the current Git repository.

    .DESCRIPTION
        This function calls Git using 'git rev-parse --show-toplevel' to determine
        the root directory of the current Git repository. If Git is not available
        or the current directory is not within a Git repository, the function returns
        an error. The function converts any forward slashes to the system's directory
        separator (works correctly on both Windows and Linux).

    .PARAMETER None
        This function does not require any parameters.

    .EXAMPLE
        PS C:\Projects\MyRepo> Get-GitTopLevelDirectory
        C:\Projects\MyRepo

    .NOTES
        Ensure Git is installed and available in your system's PATH.
    #>
    [CmdletBinding()]
    [alias("ggtd")]
    param()

    try {
        # Attempt to retrieve the top-level directory of the Git repository.
        $topLevel = git rev-parse --show-toplevel 2>$null

        if (-not $topLevel) {
            Write-Error "Not a Git repository or Git is not available in the PATH."
            return $null
        }

        # Trim the result and replace forward slashes with the current directory separator.
        $topLevel = $topLevel.Trim().Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        return $topLevel
    }
    catch {
        Write-Error "Error retrieving Git top-level directory: $_"
    }
}

function Get-GitCurrentBranch {
    <#
    .SYNOPSIS
    Retrieves the current Git branch name.

    .DESCRIPTION
    This function calls Git to determine the current branch. It first uses
    'git rev-parse --abbrev-ref HEAD' to get the branch name. If the output is
    "HEAD" (indicating a detached HEAD state), it then attempts to find a branch
    that contains the current commit using 'git branch --contains HEAD'. If no
    branch is found, it falls back to returning the commit hash.

    .EXAMPLE
    PS C:\> Get-GitCurrentBranch

    Returns:
    master

    .NOTES
    - Ensure Git is available in your system's PATH.
    - In cases of a detached HEAD with multiple containing branches, the first
      branch found is returned.
    #>
    [CmdletBinding()]
    [alias("ggcb")]
    param()
    
    try {
        # Get the abbreviated branch name
        $branch = git rev-parse --abbrev-ref HEAD 2>$null

        # If HEAD is returned, we're in a detached state.
        if ($branch -eq 'HEAD') {
            # Try to get branch names that contain the current commit.
            $branches = git branch --contains HEAD 2>$null | ForEach-Object {
                # Remove any asterisks or leading/trailing whitespace.
                $_.Replace('*','').Trim()
            } | Where-Object { $_ -ne '' }

            if ($branches.Count -gt 0) {
                # Return the first branch found
                return $branches[0]
            }
            else {
                # As a fallback, return the commit hash.
                return git rev-parse HEAD 2>$null
            }
        }
        else {
            return $branch.Trim()
        }
    }
    catch {
        Write-Error "Error retrieving Git branch: $_"
    }
}

function Get-GitCurrentBranchRoot {
    <#
    .SYNOPSIS
    Retrieves the root portion of the current Git branch name.

    .DESCRIPTION
    This function retrieves the current Git branch name by invoking Git commands directly.
    It first attempts to get the branch name using 'git rev-parse --abbrev-ref HEAD'. If the result is
    "HEAD" (indicating a detached HEAD state), it then looks for a branch that contains the current commit
    via 'git branch --contains HEAD'. If no branch is found, it falls back to using the commit hash.
    The function then splits the branch name on both forward (/) and backslashes (\) and returns the first
    segment as the branch root.

    .EXAMPLE
    PS C:\> Get-GitCurrentBranchRoot

    Returns:
    feature

    .NOTES
    - Ensure Git is available in your system's PATH.
    - For detached HEAD states with multiple containing branches, the first branch found is used.
    #>
    [CmdletBinding()]
    [alias("ggcbr")]
    param()

    try {
        # Attempt to get the abbreviated branch name.
        $branch = git rev-parse --abbrev-ref HEAD 2>$null

        # Check for detached HEAD state.
        if ($branch -eq 'HEAD') {
            # Retrieve branches containing the current commit.
            $branches = git branch --contains HEAD 2>$null | ForEach-Object {
                $_.Replace('*','').Trim()
            } | Where-Object { $_ -ne '' }

            if ($branches.Count -gt 0) {
                $branch = $branches[0]
            }
            else {
                # Fallback to commit hash if no branch is found.
                $branch = git rev-parse HEAD 2>$null
            }
        }
        
        $branch = $branch.Trim()
        if ([string]::IsNullOrWhiteSpace($branch)) {
            Write-Error "Unable to determine the current Git branch."
            return
        }
        
        # Split the branch name on both '/' and '\' and return the first segment.
        $root = $branch -split '[\\/]' | Select-Object -First 1
        return $root
    }
    catch {
        Write-Error "Error retrieving Git branch root: $_"
    }
}

function Get-GitRepositoryName {
    <#
    .SYNOPSIS
        Gibt den Namen des Git-Repositories anhand der Remote-URL zurück.

    .DESCRIPTION
        Diese Funktion ruft über 'git config --get remote.origin.url' die Remote-URL des Repositories ab.
        Anschließend wird der Repository-Name aus der URL extrahiert, indem der letzte Teil der URL (nach dem letzten "/" oder ":")
        entnommen und eine eventuell vorhandene ".git"-Endung entfernt wird.
        Sollte keine Remote-URL vorhanden sein, wird ein Fehler ausgegeben.

    .PARAMETER None
        Diese Funktion benötigt keine Parameter.

    .EXAMPLE
        PS C:\Projects\MyRepo> Get-GitRepositoryName
        MyRepo

    .NOTES
        Stelle sicher, dass Git installiert ist und in deinem Systempfad verfügbar ist.
    #>
    [CmdletBinding()]
    [alias("ggrn")]
    param()

    try {
        # Remote-URL des Repositories abrufen
        $remoteUrl = git config --get remote.origin.url 2>$null

        if (-not $remoteUrl) {
            Write-Error "No remote URL found. Ensure the repository has a remote URL.."
            return $null
        }

        $remoteUrl = $remoteUrl.Trim()

        # Entferne eine eventuell vorhandene ".git"-Endung
        if ($remoteUrl -match "\.git$") {
            $remoteUrl = $remoteUrl.Substring(0, $remoteUrl.Length - 4)
        }

        # Unterscheidung zwischen URL-Formaten (HTTPS/SSH)
        if ($remoteUrl.Contains('/')) {
            $parts = $remoteUrl.Split('/')
        }
        else {
            # SSH-Format: z.B. git@github.com:User/Repo
            $parts = $remoteUrl.Split(':')
        }

        # Letztes Element als Repository-Name extrahieren
        $repoName = $parts[-1]
        return $repoName
    }
    catch {
        Write-Error "Fehler beim Abrufen des Repository-Namens: $_"
    }
}

function Get-GitRemoteUrl {
    <#
    .SYNOPSIS
        Gibt den Namen des Git-Repositories anhand der Remote-URL zurück.

    .DESCRIPTION
        Diese Funktion ruft über 'git config --get remote.origin.url' die Remote-URL des Repositories ab.
        Anschließend wird der Repository-Name aus der URL extrahiert, indem der letzte Teil der URL (nach dem letzten "/" oder ":")
        entnommen und eine eventuell vorhandene ".git"-Endung entfernt wird.
        Sollte keine Remote-URL vorhanden sein, wird ein Fehler ausgegeben.

    .PARAMETER None
        Diese Funktion benötigt keine Parameter.

    .EXAMPLE
        PS C:\Projects\MyRepo> Get-GitRepositoryName
        MyRepo

    .NOTES
        Stelle sicher, dass Git installiert ist und in deinem Systempfad verfügbar ist.
    #>
    [CmdletBinding()]
    [alias("gru")]
    param()

    try {
        # Remote-URL des Repositories abrufen
        $remoteUrl = git config --get remote.origin.url 2>$null

        if (-not $remoteUrl) {
            Write-Error "No remote URL found. Ensure the repository has a remote URL.."
            return $null
        }

        $remoteUrl = $remoteUrl.Trim()

        return $remoteUrl
    }
    catch {
        Write-Error "Fehler beim Abrufen des Repository-Namens: $_"
    }
}

###############################################


function Convert-DateTimeTo64SecVersionComponents {
<#
.SYNOPSIS
  Encode DateTime to 64s-packed version (Build.Major.Minor.Revision), UTC-internal.
.DESCRIPTION
  Seconds since Jan 1 (UTC) >> 6, split: HighPart (0..7), LowPart (16-bit).
  Minor = (Year * 10) + HighPart. Valid for years where Minor ≤ 65535.
#>
  [CmdletBinding()]
  [Alias('cdv64_2')]
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
  [Alias('cdv64r_2')]
  param(
    [Parameter(Mandatory=$true)][int]$VersionBuild,
    [Parameter(Mandatory=$true)][int]$VersionMajor,
    [Parameter(Mandatory=$true)][int]$VersionMinor,
    [Parameter(Mandatory=$true)][int]$VersionRevision
  )

  if ($VersionMinor -lt 0) { throw "VersionMinor must be ≥ 0." }

  # --- Robust decade split (avoid rounding-to-nearest bugs) ---
  # Use integer truncation then normalize remainder into 0..9.
  $year = [int]($VersionMinor / 10)          # truncates toward zero for positives
  $high = $VersionMinor - ($year * 10)
  if ($high -lt 0) { $year -= 1; $high += 10 }
  elseif ($high -gt 9) { $year += 1; $high -= 10 }

  if ($year -lt 1 -or $year -gt 9999) { throw "Decoded year $year out of 1..9999." }
  if ($high -lt 0 -or $high -gt 7)    { throw "HighPart $high out of range 0..7 — not an encoded 64s version." }

  $low = $VersionRevision -band 0xFFFF
  if ($VersionRevision -ne $low) { throw "VersionRevision $VersionRevision exceeds 16 bits." }

  $shifted = ($high -shl 16) -bor $low

  $isLeap = [datetime]::IsLeapYear($year)
  $secondsInYear = if ($isLeap) { 31622400 } else { 31536000 }
  $maxShifted = [int][math]::Floor(($secondsInYear - 1) / 64)
  if ($shifted -gt $maxShifted) {
    throw "ShiftedSeconds $shifted exceeds max $maxShifted for year $year — components invalid."
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

###############################################

function Update-ManifestModuleVersion {
    <#
    .SYNOPSIS
        Updates the ModuleVersion in a PowerShell module manifest (psd1) file.

    .DESCRIPTION
        This function reads a PowerShell module manifest file as text, uses a regular expression to update the
        ModuleVersion value while preserving the file's comments and formatting, and writes the updated content back
        to the file. If a directory path is supplied, the function recursively searches for the first *.psd1 file and uses it.

    .PARAMETER ManifestPath
        The file or directory path to the module manifest (psd1) file. If a directory is provided, the function will
        search recursively for the first *.psd1 file.

    .PARAMETER NewVersion
        The new version string to set for the ModuleVersion property.

    .EXAMPLE
        PS C:\> Update-ManifestModuleVersion -ManifestPath "C:\projects\MyDscModule" -NewVersion "2.0.0"
        Updates the ModuleVersion of the first PSD1 manifest found in the given directory to "2.0.0".
    #>
    [CmdletBinding()]
    [alias("ummv")]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true)]
        [string]$NewVersion
    )

    # Check if the provided path exists
    if (-not (Test-Path $ManifestPath)) {
        throw "The path '$ManifestPath' does not exist."
    }

    # If the path is a directory, search recursively for the first *.psd1 file.
    $item = Get-Item $ManifestPath
    if ($item.PSIsContainer) {
        $psd1File = Get-ChildItem -Path $ManifestPath -Filter *.psd1 -Recurse | Select-Object -First 1
        if (-not $psd1File) {
            throw "No PSD1 manifest file found in directory '$ManifestPath'."
        }
        $ManifestPath = $psd1File.FullName
    }

    Write-Verbose "Using manifest file: $ManifestPath"

    # Read the manifest file content as text using .NET method.
    $content = [System.IO.File]::ReadAllText($ManifestPath)

    # Define the regex pattern to locate the ModuleVersion value.
    $pattern = "(?<=ModuleVersion\s*=\s*')[^']+(?=')"

    # Replace the current version with the new version using .NET regex.
    $updatedContent = [System.Text.RegularExpressions.Regex]::Replace($content, $pattern, $NewVersion)

    # Write the updated content back to the manifest file.
    [System.IO.File]::WriteAllText($ManifestPath, $updatedContent)
}

function Find-FilesByPattern {
    <#
    .SYNOPSIS
        Recursively searches a directory for files matching a specified pattern.
    .DESCRIPTION
        This function searches the specified directory and all its subdirectories for files
        that match the provided filename pattern (e.g., "*.txt", "*.sln", "*.csproj").
        It returns an array of matching FileInfo objects, which can be iterated with a ForEach loop.
    .PARAMETER Path
        The root directory where the search should begin.
    .PARAMETER Pattern
        The filename pattern to search for (e.g., "*.txt", "*.sln", "*.csproj").
    .EXAMPLE
        $files = Find-FilesByPattern -Path "C:\MyProjects" -Pattern "*.txt"
        foreach ($file in $files) {
            Write-Output $file.FullName
        }
    #>
    [CmdletBinding()]
    [alias("ffbp")]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    # Validate that the provided path exists and is a directory.
    if (-not (Test-Path -Path $Path -PathType Container)) {
        throw "The specified path '$Path' does not exist or is not a directory."
    }

    try {
        # Recursively search for files matching the given pattern.
        $results = Get-ChildItem -Path $Path -Filter $Pattern -Recurse -File -ErrorAction Stop
        return $results
    }
    catch {
        Write-Error "An error occurred while searching for files: $_"
    }
}

#$now=(Get-Date).ToUniversalTime()
#$e=Convert-DateTimeTo64SecVersionComponents -VersionBuild 1 -VersionMajor 0 -InputDate $now
#$d=Convert-64SecVersionComponentsToDateTime -VersionBuild ([int]$e.VersionBuild) -VersionMajor ([int]$e.VersionMajor) -VersionMinor ([int]$e.VersionMinor) -VersionRevision ([int]$e.VersionRevision)
#"Full=$($e.VersionFull)  Decoded=$($d.ComputedDateTime.ToString('o'))  Δs=$([int](($now - $d.ComputedDateTime).TotalSeconds))"


#$nowx =(Get-Date).ToUniversalTime()
#$ex=Convert-DateTimeTo64SecPowershellVersion -VersionBuild 1 -InputDate $nowx
#$dx=Convert-64SecPowershellVersionToDateTime -VersionBuild ([int]$ex.VersionBuild) -VersionMajor ([int]$ex.VersionMajor) -VersionMinor ([int]$ex.VersionMinor)
#"Full=$($ex.VersionFull)  Decoded=$($dx.ComputedDateTime.ToString('o'))  Δs=$([int](($now - $dx.ComputedDateTime).TotalSeconds))"
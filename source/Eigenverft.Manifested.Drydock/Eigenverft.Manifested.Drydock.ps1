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
        Converts a DateTime instance into NuGet and assembly version components with a granularity of 64 seconds.

    .DESCRIPTION
        This function calculates the total seconds elapsed from January 1st of the input DateTime's year and discards the lower 6 bits (each unit representing 64 seconds). The resulting value is split into:
          - LowPart: The lower 16 bits, simulating a ushort value.
          - HighPart: The remaining upper bits combined with a year-based offset (year multiplied by 10).
        The output is provided as a version string along with individual version components. This conversion is designed to generate version segments suitable for both NuGet package versions and assembly version numbers. The function accepts additional version parameters and supports years up to 6553.

    .PARAMETER VersionBuild
        An integer representing the build version component.

    .PARAMETER VersionMajor
        An integer representing the major version component.

    .PARAMETER InputDate
        An optional UTC DateTime value. If not provided, the current UTC date/time is used.
        The year of the InputDate must not exceed 6553.

    .EXAMPLE
        PS C:\> $result = Convert-DateTimeTo64SecVersionComponents -VersionBuild 1 -VersionMajor 0
        PS C:\> $result
        Name              Value
        ----              -----
        VersionFull       1.0.20250.1234
        VersionBuild      1
        VersionMajor      0
        VersionMinor      20250
        VersionRevision   1234
    #>

    [CmdletBinding()]
    [alias("cdv64")]
    param(
        [Parameter(Mandatory = $true)]
        [int]$VersionBuild,

        [Parameter(Mandatory = $true)]
        [int]$VersionMajor,

        [Parameter(Mandatory = $false)]
        [datetime]$InputDate = (Get-Date).ToUniversalTime()
    )

    # The number of bits to discard, where each unit equals 64 seconds.
    $shiftAmount = 6

    $dateTime = $InputDate

    if ($dateTime.Year -gt 6553) {
        throw "Year must not be greater than 6553."
    }

    # Determine the start of the current year
    $startOfYear = [datetime]::new($dateTime.Year, 1, 1, 0, 0, 0, $dateTime.Kind)
    
    # Calculate total seconds elapsed since the start of the year
    $elapsedSeconds = [int](([timespan]($dateTime - $startOfYear)).TotalSeconds)
    
    # Discard the lower bits by applying a bitwise shift
    $shiftedSeconds = $elapsedSeconds -shr $shiftAmount
    
    # LowPart: extract the lower 16 bits (simulate ushort using bitwise AND with 0xFFFF)
    $lowPart = $shiftedSeconds -band 0xFFFF
    
    # HighPart: remaining bits after a right-shift of 16 bits
    $highPart = $shiftedSeconds -shr 16
    
    # Combine the high part with a year offset (year multiplied by 10)
    $combinedHigh = $highPart + ($dateTime.Year * 10)
    
    # Return a hashtable with the version string and components (output names must remain unchanged)
    return @{
        VersionFull    = "$($VersionBuild.ToString()).$($VersionMajor.ToString()).$($combinedHigh.ToString()).$($lowPart.ToString())"
        VersionBuild   = $VersionBuild.ToString();
        VersionMajor   = $VersionMajor.ToString();
        VersionMinor   = $combinedHigh.ToString();
        VersionRevision = $lowPart.ToString()
    }
}

function Convert-64SecVersionComponentsToDateTime {
    <#
    .SYNOPSIS
        Reconstructs an approximate DateTime from version components encoded with 64-second granularity.
        
    .DESCRIPTION
        This function reverses the conversion performed by Convert-DateTimeTo64SecVersionComponents.
        It accepts the version components where VersionMinor is calculated as (Year * 10 + HighPart)
        and VersionRevision holds the lower 16 bits of the shifted elapsed seconds.
        The function computes:
          - The Year is extracted from VersionMinor by integer division by 10.
          - The original shifted seconds are reassembled from the high part (derived from VersionMinor) and VersionRevision.
          - Multiplying the shifted seconds by 64 recovers the approximate total elapsed seconds since the year's start.
        The function returns a hashtable with the original VersionBuild, VersionMajor, and the computed DateTime.
        Note: Due to the loss of the lower 6 bits in the original conversion, the computed DateTime is approximate.
        
    .PARAMETER VersionBuild
        An integer representing the build version component (passed through unchanged).
        
    .PARAMETER VersionMajor
        An integer representing the major version component (passed through unchanged).
        
    .PARAMETER VersionMinor
        An integer representing the combined high part of the shifted seconds along with the encoded year 
        (calculated as Year * 10 + (shiftedSeconds >> 16)).
        
    .PARAMETER VersionRevision
        An integer representing the low 16 bits of the shifted seconds.
        
    .EXAMPLE
        PS C:\> $result = Convert-64SecVersionComponentsToDateTime -VersionBuild 1 -VersionMajor 0 `
                  -VersionMinor 20250 -VersionRevision 1234
        PS C:\> $result
        Name                Value
        ----                -----
        VersionBuild        1
        VersionMajor        0
        ComputedDateTime    2025-06-15T12:34:56Z
    #>
    [CmdletBinding()]
    [alias("cdv64r")]
    param(
        [Parameter(Mandatory = $true)]
        [int]$VersionBuild,
        
        [Parameter(Mandatory = $true)]
        [int]$VersionMajor,
        
        [Parameter(Mandatory = $true)]
        [int]$VersionMinor,
        
        [Parameter(Mandatory = $true)]
        [int]$VersionRevision
    )

    # Extract the year from VersionMinor.
    # Since VersionMinor = (Year * 10) + HighPart, integer division by 10 yields the year.
    $year = [int]($VersionMinor / 10)

    # Calculate the high part by subtracting (Year * 10) from VersionMinor.
    $highPart = $VersionMinor - ($year * 10)

    # Reconstruct the shifted seconds: original shiftedSeconds = (HighPart << 16) + VersionRevision.
    $shiftedSeconds = ($highPart -shl 16) + $VersionRevision

    # Multiply the shifted seconds by 64 to recover the approximate elapsed seconds.
    $elapsedSeconds = $shiftedSeconds * 64

    # Define the start of the year in UTC.
    $startOfYear = [datetime]::new($year, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)

    # Compute the approximate DateTime.
    $computedDateTime = $startOfYear.AddSeconds($elapsedSeconds)

    return @{
        VersionBuild     = $VersionBuild;
        VersionMajor     = $VersionMajor;
        ComputedDateTime = $computedDateTime
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

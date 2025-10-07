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

function Get-ConfigValue {
<#
.SYNOPSIS
Return an existing value if provided; otherwise read a JSON file and return a property.

.DESCRIPTION
If -Check is non-empty, that value is returned (no file I/O). If -Check is null/empty,
the JSON file at -FilePath is parsed and the value at -Property (supports dotted paths)
is returned. Compatible with Windows PowerShell 5.x.

.PARAMETER Check
Existing value to prefer. If non-empty, it is returned as-is.

.PARAMETER FilePath
Path to the JSON secrets/config file.

.PARAMETER Property
Property name or dotted path within the JSON (e.g. "POWERSHELL_GALLERY" or "App.Settings.Token").

.EXAMPLE
$POWERSHELL_GALLERY = Get-ConfigValue -Check $POWERSHELL_GALLERY -FilePath (Join-Path $PSScriptRoot 'main_secrets.json') -Property 'POWERSHELL_GALLERY'

.OUTPUTS
[object]
#>
    [CmdletBinding()]
    [alias("gcv")]
    param(
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Check,

        [Parameter(Mandatory=$true)]
        [string]$FilePath,

        [Parameter(Mandatory=$true)]
        [string]$Property
    )

    # Fast path: if Check has a non-empty value, return it without touching disk.
    if ($PSBoundParameters.ContainsKey('Check') -and -not [string]::IsNullOrWhiteSpace($Check)) {
        return $Check
    }

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Get-ConfigValue: File not found: $FilePath"
    }

    $raw = Get-Content -LiteralPath $FilePath -Raw
    try {
        $obj = $raw | ConvertFrom-Json
    } catch {
        throw "Get-ConfigValue: Invalid JSON in file: $FilePath. $_"
    }

    $path = ($Property.Trim()).TrimStart('.')
    if ([string]::IsNullOrEmpty($path)) {
        throw "Get-ConfigValue: Property path is empty."
    }

    $current = $obj
    foreach ($segment in $path -split '\.') {
        if ($null -eq $current) { break }
        $prop = $current.PSObject.Properties[$segment]
        if ($null -eq $prop) {
            throw "Get-ConfigValue: Property not found: $segment (path: $Property)"
        }
        $current = $prop.Value
    }

    return $current
}

function Ensure-Variable {
    # Suppress the use of unapproved verb in function name
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
    <#
    .SYNOPSIS
    Ensures a variable meets conditions and displays its details.

    .DESCRIPTION
    Accepts a script block containing a simple variable reference (e.g. { $currentBranch }),
    extracts the variable's name from the AST, evaluates its value, and displays both in one line.
    The -HideValue switch suppresses the actual value by displaying "[Hidden]". When -ExitIfNullOrEmpty
    is specified, the function exits with code 1 if the variable's value is null, an empty string,
    or (in the case of a hashtable) empty.

    .PARAMETER Variable
    A script block that must contain a simple variable reference.

    .PARAMETER HideValue
    If specified, the displayed value will be replaced with "[Hidden]".

    .PARAMETER ExitIfNullOrEmpty
    If specified, the function exits with code 1 when the variable's value is null or empty.

    .EXAMPLE
    $currentBranch = "develop"
    Ensure-Variable -Variable { $currentBranch }
    # Output: Variable Name: currentBranch, Value: develop

    .EXAMPLE
    $currentBranch = ""
    Ensure-Variable -Variable { $currentBranch } -ExitIfNullOrEmpty
    # Outputs an error and exits with code 1.

    .EXAMPLE
    $myHash = @{ Key1 = "Value1"; Key2 = "Value2" }
    Ensure-Variable -Variable { $myHash }
    # Output: Variable Name: myHash, Value: {"Key1":"Value1","Key2":"Value2"}

    .NOTES
    The script block must contain a simple variable reference for the AST extraction to work correctly.
    #>
    [CmdletBinding()]
    [alias("ev")]
    param (
        [Parameter(Mandatory = $true)]
        [ScriptBlock]$Variable,
        
        [switch]$HideValue,
        
        [switch]$ExitIfNullOrEmpty
    )

    # Extract variable name from the script block's AST.
    $ast = $Variable.Ast
    $varAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
    if (-not $varAst) {
        Write-Error "The script block must contain a simple variable reference."
        return
    }
    $varName = $varAst.VariablePath.UserPath

    # Evaluate the script block to get the variable's value.
    $value = & $Variable

    # Check if the value is null or empty and exit if required.
    if ($ExitIfNullOrEmpty) {
        if ($null -eq $value) {
            Write-Error "Variable '$varName' is null."
            exit 1
        }
        if (($value -is [string]) -and [string]::IsNullOrEmpty($value)) {
            Write-Error "Variable '$varName' is an empty string."
            exit 1
        }
        if ($value -is [hashtable] -and ($value.Count -eq 0)) {
            Write-Error "Variable '$varName' is an empty hashtable."
            exit 1
        }
    }

    # Prepare the display value.
    if ($HideValue) {
        $displayValue = "[Hidden]"
    }
    else {
        if ($value -is [hashtable]) {
            # Convert the hashtable to a compact JSON string for one-line output.
            $displayValue = $value | ConvertTo-Json -Compress
        }
        else {
            $displayValue = $value
        }
    }

    Write-Output "Variable Name: $varName, Value: $displayValue"
}

function Get-RunEnvironment {
<#
.SYNOPSIS
Determines whether this PowerShell session runs locally or under a CI system (GitHub Actions, Azure Pipelines, Jenkins) and classifies hosted vs self-hosted when possible.

.DESCRIPTION
Uses well-known CI environment variables:
- GitHub Actions: GITHUB_ACTIONS=true (hosted images expose ImageOS/ImageVersion).
- Azure Pipelines: TF_BUILD=true; heuristics on AGENT_NAME / machine name to infer Microsoft-hosted vs self-hosted.
- Jenkins: JENKINS_URL / BUILD_ID.
Falls back to CI=true as “UnknownCI”.

.OUTPUTS
[pscustomobject] by default; optionally a Hashtable or a concise String via -As.

.PARAMETER As
Output shape. One of: Object (default), Hashtable, String.
[Mandatory: $false]

.EXAMPLE
Get-RunEnvironment
# -> Provider/Hosting/IsCI plus Details and Evidence.

.EXAMPLE
Get-RunEnvironment -As String
# -> "GitHubActions/Hosted (IsCI=True)"

.NOTES
Reviewer note: Host-type detection for Azure is heuristic by design; no single authoritative flag exists.
#>
    [CmdletBinding()]
    [alias("gre")]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Object','Hashtable','String')]
        [string]$As = 'Object'
    )

    # Build a mutable state with explicit fields.
    $state = [ordered]@{
        Provider = 'Local'
        Hosting  = 'N/A'
        IsCI     = $false
        Details  = [ordered]@{}
        Evidence = @()
    }

    # --- GitHub Actions ------------------------------------------------------
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $state.Provider = 'GitHubActions'
        $state.IsCI     = $true
        $state.Details['RunnerOS']   = $env:RUNNER_OS
        $state.Details['RunnerName'] = $env:RUNNER_NAME
        $isHosted = [bool]$env:ImageOS -or [bool]$env:ImageVersion
        $state.Hosting = if ($isHosted) { 'Hosted' } else { 'SelfHosted' }
        $state.Evidence += 'GITHUB_ACTIONS'
        if ($env:ImageOS)     { $state.Evidence += 'ImageOS' }
        if ($env:ImageVersion){ $state.Evidence += 'ImageVersion' }
    }
    # --- Azure Pipelines -----------------------------------------------------
    elseif (($env:TF_BUILD -as [string]) -match '^(?i:true)$' -or $env:AGENT_NAME -or $env:BUILD_BUILDID) {
        $state.Provider = 'AzurePipelines'
        $state.IsCI     = $true
        $state.Details['AgentName']       = $env:AGENT_NAME
        $state.Details['AgentOS']         = $env:AGENT_OS
        $state.Details['AgentMachineName']= $env:AGENT_MACHINENAME

        # Heuristic: Microsoft-hosted agents usually have Agent.Name like "Azure Pipelines <n>" or legacy "Hosted Agent",
        # and ephemeral VM names starting with "fv-az".
        $isHosted = ($env:AGENT_NAME -match '^(Azure Pipelines|Hosted Agent)') -or ($env:AGENT_MACHINENAME -like 'fv-az*')
        $state.Hosting = if ($isHosted) { 'Hosted' } else { 'SelfHosted' }

        foreach ($n in 'TF_BUILD','AGENT_NAME','BUILD_BUILDID','AGENT_MACHINENAME') {
            if (Test-Path "Env:\$n") { $state.Evidence += $n }
        }
    }
    # --- Jenkins -------------------------------------------------------------
    elseif ($env:JENKINS_URL -or $env:BUILD_ID) {
        $state.Provider = 'Jenkins'
        $state.IsCI     = $true
        $state.Details['NodeName'] = $env:NODE_NAME
        $state.Details['HasJenkinsUrl'] = [bool]$env:JENKINS_URL

        # Jenkins OSS is typically self-hosted. Mark hosted if URL hints a managed service (very rough).
        if ($env:JENKINS_URL -match '(cloudbees|jenkins\.io)') { $state.Hosting = 'Hosted' } else { $state.Hosting = 'SelfHosted' }

        foreach ($n in 'JENKINS_URL','BUILD_ID','NODE_NAME') {
            if (Test-Path "Env:\$n") { $state.Evidence += $n }
        }
    }
    # --- Unknown CI ----------------------------------------------------------
    elseif ($env:CI -eq 'true') {
        $state.Provider = 'UnknownCI'
        $state.IsCI     = $true
        $state.Hosting  = 'Unknown'
        $state.Evidence += 'CI'
    }

    switch ($As) {
        'String'    { "{0}/{1} (IsCI={2})" -f $state.Provider,$state.Hosting,$state.IsCI }
        'Hashtable' { [hashtable]$state }
        default     { [pscustomobject]@{
                        Provider = $state.Provider
                        Hosting  = $state.Hosting
                        IsCI     = $state.IsCI
                        Details  = [pscustomobject]$state.Details
                        Evidence = $state.Evidence
                      }
        }
    }
}



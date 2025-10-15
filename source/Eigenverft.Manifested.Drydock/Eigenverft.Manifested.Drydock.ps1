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
        IsLocal  = $true
        Details  = [ordered]@{}
        Evidence = @()
    }

    # --- GitHub Actions ------------------------------------------------------
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $state.Provider = 'GitHubActions'
        $state.IsCI     = $true
        $state.IsLocal  = $false
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
        $state.IsLocal  = $false
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
        $state.IsLocal  = $false        
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
        $state.IsLocal  = $false        
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
                        IsLocal  = $state.IsLocal
                        Details  = [pscustomobject]$state.Details
                        Evidence = $state.Evidence
                      }
        }
    }
}

function Drydock {
<#
.SYNOPSIS
Install Eigenverft.Manifested.Drydock from PSGallery.

.DESCRIPTION
Installs the module for the chosen scope. By default prerelease builds are allowed;
use -Stable to restrict to stable releases only.

.PARAMETER Stable
Install only stable versions (omits -AllowPrerelease).

.PARAMETER Scope
PowerShellGet install scope. Defaults to CurrentUser. Use AllUsers if elevated.

.EXAMPLE
Drydock
# Installs (allows prerelease) for CurrentUser.

.EXAMPLE
Drydock -Stable -Scope AllUsers
# Installs stable-only for all users (requires elevation).
#>
    [CmdletBinding()]
    param(
        [switch]$Stable,
        [ValidateSet('CurrentUser','AllUsers')]
        [string]$Scope = 'CurrentUser'
    )

    # Build arguments explicitly to keep the surface area minimal and PS5-safe.
    $cliargs = @(
        '-Name','Eigenverft.Manifested.Drydock',
        '-Repository','PSGallery',
        '-Scope', $Scope,
        '-Force',
        '-AllowClobber',
        '-ErrorAction','Stop'
    )

    if (-not $Stable) {
        # Allow prerelease unless caller requests stable-only.
        $cliargs += '-AllowPrerelease'
    }

    Install-Module @cliargs
}


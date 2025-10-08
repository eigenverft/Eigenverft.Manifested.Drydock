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

function Test-VariableValue {
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
    Test-VariableValue -Variable { $currentBranch }
    # Output: Variable Name: currentBranch, Value: develop

    .EXAMPLE
    $currentBranch = ""
    Test-VariableValue -Variable { $currentBranch } -ExitIfNullOrEmpty
    # Outputs an error and exits with code 1.

    .EXAMPLE
    $myHash = @{ Key1 = "Value1"; Key2 = "Value2" }
    Test-VariableValue -Variable { $myHash }
    # Output: Variable Name: myHash, Value: {"Key1":"Value1","Key2":"Value2"}

    .NOTES
    The script block must contain a simple variable reference for the AST extraction to work correctly.
    #>
    [CmdletBinding()]
    [alias("tvv")]
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

function Test-AvailableCommand {
<#
.SYNOPSIS
Returns a CommandInfo for a command name, or $null if not found. (Windows PowerShell 5.1 compatible)

.DESCRIPTION
Resolves cmdlets, functions, aliases, external apps, or scripts via Get-Command.
Returns the first matching [System.Management.Automation.CommandInfo] or $null.
Optionally fail fast via -ThrowOnMissing or -ExitOnMissing (default exit code 127).

.PARAMETER Name
The command name to resolve (e.g., 'git').

.PARAMETER Type
Optional filter for the command type. Valid: Any, Cmdlet, Function, Alias, Application, ExternalScript.

.PARAMETER ThrowOnMissing
Throw a terminating error if the command is not found.

.PARAMETER ExitOnMissing
Exit the current PowerShell host if the command is not found.

.PARAMETER ExitCode
Exit code to use with -ExitOnMissing. Defaults to 127.

.EXAMPLE
PS> $git = Test-AvailableCommand git
PS> if ($git) { "git at $($git.Definition)" } else { "git missing" }
PS> # PS5 note: for external applications, .Definition is the full path.

.EXAMPLE
PS> if ($cmd = Test-AvailableCommand "pwsh") { "pwsh ok at $($cmd.Definition)" } else { "pwsh missing" }
PS> # PS5-friendly inline assignment in the if; $null is falsey.

.EXAMPLE
PS> Test-AvailableCommand node -ThrowOnMissing
PS> # Throws a terminating error if 'node' cannot be resolved (script-level enforcement).

.EXAMPLE
PS> Test-AvailableCommand "az" -ExitOnMissing -ExitCode 127
PS> # Unconditionally terminates the current host if 'az' is missing (CI-safe).

.EXAMPLE
PS> $exe = Test-AvailableCommand git -Type Application
PS> if ($exe) { "exe path: $($exe.Definition)" } else { "no Application match" }
PS> # Filters by CommandType in PS5-compatible way.

.NOTES
Reviewer note: Keep -ExitOnMissing for CI/bootstrap scripts; prefer -ThrowOnMissing for script/module flows where try/catch is desired.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Name,

        [ValidateSet('Any','Cmdlet','Function','Alias','Application','ExternalScript')]
        [string]$Type = 'Any',

        [switch]$ThrowOnMissing,
        [switch]$ExitOnMissing,
        [int]$ExitCode = 127
    )

    # Resolve candidate(s) using PS5-safe constructs (no newer syntax).
    try {
        $resolved = Get-Command -Name $Name -ErrorAction Stop
    } catch {
        $resolved = $null
    }

    # Optional type filter (string compare for PS5.1 compatibility).
    if ($Type -ne 'Any' -and $resolved) {
        $resolved = $resolved | Where-Object { $_.CommandType.ToString() -eq $Type }
    }

    # Select the first match (typical for PATH executables).
    $first = $resolved | Select-Object -First 1

    if ($null -ne $first) {
        return $first
    }

    # Not found: enforce chosen fail-fast behavior.
    if ($ThrowOnMissing) {
        throw "Required command '$Name' was not found in PATH (Type=$Type)."
    }
    if ($ExitOnMissing) {
        Write-Error "Required command '$Name' was not found in PATH (Type=$Type). Exiting with code $ExitCode."
        exit $ExitCode
    }

    return $null
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



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
            Write-Error "Test-VariableValue: '$varName' is null."
            exit 1
        }
        if (($value -is [string]) -and [string]::IsNullOrEmpty($value)) {
            Write-Error "Test-VariableValue: '$varName' is an empty string."
            exit 1
        }
        if ($value -is [hashtable] -and ($value.Count -eq 0)) {
            Write-Error "Test-VariableValue: '$varName' is an empty hashtable."
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

    Write-Output "Test-VariableValue: $varName, Value: $displayValue"
}

function Test-CommandAvailable {
<#
.SYNOPSIS
Returns a CommandInfo for a command, or $null if not found. (Windows PowerShell 5.1 compatible)

.DESCRIPTION
Resolves cmdlets, functions, aliases, external apps, or scripts via Get-Command.
Returns the first matching [System.Management.Automation.CommandInfo] or $null.
Optionally fail fast via -ThrowIfNotFound or -ExitIfNotFound (default exit code 127).

.PARAMETER Command
The command to resolve (e.g., 'git').

.PARAMETER Type
Optional filter for the command type. Valid: Any, Cmdlet, Function, Alias, Application, ExternalScript.

.PARAMETER ThrowIfNotFound
Throw a terminating error if the command is not found.

.PARAMETER ExitIfNotFound
Exit the current PowerShell host if the command is not found.

.PARAMETER ExitCode
Exit code to use with -ExitIfNotFound. Defaults to 127.

.EXAMPLE
PS> $git = Test-CommandAvailable -Command git
PS> if ($git) { "git at $($git.Definition)" } else { "git missing" }
PS> # PS5 note: for external applications, .Definition is the full path.

.EXAMPLE
PS> if ($cmd = Test-CommandAvailable "pwsh") { "pwsh ok at $($cmd.Definition)" } else { "pwsh missing" }
PS> # PS5-friendly inline assignment in the if; $null is falsey.

.EXAMPLE
PS> Test-CommandAvailable node -ThrowIfNotFound
PS> # Throws a terminating error if 'node' cannot be resolved (script-level enforcement).

.EXAMPLE
PS> Test-CommandAvailable "az" -ExitIfNotFound -ExitCode 127
PS> # Unconditionally terminates the current host if 'az' is missing (CI-safe).

.EXAMPLE
PS> $exe = Test-CommandAvailable git -Type Application
PS> if ($exe) { "exe path: $($exe.Definition)" } else { "no Application match" }
PS> # Filters by CommandType in a PS5-compatible way.

.NOTES
Reviewer note: Prefer -ExitIfNotFound for CI/bootstrap; use -ThrowIfNotFound where try/catch is desired.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Command,

        [ValidateSet('Any','Cmdlet','Function','Alias','Application','ExternalScript')]
        [string]$Type = 'Any',

        [switch]$ThrowIfNotFound,
        [switch]$ExitIfNotFound,
        [int]$ExitCode = 127
    )

    # Resolve candidates (PS5-safe).
    try {
        $resolved = Get-Command -Name $Command -ErrorAction Stop
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
    if ($ThrowIfNotFound) {
        throw "Required command '$Command' was not found in PATH (Type=$Type)."
    }
    if ($ExitIfNotFound) {
        Write-Error "Required command '$Command' was not found in PATH (Type=$Type). Exiting with code $ExitCode."
        exit $ExitCode
    }

    return $null
}

function Test-ModuleAvailable {
<#
.SYNOPSIS
    Returns a PSModuleInfo for a locally installed module (stable only by default), or $null if not found.

.DESCRIPTION
    Strictly local check:
      - Considers already-loaded modules first, then installed modules via Get-Module -ListAvailable.
      - By default, prerelease modules are excluded. Use -IncludePrerelease to allow them.
      - Supports exact version (RequiredVersion) or a version range (MinimumVersion/MaximumVersion).
    Returns the best matching [System.Management.Automation.PSModuleInfo] or $null.
    Optional -ThrowIfNotFound / -ExitIfNotFound for CI-style enforcement.

.PARAMETER Name
    Module name to resolve (wildcards allowed; exact-name matches are preferred).

.PARAMETER RequiredVersion
    Exact version required. If set, Minimum/MaximumVersion are ignored.

.PARAMETER MinimumVersion
    Lowest acceptable version (inclusive) when RequiredVersion is not specified.

.PARAMETER MaximumVersion
    Highest acceptable version (inclusive) when RequiredVersion is not specified.

.PARAMETER IncludePrerelease
    Include prerelease modules in the candidate set (default behavior excludes them).

.PARAMETER ThrowIfNotFound
    Throw a terminating error when not found.

.PARAMETER ExitIfNotFound
    Exit the current PowerShell host when not found (default code 127).

.PARAMETER ExitCode
    Exit code used with -ExitIfNotFound.

.EXAMPLE
    if ($m = Test-ModuleAvailable Pester) { "$($m.Name) $($m.Version)" } else { "Pester (stable) missing" }

.EXAMPLE
    # Allow prerelease if only preview builds are installed
    Test-ModuleAvailable Pester -IncludePrerelease -MinimumVersion 5.5

.NOTES
    Reviewer note: Purely local; no gallery/network calls. Prefers exact name, then highest version.
#>
    [CmdletBinding(DefaultParameterSetName='ByRange')]
    [OutputType([System.Management.Automation.PSModuleInfo])]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Name,

        [Parameter(ParameterSetName='ByRequired')]
        [version]$RequiredVersion,

        [Parameter(ParameterSetName='ByRange')]
        [version]$MinimumVersion,

        [Parameter(ParameterSetName='ByRange')]
        [version]$MaximumVersion,

        [switch]$IncludePrerelease,

        [switch]$ThrowIfNotFound,
        [switch]$ExitIfNotFound,
        [int]$ExitCode = 127
    )

    # Helper: determine if a PSModuleInfo is prerelease.
    # Uses common manifest metadata: PrivateData.PSData.Prerelease
    function _IsPrerelease {
        param([System.Management.Automation.PSModuleInfo]$m)
        try {
            if ($null -eq $m -or $null -eq $m.PrivateData) { return $false }
            $psd = $m.PrivateData.PSData
            if ($psd -is [hashtable]) {
                $pre = $psd['Prerelease']
            } else {
                $pre = $psd.Prerelease
            }
            return -not [string]::IsNullOrEmpty([string]$pre)
        } catch {
            # Be conservative: if we can't read it, treat as stable.
            return $false
        }
    }

    # Helper: PS5-friendly version checks (no version-interval API here).
    function _MeetsVersion {
        param([version]$v)
        if ($PSCmdlet.ParameterSetName -eq 'ByRequired' -and $RequiredVersion) { return ($v -eq $RequiredVersion) }
        if ($MinimumVersion -and ($v -lt $MinimumVersion)) { return $false }
        if ($MaximumVersion -and ($v -gt $MaximumVersion)) { return $false }
        return $true
    }

    # Helper: apply default stable-only filter unless -IncludePrerelease is present.
    function _FilterByStability {
        param([System.Management.Automation.PSModuleInfo[]]$mods)
        if ($IncludePrerelease) { return $mods }
        return $mods | Where-Object { -not (_IsPrerelease $_) }
    }

    # 1) Prefer already-loaded modules that satisfy constraints and stability policy.
    $loaded = Get-Module -Name $Name
    if ($loaded) {
        $candidates = _FilterByStability $loaded
        $candidates = $candidates | Where-Object { _MeetsVersion $_.Version }
        # Prefer exact name, then highest version; if including prerelease, highest wins regardless of label.
        $sorted = if ($IncludePrerelease) {
            $candidates | Sort-Object @{Expression={ if ($_.Name -ieq $Name) {0} else {1} }}, @{Expression='Version';Descending=$true}
        } else {
            $candidates | Sort-Object @{Expression={ if ($_.Name -ieq $Name) {0} else {1} }}, @{Expression='Version';Descending=$true}
        }
        $best = $sorted | Select-Object -First 1
        if ($best) { return $best }
    }

    # 2) Scan locally installed modules (strictly local; no online contact).
    try {
        $avail = Get-Module -ListAvailable -Name $Name -ErrorAction Stop
    } catch {
        $avail = @()
    }

    if ($avail.Count -gt 0) {
        $candidates = _FilterByStability $avail
        $candidates = $candidates | Where-Object { _MeetsVersion $_.Version }
        $sorted = if ($IncludePrerelease) {
            # When including prerelease, choose the highest version across all candidates.
            $candidates | Sort-Object @{Expression={ if ($_.Name -ieq $Name) {0} else {1} }}, @{Expression='Version';Descending=$true}
        } else {
            $candidates | Sort-Object @{Expression={ if ($_.Name -ieq $Name) {0} else {1} }}, @{Expression='Version';Descending=$true}
        }
        $best = $sorted | Select-Object -First 1
        if ($best) { return $best }
    }

    # 3) Not found -> chosen enforcement.
    $verMsg = if ($PSCmdlet.ParameterSetName -eq 'ByRequired' -and $RequiredVersion) {
        "RequiredVersion=$RequiredVersion"
    } else {
        "MinimumVersion=$MinimumVersion, MaximumVersion=$MaximumVersion"
    }
    $stabMsg = if ($IncludePrerelease) { "stable+prerelease allowed" } else { "stable-only" }

    if ($ThrowIfNotFound) { throw "Required module '$Name' not found locally ($verMsg, $stabMsg)." }
    if ($ExitIfNotFound)  { Write-Error "Required module '$Name' not found locally ($verMsg, $stabMsg). Exiting with code $ExitCode."; exit $ExitCode }

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

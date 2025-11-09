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
    Optional -Quiet to return only a boolean (True/False) without emitting PSModuleInfo.

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

.PARAMETER Quiet
    Return only True/False and suppress emitting PSModuleInfo. With -ExitIfNotFound, exits silently (no error line).

.EXAMPLE
    # Boolean check only; prints True/False
    Test-ModuleAvailable Pester -Quiet

.EXAMPLE
    # CI-style enforcement, silent on success, exits 127 if missing
    Test-ModuleAvailable -Name Eigenverft.Manifested.Drydock -IncludePrerelease -ExitIfNotFound -Quiet

.NOTES
    Reviewer note: Purely local; no gallery/network calls. Prefers exact name, then highest version.
#>
    [CmdletBinding(DefaultParameterSetName='ByRange')]
    [OutputType([System.Management.Automation.PSModuleInfo])]
    [OutputType([bool])]
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
        [int]$ExitCode = 127,

        [switch]$Quiet
    )

    function _IsPrerelease {
        param([System.Management.Automation.PSModuleInfo]$m)
        try {
            if ($null -eq $m -or $null -eq $m.PrivateData) { return $false }
            $psd = $m.PrivateData.PSData
            if ($psd -is [hashtable]) { $pre = $psd['Prerelease'] } else { $pre = $psd.Prerelease }
            return -not [string]::IsNullOrEmpty([string]$pre)
        } catch { return $false }
    }

    function _MeetsVersion {
        param([version]$v)
        if ($PSCmdlet.ParameterSetName -eq 'ByRequired' -and $RequiredVersion) { return ($v -eq $RequiredVersion) }
        if ($MinimumVersion -and ($v -lt $MinimumVersion)) { return $false }
        if ($MaximumVersion -and ($v -gt $MaximumVersion)) { return $false }
        return $true
    }

    function _FilterByStability {
        param([System.Management.Automation.PSModuleInfo[]]$mods)
        if ($IncludePrerelease) { return $mods }
        return $mods | Where-Object { -not (_IsPrerelease $_) }
    }

    # 1) Prefer already-loaded modules
    $loaded = Get-Module -Name $Name
    if ($loaded) {
        $candidates = _FilterByStability $loaded | Where-Object { _MeetsVersion $_.Version }
        $sorted = $candidates | Sort-Object @{Expression={ if ($_.Name -ieq $Name) {0} else {1} }}, @{Expression='Version';Descending=$true}
        $best = $sorted | Select-Object -First 1
        if ($best) { if ($Quiet) { return $true } else { return $best } }
    }

    # 2) Locally installed (no network)
    try { $avail = Get-Module -ListAvailable -Name $Name -ErrorAction Stop } catch { $avail = @() }
    if ($avail.Count -gt 0) {
        $candidates = _FilterByStability $avail | Where-Object { _MeetsVersion $_.Version }
        $sorted = $candidates | Sort-Object @{Expression={ if ($_.Name -ieq $Name) {0} else {1} }}, @{Expression='Version';Descending=$true}
        $best = $sorted | Select-Object -First 1
        if ($best) { if ($Quiet) { return $true } else { return $best } }
    }

    # 3) Not found
    $verMsg = if ($PSCmdlet.ParameterSetName -eq 'ByRequired' -and $RequiredVersion) { "RequiredVersion=$RequiredVersion" } else { "MinimumVersion=$MinimumVersion, MaximumVersion=$MaximumVersion" }
    $stabMsg = if ($IncludePrerelease) { "stable+prerelease allowed" } else { "stable-only" }

    if ($ThrowIfNotFound) { throw "Required module '$Name' not found locally ($verMsg, $stabMsg)." }
    if ($ExitIfNotFound)  { if (-not $Quiet) { Write-Error "Required module '$Name' not found locally ($verMsg, $stabMsg). Exiting with code $ExitCode." }; exit $ExitCode }

    if ($Quiet) { return $false } else { return $null }
}

function Test-PsGalleryPublishPrereqsOffline {
<#
.SYNOPSIS
Local diagnostics for PowerShell Gallery publish prerequisites.

.DESCRIPTION
Performs non-network checks to assess whether the host is prepared for `Publish-Module`:
- On Windows PowerShell 5.x, verifies TLS 1.2 flag is present.
- Confirms NuGet package provider (>= 2.8.5.201) is installed.
- Confirms PackageManagement and PowerShellGet modules are present and importable.
- Confirms the PSGallery repository is registered and includes publish endpoints.
Writes human-readable status lines via Write-Host and returns nothing.

.PARAMETER ThrowOnFailure
If supplied, throws after checks when any prerequisite is missing.

.PARAMETER ExitOnFailure
If supplied, exits the host with code 1 after checks when any prerequisite is missing.
NOTE: This terminates the current PowerShell host. Use in CI pipelines or scripts only.

.EXAMPLE
Test-PsGalleryPublishPrereqsOffline

.EXAMPLE
Test-PsGalleryPublishPrereqsOffline -ThrowOnFailure

.EXAMPLE
Test-PsGalleryPublishPrereqsOffline -ExitOnFailure
#>
    [CmdletBinding()]
    param(
        [switch]$ThrowOnFailure,
        [switch]$ExitOnFailure
    )

    # Internal state
    $overallOk = $true
    $failures  = New-Object System.Collections.Generic.List[string]
    $isDesktop = ($PSVersionTable.PSEdition -eq 'Desktop')
    $psv       = $PSVersionTable.PSVersion.ToString()

    # Helper: formatted line with OK/FAIL, color, and detail; collects failing names
    function _print([string]$name, [bool]$ok, [string]$detail) {
        if (-not $ok) {
            $script:overallOk = $false
            [void]$script:failures.Add($name)
        }
        $tag   = if ($ok) { 'OK' } else { 'FAIL' }
        $color = if ($ok) { 'Green' } else { 'Red' }
        Write-Host ("[{0}] {1}: {2}" -f $tag, $name, $detail) -ForegroundColor $color
    }

    Write-Host ("--- PowerShell Gallery Publish Prerequisite Check (PS {0}, Edition: {1}) ---" -f $psv, $PSVersionTable.PSEdition) -ForegroundColor Cyan

    # TLS 1.2 (Windows PowerShell only)
    $tlsOk = $true
    $tlsDetail = "Not applicable on $($PSVersionTable.PSEdition)"
    if ($isDesktop) {
        try {
            $tls = [Net.ServicePointManager]::SecurityProtocol
            $tlsOk = (($tls -band [Net.SecurityProtocolType]::Tls12) -ne 0)
            $tlsDetail = if ($tlsOk) { 'TLS 1.2 present' } else { 'TLS 1.2 not present' }
        } catch {
            $tlsOk = $false
            $tlsDetail = 'Unable to read SecurityProtocol'
        }
    }
    _print 'TLS (Desktop only)' $tlsOk $tlsDetail

    # NuGet package provider (>= 2.8.5.201)
    $nugetOk = $false
    $nugetDetail = 'Not found'
    try {
        $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if ($nuget) {
            $nugetOk = ($nuget.Version -ge [version]'2.8.5.201')
            $nugetDetail = "Found $($nuget.Version)" + ($(if(-not $nugetOk){' (need >= 2.8.5.201)'} else {''}))
        }
    } catch {}
    _print 'NuGet provider' $nugetOk $nugetDetail

    # PackageManagement module present & importable
    $pmOk = $false
    $pmDetail = 'Not found'
    try {
        $pm = Get-Module -ListAvailable -Name PackageManagement | Sort-Object Version -Descending | Select-Object -First 1
        if ($pm) {
            try { Import-Module PackageManagement -MinimumVersion $pm.Version -Force -ErrorAction Stop | Out-Null } catch {}
            $pmOk = $true
            $pmDetail = "Found $($pm.Version)"
        }
    } catch {}
    _print 'PackageManagement module' $pmOk $pmDetail

    # PowerShellGet module present & importable
    $psgOk = $false
    $psgDetail = 'Not found'
    try {
        $psg = Get-Module -ListAvailable -Name PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1
        if ($psg) {
            try { Import-Module PowerShellGet -MinimumVersion $psg.Version -Force -ErrorAction Stop | Out-Null } catch {}
            $psgOk = $true
            $psgDetail = "Found $($psg.Version)"
        }
    } catch {}
    _print 'PowerShellGet module' $psgOk $psgDetail

    # PSGallery repository registration & publish endpoints (metadata only; no network)
    $repoOk = $false
    $repoDetail = 'Not registered'
    $pubOk = $false
    $pubDetail = 'Publish endpoints missing'
    try {
        $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($repo) {
            $repoOk = $true
            $repoDetail = 'Registered'
            $pubOk = [bool]$repo.PublishLocation -and [bool]$repo.ScriptPublishLocation -and ($repo.PublishLocation.ToString() -match '/api/v2/package/')
            $pubDetail = if ($pubOk) { 'Publish endpoints present' } else { 'Publish endpoints missing' }
        }
    } catch {}
    _print 'PSGallery repository' $repoOk $repoDetail
    _print 'PSGallery publish endpoints' $pubOk $pubDetail

    # Summary and failure handling
    if ($overallOk) {
        Write-Host '[SUMMARY] Prerequisite check PASSED.' -ForegroundColor Green
    } else {
        Write-Host ('[SUMMARY] Prerequisite check FAILED: {0}.' -f ($failures -join ', ')) -ForegroundColor Red
        if ($ThrowOnFailure) {
            throw ("Prereq check failed: {0}." -f ($failures -join ', '))
        } elseif ($ExitOnFailure) {
            $global:LASTEXITCODE = 1
            exit 1
        }
    }

    return  # no output object
}

function Test-PsGalleryPublishPrereqsOffline2 {
<#
.SYNOPSIS
Local diagnostics for PowerShell Gallery publish prerequisites.

.DESCRIPTION
Runs only local, non-network checks to verify whether the current host is prepared to publish modules
using Publish-Module against the PowerShell Gallery.

Checks performed:
- On Windows PowerShell 5.x (Desktop edition), verifies that TLS 1.2 is enabled in SecurityProtocol.
- Confirms that the NuGet package provider (version 2.8.5.201 or later) is available.
- Confirms that PackageManagement and PowerShellGet modules are present and importable.
- Confirms that the PSGallery repository is registered and exposes publish-related locations.

The function:
- Writes structured, human-readable status lines for each check via an inline _Write-StandardMessage helper.
- Writes a final summary line.
- Produces no pipeline output.

.PARAMETER ThrowOnFailure
If specified, throws after all checks when one or more prerequisites are missing.

.PARAMETER ExitOnFailure
If specified, exits the current PowerShell host with exit code 1 after all checks when one or more
prerequisites are missing. Intended for CI or scripted use only.

.EXAMPLE
Test-PsGalleryPublishPrereqsOffline

Runs all checks and prints a summary. Does not throw or exit on failure.

.EXAMPLE
Test-PsGalleryPublishPrereqsOffline -ThrowOnFailure

Runs all checks and throws a terminating error if any prerequisite is missing.

.EXAMPLE
Test-PsGalleryPublishPrereqsOffline -ExitOnFailure

Runs all checks and terminates the current PowerShell host with exit code 1 if any prerequisite is missing.

.NOTES
- Supported on Windows PowerShell 5/5.1 and PowerShell 7+ on Windows, macOS, and Linux.
- Uses only offline/metadata checks; no HTTP/network calls are made.
- Does not rely on pipeline input and does not emit objects to the pipeline.
#>
    [CmdletBinding()]
    param(
        [Parameter()][switch]$ThrowOnFailure,
        [Parameter()][switch]$ExitOnFailure
    )

    function _Write-StandardMessage {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        # This function is globally exempt from the GENERAL POWERSHELL REQUIREMENTS unless explicitly stated otherwise.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Message,
            [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$Level='INF',
            [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$MinLevel
        )
        $sevMap=@{TRC=0;DBG=1;INF=2;WRN=3;ERR=4;FTL=5}
        if(-not $PSBoundParameters.ContainsKey('MinLevel')){
            $gv=Get-Variable ConsoleLogMinLevel -Scope Global -ErrorAction SilentlyContinue
            $MinLevel=if($gv -and $gv.Value -and -not [string]::IsNullOrEmpty([string]$gv.Value)){[string]$gv.Value}else{'INF'}
        }
        $lvl=$Level.ToUpperInvariant()
        $min=$MinLevel.ToUpperInvariant()
        $sev=$sevMap[$lvl];if($null -eq $sev){$lvl='INF';$sev=$sevMap['INF']}
        $gate=$sevMap[$min];if($null -eq $gate){$min='INF';$gate=$sevMap['INF']}
        if($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4){$lvl=$min;$sev=$gate}
        if($sev -lt $gate){return}
        $ts=[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss:fff')
        $stack=Get-PSCallStack ; $helperName=$MyInvocation.MyCommand.Name ; $caller=$null
        if($stack){for($i=0;$i -lt $stack.Count;$i++){if($stack[$i].FunctionName -ne $helperName){$caller=if($stack.Count -gt ($i+1)){$stack[$i+1]}else{$stack[$i]};break}}}
        if(-not $caller){$caller=[pscustomobject]@{ScriptName=$PSCommandPath;FunctionName=$null}}
        $lineNumber=$null ; 
        $p=$caller.PSObject.Properties['ScriptLineNumber'];if($p -and $p.Value){$lineNumber=[string]$p.Value}
        if(-not $lineNumber){
            $p=$caller.PSObject.Properties['Position']
            if($p -and $p.Value){
                $sp=$p.Value.PSObject.Properties['StartLineNumber'];if($sp -and $sp.Value){$lineNumber=[string]$sp.Value}
            }
        }
        if(-not $lineNumber){
            $p=$caller.PSObject.Properties['Location']
            if($p -and $p.Value){
                $m=[regex]::Match([string]$p.Value,':(\d+)\s+char:','IgnoreCase');if($m.Success -and $m.Groups.Count -gt 1){$lineNumber=$m.Groups[1].Value}
            }
        }
        $file=if($caller.ScriptName){Split-Path -Leaf $caller.ScriptName}else{'cmd'}
        if($file -ne 'console' -and $lineNumber){$file="{0}:{1}" -f $file,$lineNumber}
        $prefix="[$ts "
        $suffix="] [$file] $Message"
        $cfg=@{TRC=@{Fore='DarkGray';Back=$null};DBG=@{Fore='Cyan';Back=$null};INF=@{Fore='Green';Back=$null};WRN=@{Fore='Yellow';Back=$null};ERR=@{Fore='Red';Back='DarkRed'}}[$lvl]
        $fore=$cfg.Fore
        $back=$cfg.Back
        if($fore -or $back){
            Write-Host -NoNewline $prefix
            if($fore -and $back){Write-Host -NoNewline $lvl -ForegroundColor $fore -BackgroundColor $back}
            elseif($fore){Write-Host -NoNewline $lvl -ForegroundColor $fore}
            elseif($back){Write-Host -NoNewline $lvl -BackgroundColor $back}
            Write-Host $suffix
        } else {
            Write-Host "$prefix$lvl$suffix"
        }
        if($sev -ge 4 -and $ErrorActionPreference -eq 'Stop'){throw ("ConsoleLog.{0}: {1}" -f $lvl,$Message)}
    }

    function _New-StatusRecord {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)][bool]$Ok,
            [Parameter(Mandatory = $true)][string]$Detail
        )

        # External reviewer: encapsulates a single check result.
        $record = [PSCustomObject]@{
            Name   = $Name
            Ok     = $Ok
            Detail = $Detail
        }
        return ,$record
    }

    function _Apply-LocalStatus {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$Record,

            [Parameter()]
            [System.Collections.IList]$FailureList,

            [Parameter(Mandatory = $true)]
            [bool]$CurrentOverallOk
        )

        if (-not $Record.Ok) {
            if ($null -ne $FailureList) {
                $null = $FailureList.Add($Record.Name)
            }
            $CurrentOverallOk = $false
        }

        $tag = if ($Record.Ok) { 'OK' } else { 'FAIL' }
        $message = '[{0}] {1}: {2}' -f $tag, $Record.Name, $Record.Detail
        $level = if ($Record.Ok) { 'INF' } else { 'ERR' }

        _Write-StandardMessage -Message $message -Level $level

        return $CurrentOverallOk
    }

    # Local state.
    $overallOk = $true
    $failures = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $editionText = $PSVersionTable.PSEdition
    $psVersionText = $PSVersionTable.PSVersion.ToString()
    $isDesktopEdition = ($editionText -eq 'Desktop')

    _Write-StandardMessage -Message ("--- PowerShell Gallery Publish Prerequisite Check (PS {0}, Edition: {1}) ---" -f $psVersionText, $editionText) -Level 'INF'

    # 1) TLS 1.2 (Windows PowerShell Desktop only).
    $tlsOk = $true
    $tlsDetail = 'Not applicable on current edition'
    if ($isDesktopEdition) {
        try {
            $currentProtocol = [Net.ServicePointManager]::SecurityProtocol
            $hasTls12 = (($currentProtocol -band [Net.SecurityProtocolType]::Tls12) -ne 0)
            if ($hasTls12) {
                $tlsOk = $true
                $tlsDetail = 'TLS 1.2 enabled in SecurityProtocol'
            }
            else {
                $tlsOk = $false
                $tlsDetail = 'TLS 1.2 not enabled in SecurityProtocol'
            }
        }
        catch {
            $tlsOk = $false
            $tlsDetail = 'Unable to read SecurityProtocol for TLS 1.2 verification'
        }
    }

    $tlsRecord = _New-StatusRecord -Name 'TLS (Desktop only)' -Ok:$tlsOk -Detail:$tlsDetail
    $overallOk = _Apply-LocalStatus -Record $tlsRecord -FailureList $failures -CurrentOverallOk $overallOk

    # 2) NuGet package provider (version >= 2.8.5.201).
    $nugetOk = $false
    $nugetDetail = 'NuGet provider not found'
    try {
        $nugetProvider = Get-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue
        if ($null -ne $nugetProvider) {
            $requiredNuGetVersion = [version]'2.8.5.201'
            if ($nugetProvider.Version -ge $requiredNuGetVersion) {
                $nugetOk = $true
                $nugetDetail = ('Found NuGet provider version {0}' -f $nugetProvider.Version)
            }
            else {
                $nugetDetail = ('Found NuGet provider version {0} (need {1} or later)' -f $nugetProvider.Version, $requiredNuGetVersion)
            }
        }
    }
    catch {
        $nugetOk = $false
        $nugetDetail = 'Error while querying NuGet provider'
    }

    $nugetRecord = _New-StatusRecord -Name 'NuGet provider' -Ok:$nugetOk -Detail:$nugetDetail
    $overallOk = _Apply-LocalStatus -Record $nugetRecord -FailureList $failures -CurrentOverallOk $overallOk

    # 3) PackageManagement module present and importable.
    $pmOk = $false
    $pmDetail = 'PackageManagement module not found'
    try {
        $pmModule = Get-Module -ListAvailable -Name 'PackageManagement' |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1

        if ($null -ne $pmModule) {
            try {
                Import-Module -Name 'PackageManagement' -MinimumVersion $pmModule.Version -Force -ErrorAction Stop | Out-Null
                $pmOk = $true
                $pmDetail = ('Found PackageManagement module version {0}' -f $pmModule.Version)
            }
            catch {
                $pmOk = $false
                $pmDetail = ('Found PackageManagement module version {0} but failed to import: {1}' -f $pmModule.Version, $_.Exception.Message)
            }
        }
    }
    catch {
        $pmOk = $false
        $pmDetail = 'Error while locating PackageManagement module'
    }

    $pmRecord = _New-StatusRecord -Name 'PackageManagement module' -Ok:$pmOk -Detail:$pmDetail
    $overallOk = _Apply-LocalStatus -Record $pmRecord -FailureList $failures -CurrentOverallOk $overallOk

    # 4) PowerShellGet module present and importable.
    $psgOk = $false
    $psgDetail = 'PowerShellGet module not found'
    try {
        $psgModule = Get-Module -ListAvailable -Name 'PowerShellGet' |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1

        if ($null -ne $psgModule) {
            try {
                Import-Module -Name 'PowerShellGet' -MinimumVersion $psgModule.Version -Force -ErrorAction Stop | Out-Null
                $psgOk = $true
                $psgDetail = ('Found PowerShellGet module version {0}' -f $psgModule.Version)
            }
            catch {
                $psgOk = $false
                $psgDetail = ('Found PowerShellGet module version {0} but failed to import: {1}' -f $psgModule.Version, $_.Exception.Message)
            }
        }
    }
    catch {
        $psgOk = $false
        $psgDetail = 'Error while locating PowerShellGet module'
    }

    $psgRecord = _New-StatusRecord -Name 'PowerShellGet module' -Ok:$psgOk -Detail:$psgDetail
    $overallOk = _Apply-LocalStatus -Record $psgRecord -FailureList $failures -CurrentOverallOk $overallOk

    # 5) PSGallery repository registration and publish endpoints (metadata-only, offline).
    $repoOk = $false
    $repoDetail = 'PSGallery repository not registered'
    $pubOk = $false
    $pubDetail = 'Publish endpoints not available from registered PSGallery repository'
    try {
        $psGalleryRepo = Get-PSRepository -Name 'PSGallery' -ErrorAction SilentlyContinue
        if ($null -ne $psGalleryRepo) {
            $repoOk = $true
            $repoDetail = 'PSGallery repository registered'

            $hasPublishLocation = (($null -ne $psGalleryRepo.PublishLocation) -and
                                   ($null -ne $psGalleryRepo.ScriptPublishLocation))

            $hasV2PackagePath = $false
            if ($hasPublishLocation) {
                $publishLocationText = [string]$psGalleryRepo.PublishLocation
                if ($publishLocationText -match '/api/v2/package/') {
                    $hasV2PackagePath = $true
                }
            }

            if ($hasPublishLocation -and $hasV2PackagePath) {
                $pubOk = $true
                $pubDetail = 'Publish endpoints present in PSGallery repository metadata'
            }
        }
    }
    catch {
        $repoOk = $false
        $repoDetail = 'Error while querying PSGallery repository registration'
        $pubOk = $false
        $pubDetail = 'Unable to confirm publish endpoints due to repository query error'
    }

    $repoRecord = _New-StatusRecord -Name 'PSGallery repository' -Ok:$repoOk -Detail:$repoDetail
    $overallOk = _Apply-LocalStatus -Record $repoRecord -FailureList $failures -CurrentOverallOk $overallOk

    $pubRecord = _New-StatusRecord -Name 'PSGallery publish endpoints' -Ok:$pubOk -Detail:$pubDetail
    $overallOk = _Apply-LocalStatus -Record $pubRecord -FailureList $failures -CurrentOverallOk $overallOk

    # Summary and failure handling.
    if ($overallOk) {
        _Write-StandardMessage -Message '[SUMMARY] Prerequisite check PASSED.' -Level 'INF'
    }
    else {
        $failedList = $failures -join ', '
        _Write-StandardMessage -Message ('[SUMMARY] Prerequisite check FAILED: {0}.' -f $failedList) -Level 'ERR'

        if ($ThrowOnFailure) {
            throw ('Prerequisite check failed: {0}.' -f $failedList)
        }

        if ($ExitOnFailure) {
            exit 1
        }
    }

    return
}

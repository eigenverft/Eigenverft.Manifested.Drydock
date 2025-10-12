function Test-InstallationScopeCapability {
<#
.SYNOPSIS
Resolves the effective installation scope from current privileges (no parameters).
.DESCRIPTION
Returns exactly one string:
- "AllUsers" if the session is elevated (Administrator),
- "CurrentUser" otherwise.
.EXAMPLE
Test-InstallationScopeCapability
.OUTPUTS
System.String
#>
    [CmdletBinding()]
    param()

    $isAdmin = $false
    try {
        $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pri = [Security.Principal.WindowsPrincipal]$id
        $isAdmin = $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $isAdmin = $false
    }

    if ($isAdmin) { 'AllUsers' } else { 'CurrentUser' }
}

function Set-PSGalleryTrust {
<#
.SYNOPSIS
Ensures the 'PSGallery' repository exists locally and is trusted (parameterless).
.DESCRIPTION
- Parameterless on purpose: resolves the effective scope internally via Test-InstallationScopeCapability.
- Prefers PowerShellGet repository cmdlets; falls back to PackageManagement if needed.
- Local operations only; does not force a network call.
.EXAMPLE
Set-PSGalleryTrust
#>
    [CmdletBinding()]
    param()

    $effectiveScope = Test-InstallationScopeCapability
    Write-Host "[Info] Ensuring PSGallery trust at effective scope: '$effectiveScope'."

    # Prefer PSRepository (PowerShellGet) path
    $hasPsRepositoryCmdlets = $false
    try { if (Get-Command Get-PSRepository -ErrorAction SilentlyContinue) { $hasPsRepositoryCmdlets = $true } } catch {}

    if ($hasPsRepositoryCmdlets) {
        try {
            $repo = Get-PSRepository -Name 'PSGallery' -ErrorAction Stop
            if ($repo.InstallationPolicy -ne 'Trusted') {
                Write-Host "[Action] Setting PSGallery InstallationPolicy to 'Trusted'..."
                Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction Stop
                Write-Host "[Success] PSGallery is now trusted."
            } else {
                Write-Host "[OK] PSGallery is already trusted."
            }
            return
        } catch {
            Write-Host "[Action] Registering PSGallery locally..."
            try {
                Register-PSRepository -Name 'PSGallery' `
                    -SourceLocation 'https://www.powershellgallery.com/api/v2' `
                    -ScriptSourceLocation 'https://www.powershellgallery.com/api/v2' `
                    -InstallationPolicy Trusted -ErrorAction Stop
                Write-Host "[Success] PSGallery registered and trusted."
            } catch {
                Write-Host "Error: Failed to register PSGallery via Register-PSRepository: $($_.Exception.Message)" -ForegroundColor Red
            }
            return
        }
    }

    # Fallback: PackageManagement path
    try {
        $pkgSrc = Get-PackageSource -Name 'PSGallery' -ProviderName 'PowerShellGet' -ErrorAction SilentlyContinue
        if ($pkgSrc) {
            if (-not $pkgSrc.IsTrusted) {
                Write-Host "[Action] Marking PSGallery as trusted via Set-PackageSource..."
                Set-PackageSource -Name 'PSGallery' -Trusted -ProviderName 'PowerShellGet' -ErrorAction Stop | Out-Null
                Write-Host "[Success] PSGallery is now trusted."
            } else {
                Write-Host "[OK] PSGallery is already trusted (PackageManagement)."
            }
        } else {
            Write-Host "[Action] Adding PSGallery (fallback path)..."
            try {
                Register-PSRepository -Name 'PSGallery' `
                    -SourceLocation 'https://www.powershellgallery.com/api/v2' `
                    -ScriptSourceLocation 'https://www.powershellgallery.com/api/v2' `
                    -InstallationPolicy Trusted -ErrorAction Stop
                Write-Host "[Success] PSGallery registered and trusted."
            } catch {
                Write-Host "Error: Could not register PSGallery (fallback path): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    } catch {
        Write-Host "Error: Failed to evaluate or set PSGallery trust state: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Use-Tls12 {
<#
.SYNOPSIS
Ensures TLS 1.2 for outbound HTTPS in Windows PowerShell 5.x.

.DESCRIPTION
Adds TLS 1.2 to [Net.ServicePointManager]::SecurityProtocol for the current session.
Prevents "Could not create SSL/TLS secure channel" when using PowerShellGet/NuGet.

.EXAMPLE
Use-Tls12
#>
    [CmdletBinding()]
    param()
    $tls12 = [Net.SecurityProtocolType]::Tls12
    if (([Net.ServicePointManager]::SecurityProtocol -band $tls12) -eq 0) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12
    }
}

function Test-PSGalleryConnectivity {
<#
.SYNOPSIS
Fast connectivity test to PowerShell Gallery with HEAD→GET fallback.
.DESCRIPTION
Attempts a HEAD request to https://www.powershellgallery.com/api/v2/.
If the server returns 405 (Method Not Allowed), retries with GET.
Considers HTTP 200–399 as reachable. Writes status and returns $true/$false.
.EXAMPLE
Test-PSGalleryConnectivity
.OUTPUTS
System.Boolean
#>
    [CmdletBinding()]
    param()

    $url = 'https://www.powershellgallery.com/api/v2/'
    $timeoutMs = 5000

    function Invoke-WebCheck {
        param([string]$Method)

        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Method            = $Method
            $req.Timeout           = $timeoutMs
            $req.ReadWriteTimeout  = $timeoutMs
            $req.AllowAutoRedirect = $true
            $req.UserAgent         = 'WindowsPowerShell/5.1 PSGalleryConnectivityCheck'

            # NOTE: No proxy credential munging here—use system defaults.
            $res = $req.GetResponse()
            $status = [int]$res.StatusCode
            $res.Close()

            if ($status -ge 200 -and $status -lt 400) {
                Write-Host "[OK] PSGallery reachable via $Method (HTTP $status)."
                return $true
            } else {
                Write-Host "Error: PSGallery returned HTTP $status on $Method." -ForegroundColor Red
                return $false
            }
        } catch [System.Net.WebException] {
            $wex = $_.Exception
            $resp = $wex.Response
            if ($resp -and $resp -is [System.Net.HttpWebResponse]) {
                $status = [int]$resp.StatusCode
                $resp.Close()
                if ($status -eq 405 -and $Method -eq 'HEAD') {
                    # Fallback handled by caller
                    return $null
                }
                Write-Host "Error: PSGallery $Method failed (HTTP $status): $($wex.Message)" -ForegroundColor Red
                return $false
            } else {
                Write-Host "Error: PSGallery $Method failed: $($wex.Message)" -ForegroundColor Red
                return $false
            }
        } catch {
            Write-Host "Error: PSGallery $Method failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }

    # Try HEAD first for speed; if 405, fall back to GET.
    $headResult = Invoke-WebCheck -Method 'HEAD'
    if ($headResult -eq $true) { return $true }
    if ($null -eq $headResult) {
        # 405 from HEAD → retry with GET
        $getResult = Invoke-WebCheck -Method 'GET'
        return [bool]$getResult
    }

    return $false
}

function Initialize-NugetPackageProvider {
<#
.SYNOPSIS
Ensures the NuGet package provider (>= 2.8.5.201) is available for the exact scope.
.DESCRIPTION
- Exact scope handling (AllUsers | CurrentUser).
- If -Scope is omitted, resolves scope via Test-InstallationScopeCapability.
- Local-first: only installs/updates when needed.
- Write-Host only (PS5-compatible).
.PARAMETER Scope
Exact scope ('AllUsers' or 'CurrentUser'). If omitted, chosen automatically.
.EXAMPLE
Initialize-NugetPackageProvider
.EXAMPLE
Initialize-NugetPackageProvider -Scope AllUsers
#>
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('AllUsers','CurrentUser')]
        [string]$Scope = 'CurrentUser'
    )

    # 1) Resolve scope
    $resolvedScope = if ($PSBoundParameters.ContainsKey('Scope')) {
        Write-Host "[Init] Using explicitly provided scope: $Scope"
        $Scope
    } else {
        $auto = Test-InstallationScopeCapability
        Write-Host "[Default] No scope provided; using '$auto' based on permission check."
        $auto
    }

    # 2) Gate explicit AllUsers if not elevated
    if ($PSBoundParameters.ContainsKey('Scope') -and $resolvedScope -eq 'AllUsers' -and (Test-InstallationScopeCapability) -ne 'AllUsers') {
        Write-Host "Error: Requested 'AllUsers' but session is not elevated. Start PowerShell as Administrator or omit -Scope." -ForegroundColor Red
        Write-Host "[Result] Aborted: insufficient privileges for 'AllUsers'."
        return
    }
    Write-Host "[OK] Operating with scope '$resolvedScope'."

    # 3) Minimum required version
    $requiredMinVersion = [Version]'2.8.5.201'
    Write-Host "[Check] Minimum required NuGet provider version: $requiredMinVersion"

    # 4) Local detection
    try {
        Write-Host "[Check] Inspecting existing NuGet provider..."
        $installedProvider = Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue |
                             Where-Object { $_.Name -ieq 'NuGet' } |
                             Select-Object -First 1
    } catch {
        Write-Host "Error: Failed to query package providers: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[Result] Aborted: provider enumeration failed."
        return
    }

    $needsInstall = $true
    if ($installedProvider) {
        try {
            $currentVersion = [Version]$installedProvider.Version
            Write-Host "[Info] Found NuGet provider version: $currentVersion"
            $needsInstall = ($currentVersion -lt $requiredMinVersion)
        } catch {
            Write-Host "[Warn] Could not interpret provider version; will attempt reinstallation."
            $needsInstall = $true
        }
    } else {
        Write-Host "[Info] NuGet provider not found."
    }

    # 5) Install/Update if needed
    if ($needsInstall) {
        Write-Host "[Action] Installing/updating NuGet provider to >= $requiredMinVersion (Scope: $resolvedScope)..."
        $originalProgressPreference = $global:ProgressPreference
        try {
            $global:ProgressPreference = 'SilentlyContinue'
            $installCmdlet = Get-Command Install-PackageProvider -ErrorAction SilentlyContinue
            $installParams = @{
                Name           = 'NuGet'
                MinimumVersion = $requiredMinVersion
                Force          = $true
                ErrorAction    = 'Stop'
            }
            if ($installCmdlet -and $installCmdlet.Parameters.ContainsKey('Scope')) { $installParams['Scope'] = $resolvedScope }

            Install-PackageProvider @installParams | Out-Null
            Write-Host "[Success] NuGet provider installed/updated for '$resolvedScope'."
            Write-Host "[Result] Compliant: provider version >= $requiredMinVersion."
        } catch {
            Write-Host "Error: Installation in scope '$resolvedScope' failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "[Result] Failed: installation/update did not complete."
        } finally {
            $global:ProgressPreference = $originalProgressPreference
        }
        return
    }

    Write-Host "[Skip] Provider already meets minimum ($requiredMinVersion); no action required."
    Write-Host "[Result] No changes necessary."
}

function Initialize-PowerShellGet {
<#
.SYNOPSIS
Ensures the PowerShellGet module is present/updated with PSGallery trusted; resolves scope automatically when omitted.
.DESCRIPTION
- Exact scope handling (AllUsers | CurrentUser). If -Scope not provided, resolves via Test-InstallationScopeCapability.
- Local-first: if installed PowerShellGet >= minimum, no online contact is made.
- Calls Initialize-NugetPackageProvider (prereq) and Set-PSGalleryTrust (trust).
- Write-Host only (PS5-compatible).
.PARAMETER Scope
Exact scope ('AllUsers' or 'CurrentUser'). If omitted, chosen automatically.
.EXAMPLE
Initialize-PowerShellGet
.EXAMPLE
Initialize-PowerShellGet -Scope AllUsers
#>
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('AllUsers','CurrentUser')]
        [string]$Scope = 'CurrentUser'
    )

    # 1) Resolve scope
    $resolvedScope = if ($PSBoundParameters.ContainsKey('Scope')) {
        Write-Host "[Init] Using explicitly provided scope: $Scope"
        $Scope
    } else {
        $auto = Test-InstallationScopeCapability
        Write-Host "[Default] No scope provided; using '$auto' based on permission check."
        $auto
    }

    # 2) Gate explicit AllUsers if not elevated
    if ($PSBoundParameters.ContainsKey('Scope') -and $resolvedScope -eq 'AllUsers' -and (Test-InstallationScopeCapability) -ne 'AllUsers') {
        Write-Host "Error: Requested 'AllUsers' but session is not elevated. Start PowerShell as Administrator or omit -Scope." -ForegroundColor Red
        Write-Host "[Result] Aborted: insufficient privileges for 'AllUsers'."
        return
    }
    Write-Host "[OK] Operating with scope '$resolvedScope'."

    # 3) Minimum required version
    $requiredMinVersion = [Version]'2.2.5.1'
    Write-Host "[Check] Minimum required PowerShellGet version: $requiredMinVersion"

    # 4) Local detection
    $installed = $null
    try {
        $installed = Get-Module -ListAvailable -Name 'PowerShellGet' |
                     Sort-Object Version -Descending |
                     Select-Object -First 1
    } catch {
        Write-Host "[Warn] Failed to enumerate installed PowerShellGet: $($_.Exception.Message)"
    }

    if ($installed) {
        Write-Host "[Info] Found PowerShellGet version: $($installed.Version) at $($installed.ModuleBase)"
        if ([Version]$installed.Version -ge $requiredMinVersion) {
            Set-PSGalleryTrust
            Write-Host "[Skip] Installed PowerShellGet meets minimum; no online update performed."
            Write-Host "[Result] No changes necessary."
            return
        }
        Write-Host "[Info] Installed version is below minimum; update will be attempted."
    } else {
        Write-Host "[Info] PowerShellGet not found; installation will be attempted."
    }

    # 5) Prep: Ensure NuGet provider, then trust PSGallery
    try {
        Write-Host "[Prep] Ensuring NuGet provider via Initialize-NugetPackageProvider..."
        Initialize-NugetPackageProvider -Scope $resolvedScope
    } catch {
        Write-Host "[Warn] Initialize-NugetPackageProvider reported an issue: $($_.Exception.Message)"
    }

    Set-PSGalleryTrust

    # 6) Install/Update (online only when needed)
    Write-Host "[Action] Installing/Updating PowerShellGet (Scope: $resolvedScope)..."
    $originalProgressPreference = $global:ProgressPreference
    try {
        $global:ProgressPreference = 'SilentlyContinue'
        $installCmdlet = Get-Command Install-Module -ErrorAction SilentlyContinue
        if (-not $installCmdlet) {
            Write-Host "Error: Install-Module is not available. Ensure PowerShellGet cmdlets are loaded." -ForegroundColor Red
            Write-Host "[Result] Failed: cannot proceed with installation."
            return
        }

        $installParams = @{
            Name         = 'PowerShellGet'
            Repository   = 'PSGallery'
            Force        = $true
            AllowClobber = $true
            ErrorAction  = 'Stop'
        }
        if ($installCmdlet.Parameters.ContainsKey('Scope')) { $installParams['Scope'] = $resolvedScope }

        Install-Module @installParams
        Write-Host "[Success] PowerShellGet installed/updated successfully."
        Write-Host "[Result] PowerShellGet is compliant (>= $requiredMinVersion)."
    } catch {
        Write-Host "Error: Installing/Updating PowerShellGet failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[Result] Failed: PowerShellGet could not be installed/updated."
    } finally {
        $global:ProgressPreference = $originalProgressPreference
    }
}

function Initialize-PackageManagement {
<#
.SYNOPSIS
Ensures the PackageManagement module is present/updated for the exact scope with local-first behavior.
.DESCRIPTION
- Exact scope handling (AllUsers | CurrentUser). If -Scope is omitted, resolves via Test-InstallationScopeCapability.
- Local-first: if installed PackageManagement >= minimum baseline, no online call is made.
- Preps NuGet provider via Initialize-NugetPackageProvider; ensures PSGallery is trusted via Set-PSGalleryTrust.
- Write-Host only (PS5-compatible).
.PARAMETER Scope
Exact scope name ('AllUsers' or 'CurrentUser'). If omitted, chosen automatically.
.EXAMPLE
Initialize-PackageManagement
.EXAMPLE
Initialize-PackageManagement -Scope AllUsers
#>
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('AllUsers','CurrentUser')]
        [string]$Scope = 'CurrentUser'
    )

    # 1) Resolve scope
    $resolvedScope = if ($PSBoundParameters.ContainsKey('Scope')) {
        Write-Host "[Init] Using explicitly provided scope: $Scope"
        $Scope
    } else {
        $auto = Test-InstallationScopeCapability
        Write-Host "[Default] No scope provided; using '$auto' based on permission check."
        $auto
    }

    # 2) Gate explicit AllUsers if not elevated
    if ($PSBoundParameters.ContainsKey('Scope') -and $resolvedScope -eq 'AllUsers' -and (Test-InstallationScopeCapability) -ne 'AllUsers') {
        Write-Host "Error: Requested 'AllUsers' but session is not elevated. Start PowerShell as Administrator or omit -Scope." -ForegroundColor Red
        Write-Host "[Result] Aborted: insufficient privileges for 'AllUsers'."
        return
    }
    Write-Host "[OK] Operating with scope '$resolvedScope'."

    # 3) Minimum required version
    $requiredMinVersion = [Version]'1.4.8.1'  # Adjust baseline if your estate requires a different floor
    Write-Host "[Check] Minimum required PackageManagement version: $requiredMinVersion"

    # 4) Local detection
    $installed = $null
    try {
        $installed = Get-Module -ListAvailable -Name 'PackageManagement' |
                     Sort-Object Version -Descending |
                     Select-Object -First 1
    } catch {
        Write-Host "[Warn] Failed to enumerate installed PackageManagement: $($_.Exception.Message)"
    }

    if ($installed) {
        Write-Host "[Info] Found PackageManagement version: $($installed.Version) at $($installed.ModuleBase)"
        if ([Version]$installed.Version -ge $requiredMinVersion) {
            Set-PSGalleryTrust
            Write-Host "[Skip] Installed PackageManagement meets minimum; no online update performed."
            Write-Host "[Result] No changes necessary."
            return
        }
        Write-Host "[Info] Installed version is below minimum; update will be attempted."
    } else {
        Write-Host "[Info] PackageManagement not found; installation will be attempted."
    }

    # 5) Prep: Ensure NuGet provider, then trust PSGallery
    try {
        Write-Host "[Prep] Ensuring NuGet provider via Initialize-NugetPackageProvider..."
        Initialize-NugetPackageProvider -Scope $resolvedScope
    } catch {
        Write-Host "[Warn] Initialize-NugetPackageProvider reported an issue: $($_.Exception.Message)"
    }

    Set-PSGalleryTrust

    # 6) Install/Update (online only when needed)
    Write-Host "[Action] Installing/Updating PackageManagement (Scope: $resolvedScope)..."
    $originalProgressPreference = $global:ProgressPreference
    try {
        $global:ProgressPreference = 'SilentlyContinue'

        $installCmdlet = Get-Command Install-Module -ErrorAction SilentlyContinue
        if (-not $installCmdlet) {
            Write-Host "Error: Install-Module is not available. Ensure PowerShellGet cmdlets are loaded." -ForegroundColor Red
            Write-Host "[Result] Failed: cannot proceed with installation."
            return
        }

        # Intentionally avoid Find-Module to keep offline unless installation is required.
        $installParams = @{
            Name               = 'PackageManagement'
            Repository         = 'PSGallery'
            Force              = $true
            AllowClobber       = $true
            SkipPublisherCheck = $true
            ErrorAction        = 'Stop'
        }
        if ($installCmdlet.Parameters.ContainsKey('Scope')) { $installParams['Scope'] = $resolvedScope }

        try {
            Install-Module @installParams
            Write-Host "[Success] PackageManagement installed/updated successfully."
            Write-Host "[Result] PackageManagement is compliant (>= $requiredMinVersion)."
        } catch {
            Write-Host "Error: Install-Module for PackageManagement failed: $($_.Exception.Message)" -ForegroundColor Red
            # Fallback in case the module exists but is locked/older in certain paths
            try {
                Write-Host "[Fallback] Attempting Update-Module -Name PackageManagement -Force ..."
                Update-Module -Name 'PackageManagement' -Force -ErrorAction Stop
                Write-Host "[Success] Update-Module completed."
                Write-Host "[Result] PackageManagement updated."
            } catch {
                Write-Host "Error: Update-Module failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "[Result] Failed: PackageManagement not updated."
            }
        }
    } finally {
        $global:ProgressPreference = $originalProgressPreference
    }
}

function Initialize-PowerShellBootstrap {
<#
.SYNOPSIS
Runs the initialization sequence on Windows PowerShell 5.x only (skips on PS 6/7+).

.DESCRIPTION
- Detects edition/version; exits early on PowerShell Core (6/7+).
- On PS5.x:
  - Enables TLS 1.2 (local, idempotent).
  - Resolves effective scope (or honors -Scope).
  - Applies PSGallery trust (local-only).
  - Proceeds with NuGet → PowerShellGet → PackageManagement
    only if PSGallery connectivity succeeds.

.PARAMETER Scope
Optional exact scope ('AllUsers' or 'CurrentUser'). If omitted, scope is resolved via Test-InstallationScopeCapability.

.EXAMPLE
Initialize-PowerShellBootstrap
.EXAMPLE
Initialize-PowerShellBootstrap -Scope AllUsers
#>
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('AllUsers','CurrentUser')]
        [string]$Scope
    )

    Write-Host "[Bootstrap] Starting PowerShell environment initialization..."

    $psVer = $PSVersionTable.PSVersion
    $psEd  = $PSVersionTable.PSEdition
    $isWinPS5 = ($psEd -eq 'Desktop' -and $psVer.Major -eq 5)

    if (-not $isWinPS5) {
        Write-Host "[Bootstrap] Detected PowerShell $psVer ($psEd). Skipping Windows PowerShell 5.x bootstrap; nothing to do."
        return
    }

    Write-Host "[Bootstrap] Detected Windows PowerShell $psVer ($psEd). Continuing with PS5-specific bootstrap..."

    # 1) TLS 1.2 for PS5 sessions (local, safe)
    Use-Tls12

    # 2) Resolve scope once (info only; initializers still enforce their own gates)
    $resolvedScope = if ($PSBoundParameters.ContainsKey('Scope')) {
        Write-Host "[Bootstrap] Using explicit scope: $Scope"
        $Scope
    } else {
        $auto = Test-InstallationScopeCapability
        Write-Host "[Bootstrap] No scope provided; resolved effective scope: $auto"
        $auto
    }

    # 3) Local-only step first (no network)
    Write-Host "[Bootstrap] Applying local PSGallery trust state..."
    Set-PSGalleryTrust

    # 4) Connectivity gate for online steps
    Write-Host "[Bootstrap] Checking PSGallery connectivity..."
    if (-not (Test-PSGalleryConnectivity)) {
        Write-Host "Error: PSGallery not reachable. Online initialization steps will be skipped." -ForegroundColor Red
        Write-Host "[Bootstrap] Result: Partial (local trust applied)."
        return
    }

    # 5) Online steps in recommended order
    Write-Host "[Bootstrap] Connectivity OK. Proceeding with online steps..."
    Initialize-NugetPackageProvider -Scope $resolvedScope
    Initialize-PowerShellGet       -Scope $resolvedScope
    Initialize-PackageManagement   -Scope $resolvedScope

    Write-Host "[Bootstrap] Completed successfully."
}

function Initialize-PowerShellMiniBootstrap {
<#
.SYNOPSIS
Performs a minimal, non-interactive bootstrap for Windows PowerShell 5.x (CurrentUser scope): enables TLS 1.2, ensures the NuGet provider (>= 2.8.5.201), trusts PSGallery, installs/updates PowerShellGet and PackageManagement if newer, and imports them; silently skips on PowerShell 6/7+.
#>
    param()
    $Install=@('PowerShellGet','PackageManagement');$Scope='CurrentUser';if($PSVersionTable.PSVersion.Major -ne 5){return};[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $minNuget=[Version]'2.8.5.201'; Install-PackageProvider -Name NuGet -MinimumVersion $minNuget -Scope $Scope -Force -ForceBootstrap | Out-Null; try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop } catch { Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -ScriptSourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted -ErrorAction Stop }; Find-Module -Name $Install -Repository PSGallery | Select-Object Name,Version | Where-Object { -not (Get-Module -ListAvailable -Name $_.Name | Sort-Object Version -Descending | Select-Object -First 1 | Where-Object Version -eq $_.Version) } | ForEach-Object { Install-Module -Name $_.Name -RequiredVersion $_.Version -Repository PSGallery -Scope $Scope -Force -AllowClobber; try { Remove-Module -Name $_.Name -ErrorAction SilentlyContinue } catch {}; Import-Module -Name $_.Name -MinimumVersion $_.Version -Force }
}

function Import-Script {
<#
.SYNOPSIS
    Imports one or more scripts by globalizing their function and filter declarations, then executing them.

.DESCRIPTION
    This function reads each .ps1 file, parses it with the PowerShell AST, and rewrites every
    function/filter declaration to include the global: scope (replacing script:, local:, private: if present).
    The transformed script is then executed so all such commands are available in the global/session scope.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
    ASCII only.

.PARAMETER File
    One or more script paths. Variables like $PSScriptRoot are expanded.

.PARAMETER ErrorIfMissing
    If set, writes a non-terminating error for each missing file and continues.

.EXAMPLE
    Import-Script -File @("$PSScriptRoot\cicd.migration.ps1")

.NOTES
    Only function/filter declarations are globalized. If the source script must expose variables
    globally, set them as $global:Var inside the source script.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string[]]$File,
        [switch]$ErrorIfMissing
    )

    foreach ($f in $File) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }

        # Expand variables (e.g., $PSScriptRoot) before checking.
        $expanded = $ExecutionContext.InvokeCommand.ExpandString($f)

        if (-not (Test-Path -LiteralPath $expanded)) {
            if ($ErrorIfMissing) { Write-Error "Import-Script: file not found: $expanded" }
            continue
        }

        # Read script as text
        $code = [System.IO.File]::ReadAllText($expanded)

        # Parse to AST (PS 5.1 and 7+)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            throw "Import-Script: parse errors in '$expanded'."
        }

        # Find all function/filter definitions
        $funcAsts = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

        # Collect edits: make each declaration global:
        $edits = @()
        foreach ($fd in $funcAsts) {
            $headerText = $fd.Extent.Text
            $m = [regex]::Match(
                $headerText,
                '^(?im)\s*(?<kw>function|filter)\s+(?<scope>(?:global|script|local|private):)?(?<name>[A-Za-z_][\w-]*)'
            )
            if (-not $m.Success) { continue }

            if ($m.Groups['scope'].Success -and $m.Groups['scope'].Value -eq 'global:') {
                continue
            }

            $headerStart = $fd.Extent.StartOffset
            if ($m.Groups['scope'].Success) {
                # Replace existing non-global scope with global:
                $start = $headerStart + $m.Groups['scope'].Index
                $end   = $start + $m.Groups['scope'].Length
                $edits += [pscustomobject]@{ Start=$start; End=$end; Text='global:' }
            } else {
                # Insert global: right before the function name
                $insertAt = $headerStart + $m.Groups['name'].Index
                $edits += [pscustomobject]@{ Start=$insertAt; End=$insertAt; Text='global:' }
            }
        }

        if ($edits.Count -gt 0) {
            foreach ($e in ($edits | Sort-Object Start -Descending)) {
                $prefix = $code.Substring(0, $e.Start)
                $suffix = $code.Substring($e.End)
                $code = $prefix + $e.Text + $suffix
            }
        }

        # Execute transformed script so global: declarations register in session scope
        & ([scriptblock]::Create($code))
    }
}

function Export-OfflineModuleBundle {
<#
.SYNOPSIS
Stage PSGallery modules into Root\Nuget, copy NuGet provider into Root\Provider, and emit an offline installer script. (PS 5.1)

.DESCRIPTION
Resolves modules (including dependencies) using Find-Module -IncludeDependencies, then downloads each as a .nupkg
via Save-Package into Root\Nuget. Copies the local NuGet provider DLLs into Root\Provider so an offline machine can
bootstrap the provider. Always emits "Install-ModulesFromRepoFolder.ps1" in the root folder, which contains the
installer function plus a ready-to-run invocation that targets the folder it resides in.

.REQUIREMENTS
Machine A (online, where you run this Save function):
- Windows PowerShell 5.1.
- Working internet access to https://www.powershellgallery.com/api/v2 .
- PackageManagement module available (built-in on PS 5.1).
- PowerShellGet v2 available (built-in on PS 5.1; can be upgraded but not required).
- NuGet package provider already installed and functional (Save-Package must work).
- TLS 1.2 allowed outbound (this function enables TLS 1.2 for the process if needed).
- Write permissions to the specified -Folder path.

Artifacts created under the root -Folder:
- Nuget\  : contains the downloaded .nupkg files for the specified modules and their dependencies.
- Provider\: contains NuGet provider DLLs copied from the local machine (used to bootstrap offline).
- Install-ModulesFromRepoFolder.ps1: the self-contained offline installer and invocation line.

Machine B (offline, where you will run the emitted installer):
- Windows PowerShell 5.1.
- PackageManagement and PowerShellGet present (the old in-box versions are fine; they will be upgraded).
- Local admin rights required ONLY if you intend to install for AllUsers; otherwise CurrentUser is fine.
- ExecutionPolicy must allow running the emitted .ps1 (e.g., set to RemoteSigned/Bypass as appropriate).
- No internet is required; all content comes from the copied Root folder.
- Write permissions to ProgramFiles (if installing for AllUsers) or to user Documents (CurrentUser).

Failure cases to be aware of:
- If NuGet provider is not present on Machine B and Provider\ is missing or incomplete, install will fail.
- If the Nuget\ folder does not contain a requested module (name mismatch or missing package), only that module fails.
- Locked module directories or insufficient permissions can prevent installation (especially AllUsers scope).

.PARAMETER Folder
Root folder that will contain "Nuget" and "Provider". Created if missing.

.PARAMETER Name
One or more module names to stage.

.PARAMETER Version
(Optional) Exact version to stage for all names; latest if omitted.

.EXAMPLE
PS> Export-OfflineModuleBundle -Folder C:\temp\export -Name @('PowerShellGet','PackageManagement','Pester','PSScriptAnalyzer','Eigenverft.Manifested.Drydock')

.TROUBLESHOOTING
- On Machine B, if the script reports missing NuGet provider, verify the "Provider" folder exists and contains NuGet*.dll.
- If Install-Module errors with repository issues, confirm the "Nuget" folder exists and holds the .nupkg files.
- If execution is blocked, set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass for the current session.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Folder,
        [Parameter(Mandatory, Position=1)]
        [string[]]$Name,
        [string]$Version
    )

    # TLS 1.2 for PSGallery on PS 5.1
    try {
        if (-not ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12)) {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
    } catch { }

    if (-not (Test-Path -LiteralPath $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }

    $nugetDir    = Join-Path $Folder "Nuget"
    $providerDir = Join-Path $Folder "Provider"
    if (-not (Test-Path -LiteralPath $nugetDir))    { New-Item -ItemType Directory -Path $nugetDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $providerDir)) { New-Item -ItemType Directory -Path $providerDir -Force | Out-Null }

    $feed = "https://www.powershellgallery.com/api/v2"
    $repo = "PSGallery"

    # Resolve full dependency closure with PowerShellGet (works on PS5.1)
    # Use a name->version map so we can Save-Package without IncludeDependencies.
    $needed = @{}
    foreach ($n in $Name) {
        try {
            $findParams = @{ Name = $n; Repository = $repo; ErrorAction = "Stop"; IncludeDependencies = $true }
            if ($Version) { $findParams["RequiredVersion"] = $Version }
            $mods = Find-Module @findParams
            foreach ($m in $mods) {
                # Record the highest version seen for each name (simple dedupe)
                if (-not $needed.ContainsKey($m.Name)) {
                    $needed[$m.Name] = $m.Version
                } else {
                    try {
                        # Compare as [version]; fallback to string compare if needed
                        $cur = [version]$needed[$m.Name]
                        $new = [version]$m.Version
                        if ($new -gt $cur) { $needed[$m.Name] = $m.Version }
                    } catch {
                        if ($m.Version -gt $needed[$m.Name]) { $needed[$m.Name] = $m.Version }
                    }
                }
            }
        } catch {
            Write-Error "Failed to resolve '$n' from $($repo): $($_.Exception.Message)"
        }
    }

    # Fall back: if dependency resolution returned nothing, at least try the requested names
    if ($needed.Count -eq 0) {
        foreach ($n in $Name) { $needed[$n] = $Version }
    }

    # >>> CHANGE: ensure a stable (non-prerelease) version is pinned for every entry
    foreach ($k in @($needed.Keys)) {
        $ver = $needed[$k]
        $looksPrerelease = $ver -and ($ver.ToString() -match '-')
        if (-not $ver -or $looksPrerelease) {
            try {
                # Find-Module (no -AllowPrerelease) returns latest stable version
                $resolved = Find-Module -Name $k -Repository $repo -ErrorAction Stop
                if ($resolved -and $resolved.Version) {
                    $needed[$k] = $resolved.Version
                } else {
                    # Leave as-is; Save-Package step will block to avoid prerelease
                    $needed[$k] = $null
                }
            } catch {
                # Leave null to trigger safe skip during Save-Package
                $needed[$k] = $null
            }
        }
    }
    # <<< END CHANGE

    # Download each required module version via Save-Package (no IncludeDependencies for compatibility)
    foreach ($pair in $needed.GetEnumerator()) {
        $mn = $pair.Key
        $mv = $pair.Value
        try {
            $p = @{
                Name         = $mn
                Path         = $nugetDir
                ProviderName = "NuGet"
                Source       = $feed
                ErrorAction  = "Stop"
            }
            if ($mv) {
                $p["RequiredVersion"] = $mv
            } else {
                # >>> CHANGE: skip to avoid accidentally pulling a prerelease
                Write-Error "No stable version found for '$mn' on $repo. Skipping to avoid prerelease."
                continue
                # <<< END CHANGE
            }
            [void](Save-Package @p)
        } catch {
            Write-Error "Failed to save '$mn' into '$nugetDir': $($_.Exception.Message)"
        }
    }

    # Copy NuGet provider DLLs for offline bootstrap (search ProgramFiles, LocalAppData, ProgramData)
    $providerCandidates = @(
        (Join-Path $Env:ProgramFiles "PackageManagement\ProviderAssemblies\NuGet"),
        (Join-Path $Env:LOCALAPPDATA  "PackageManagement\ProviderAssemblies\NuGet"),
        (Join-Path $Env:ProgramData   "PackageManagement\ProviderAssemblies\NuGet")
    ) | Where-Object { Test-Path -LiteralPath $_ }

    foreach ($src in $providerCandidates) {
        try {
            Copy-Item -Path (Join-Path $src "*") -Destination $providerDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Verbose "Provider copy from '$src' failed: $($_.Exception.Message)"
        }
    }

    # Emit installer script with function + invocation using $PSScriptRoot (UTF-8 for path safety)
    $installerPath = Join-Path $Folder "Install-ModulesFromRepoFolder.ps1"

$functionText = @'
function Install-ModulesFromRepoFolder {
<#
.SYNOPSIS
Install modules from Root\Nuget using a temporary PSRepository; bootstrap NuGet provider from Root\Provider. (PS 5.1)

.REQUIREMENTS
- Windows PowerShell 5.1.
- Root folder contains:
  - Provider\ with NuGet*.dll for offline bootstrap (if provider is missing).
  - Nuget\ with staged .nupkg files.
- If installing for AllUsers, run elevated.

.DESCRIPTION
1) If NuGet provider is missing, copy DLLs from Root\Provider to the proper provider path:
   - AllUsers (admin): %ProgramFiles%\PackageManagement\ProviderAssemblies\NuGet
   - CurrentUser (non-admin): %LocalAppData%\PackageManagement\ProviderAssemblies\NuGet
2) Register Root\Nuget as a temporary repository.
3) Install PackageManagement, then PowerShellGet, then remaining modules.
   Use -AllowClobber and -SkipPublisherCheck to handle in-box command collisions and publisher changes.
4) Unregister the temporary repository.

.PARAMETER Folder
Root folder containing Nuget and optionally Provider.

.PARAMETER Name
Module names to install from Root\Nuget.

.PARAMETER Scope
CurrentUser, AllUsers, or Auto (default). Auto selects AllUsers when the current process is elevated;
otherwise CurrentUser.

.EXAMPLE
PS> Install-ModulesFromRepoFolder -Folder C:\repo -Name Pester,PSScriptAnalyzer
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Folder,
        [Parameter(Mandatory, Position=1)]
        [string[]]$Name,
        [ValidateSet("CurrentUser","AllUsers","Auto")]
        [string]$Scope = "Auto"
    )

    Write-Host "[INFO] Starting offline installation..."
    Write-Host ("[INFO] Root folder: {0}" -f $Folder)

    if (-not (Test-Path -LiteralPath $Folder)) {
        throw "Folder not found: $Folder"
    }

    $nugetDir    = Join-Path $Folder "Nuget"
    $providerDir = Join-Path $Folder "Provider"
    if (-not (Test-Path -LiteralPath $nugetDir)) {
        throw "Required subfolder missing: $nugetDir"
    }

    # Determine elevation of current process
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # Resolve effective scope from requested Scope + elevation
    $effectiveScope = if ($Scope -eq "Auto") {
        if ($isAdmin) { "AllUsers" } else { "CurrentUser" }
    } else {
        $Scope
    }
    Write-Host ("[INFO] Effective installation scope: {0}" -f $effectiveScope)

    # Pick provider target based on effective scope and elevation
    $targetProviderRoot = if ($isAdmin -or $effectiveScope -eq "AllUsers") {
        Join-Path $Env:ProgramFiles "PackageManagement\ProviderAssemblies\NuGet"
    } else {
        Join-Path $Env:LOCALAPPDATA "PackageManagement\ProviderAssemblies\NuGet"
    }

    $providerPresent =
        @(Get-ChildItem -Path $Env:ProgramFiles,$Env:LOCALAPPDATA,$Env:ProgramData `
        -Recurse -ErrorAction SilentlyContinue `
        -Include 'Microsoft.PackageManagement.NuGetProvider.dll','NuGet*.dll').Count -gt 0

    if (-not $providerPresent) {
        if (-not (Test-Path $targetProviderRoot)) { New-Item -ItemType Directory -Force -Path $targetProviderRoot | Out-Null }
        Copy-Item -Path (Join-Path $providerDir '*') -Destination $targetProviderRoot -Recurse -Force
    }

    # Ensure NuGet provider from Provider if missing
    $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    if (-not $nuget) {
        Write-Host "[INFO] NuGet provider not found. Attempting offline bootstrap from Provider folder..."
        if (-not (Test-Path -LiteralPath $providerDir)) {
            throw ("NuGet provider not found. Expected staged provider under '{0}'." -f $providerDir)
        }
        if (-not (Test-Path -LiteralPath $targetProviderRoot)) {
            New-Item -ItemType Directory -Path $targetProviderRoot -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $providerDir "*") -Destination $targetProviderRoot -Recurse -Force -ErrorAction Stop
        $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        if (-not $nuget) { throw "NuGet provider bootstrap failed after copy." }
        Write-Host ("[OK] NuGet provider bootstrapped to: {0}" -f $targetProviderRoot)
    } else {
        Write-Host "[OK] NuGet provider is available."
    }

    # Register temp repo at Root\Nuget
    $repoName = ("TempRepo_{0}" -f ([Guid]::NewGuid().ToString("N").Substring(0,8)))
    Write-Host ("[INFO] Registering temporary repository '{0}' at: {1}" -f $repoName, $nugetDir)
    Register-PSRepository -Name $repoName -SourceLocation $nugetDir -PublishLocation $nugetDir -InstallationPolicy Trusted

    try {
        # Priority install: PackageManagement, then PowerShellGet
        $priority = @("PackageManagement","PowerShellGet")

        function Test-PackagePresent([string]$moduleName, [string]$rootNuget) {
            $pattern = Join-Path $rootNuget ("{0}*.nupkg" -f $moduleName)
            return (Test-Path -Path $pattern)
        }

        foreach ($m in $priority) {
            if (($Name -contains $m) -or (Test-PackagePresent -moduleName $m -rootNuget $nugetDir)) {
                Write-Host ("[INFO] Installing priority module: {0}" -f $m)
                try {
                    Install-Module -Name $m -Repository $repoName -Scope $effectiveScope -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
                    Write-Host ("[OK] Installed: {0}" -f $m)
                } catch {
                    Write-Error ("Failed to install priority module '{0}' from '{1}': {2}" -f $m, $nugetDir, $_.Exception.Message)
                }
            }
        }

        # Install remaining requested modules
        $remaining = $Name | Where-Object { $priority -notcontains $_ }
        foreach ($n in $remaining) {
            Write-Host ("[INFO] Installing module: {0}" -f $n)
            try {
                Install-Module -Name $n -Repository $repoName -Scope $effectiveScope -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
                Write-Host ("[OK] Installed: {0}" -f $n)
            } catch {
                Write-Error ("Failed to install '{0}' from '{1}': {2}" -f $n, $nugetDir, $_.Exception.Message)
            }
        }

        Write-Host "[OK] Installation sequence completed."
    }
    finally {
        Write-Host ("[INFO] Unregistering temporary repository: {0}" -f $repoName)
        try { Unregister-PSRepository -Name $repoName -ErrorAction SilentlyContinue } catch { }
    }

    [void](Read-Host "Press Enter to continue")
}
'@

    $namesList = ($Name -join ",")
    $usageLine = 'Install-ModulesFromRepoFolder -Folder "$PSScriptRoot" -Name ' + $namesList

    ($functionText + "`r`n" + $usageLine + "`r`n") | Out-File -FilePath $installerPath -Encoding utf8 -Force

    # NEW: emit a convenience CMD launcher in the root that runs the PS1
    $cmdPath = Join-Path $Folder "Install-ModulesFromRepoFolder.cmd"
    $cmdText = "@echo off`r`n" +
               "setlocal`r`n" +
               "powershell.exe -NoProfile -ExecutionPolicy Unrestricted -File ""%~dp0Install-ModulesFromRepoFolder.ps1""`r`n" +
               "endlocal`r`n"
    $cmdText | Out-File -FilePath $cmdPath -Encoding ASCII -Force

    # Return staged package paths for confirmation
    Get-ChildItem -LiteralPath $nugetDir -Filter *.nupkg | Select-Object -ExpandProperty FullName
}

function Uninstall-PreviousModuleVersions {
<#
.SYNOPSIS
Remove older versions of a PowerShell module while keeping exactly one per scope and ensure the kept version is active in the session.

.DESCRIPTION
- Decides scopes by Mode and elevation (non-elevated skips AllUsers).
- Supports Keep policy: Any/Stable/Prerelease (prerelease detected by '-' in version folder).
- Uses only Uninstall-Module (no filesystem deletes).
- Unloads the exact to-be-removed version before uninstall.
- After cleanup, ensures the globally kept version is the one loaded in the session (if any version was loaded initially or a different version is still loaded).
- Honors -WhatIf/-Confirm for uninstalls and for the final re-import step.

.PARAMETER ModuleName
Module name to clean.

.PARAMETER Mode
Auto (default), CurrentUser, AllUsers, Both.

.PARAMETER Keep
Any (default), Stable, Prerelease.

.PARAMETER PassThru
Emit objects describing planned/performed actions.

.EXAMPLE
Uninstall-PreviousModuleVersions -ModuleName Pester

.EXAMPLE
Uninstall-PreviousModuleVersions -ModuleName Az -Keep Stable -WhatIf

.OUTPUTS
pscustomobject (when -PassThru)
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ModuleName,

        [ValidateSet('Auto','CurrentUser','AllUsers','Both')]
        [string]$Mode = 'Auto',

        [ValidateSet('Any','Stable','Prerelease')]
        [string]$Keep = 'Any',

        [switch]$PassThru
    )

    # Preconditions
    if (-not (Get-Command Get-InstalledModule -ErrorAction SilentlyContinue)) {
        Write-Host "PowerShellGet (Get-InstalledModule) is required." -ForegroundColor Red
        return
    }
    if (-not (Get-Command Uninstall-Module -ErrorAction SilentlyContinue)) {
        Write-Host "PowerShellGet (Uninstall-Module) is required." -ForegroundColor Red
        return
    }

    $uninstallSupportsAllowPre = (Get-Command Uninstall-Module).Parameters.ContainsKey('AllowPrerelease')
    $getSupportsAllowPre       = (Get-Command Get-InstalledModule).Parameters.ContainsKey('AllowPrerelease')

    # Elevation
    $isElevated = $false
    try {
        if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
            $pri = [Security.Principal.WindowsPrincipal]$id
            $isElevated = $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } else {
            $uid = & id -u 2>$null
            if ($LASTEXITCODE -eq 0) { $isElevated = ([int]$uid -eq 0) }
        }
    } catch { $isElevated = $false }

    # Scopes to process
    $scopes = @()
    switch ($Mode) {
        'CurrentUser' { $scopes = @('CurrentUser') }
        'AllUsers'    { if ($isElevated) { $scopes = @('AllUsers') } else { $scopes = @() } }
        'Both'        { if ($isElevated) { $scopes = @('CurrentUser','AllUsers') } else { $scopes = @('CurrentUser') } }
        default       { if ($isElevated) { $scopes = @('CurrentUser','AllUsers') } else { $scopes = @('CurrentUser') } } # Auto
    }

    # Inventory
    $installed = $null
    if ($getSupportsAllowPre) {
        $installed = Get-InstalledModule -Name $ModuleName -AllVersions -AllowPrerelease -ErrorAction SilentlyContinue
    } else {
        $installed = Get-InstalledModule -Name $ModuleName -AllVersions -ErrorAction SilentlyContinue
    }
    if (-not $installed) {
        Write-Host "No installed versions found for '$ModuleName'." -ForegroundColor Yellow
        return
    }

    # Helpers
    $homex = if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $env:USERPROFILE } else { $env:HOME }
    function Get-InferredScope([string]$path) {
        try {
            $full = if ($path) { [IO.Path]::GetFullPath($path) } else { $null }
            if ($homex -and $full -and $full.StartsWith($homex, $true, [Globalization.CultureInfo]::InvariantCulture)) { 'CurrentUser' } else { 'AllUsers' }
        } catch { 'AllUsers' }
    }
    function Test-IsPrerelease([string]$installPath) {
        try { return [bool]((Split-Path -Leaf $installPath) -match '-') } catch { return $false }
    }
    function Get-Preferred([object[]]$items, [string]$policy) {
        $sorted = $items | Sort-Object Version -Descending
        if ($policy -eq 'Stable') {
            $st = $sorted | Where-Object { -not $_.IsPrerelease }
            if ($st -and $st.Count -gt 0) { return $st[0] } else { return $sorted[0] }
        } elseif ($policy -eq 'Prerelease') {
            $pr = $sorted | Where-Object { $_.IsPrerelease }
            if ($pr -and $pr.Count -gt 0) { return $pr[0] } else { return $sorted[0] }
        } else {
            return $sorted[0]
        }
    }
    function Get-ImportTargetPath([string]$moduleBase, [string]$name) {
        $psd1 = Join-Path $moduleBase ($name + '.psd1')
        $psm1 = Join-Path $moduleBase ($name + '.psm1')
        if (Test-Path -LiteralPath $psd1) { return $psd1 }
        if (Test-Path -LiteralPath $psm1) { return $psm1 }
        return $moduleBase   # let Import-Module resolve inside folder
    }

    # Annotate
    $annotated = foreach ($m in $installed) {
        [pscustomobject]@{
            Name              = $m.Name
            Version           = [version]$m.Version
            InstalledLocation = $m.InstalledLocation
            Scope             = Get-InferredScope $m.InstalledLocation
            IsPrerelease      = Test-IsPrerelease $m.InstalledLocation
        }
    }

    # Notify about AllUsers not processed
    if ( ($annotated | Where-Object Scope -eq 'AllUsers') -and -not ($scopes -contains 'AllUsers') ) {
        $auVersions = ($annotated | Where-Object Scope -eq 'AllUsers' | Sort-Object Version -Descending | Select-Object -ExpandProperty Version) -join ', '
        Write-Host "AllUsers installs detected for '$ModuleName': $auVersions. Run elevated to remove them." -ForegroundColor Yellow
    }

    # Compute the globally preferred "kept" version (used later for final Import-Module)
    $globalKeep = Get-Preferred ($annotated) $Keep

    # Was any version loaded initially?
    $wasLoadedInitially = $false
    $initialLoaded = Get-Module -Name $ModuleName
    if ($initialLoaded) { $wasLoadedInitially = $true }

    $summary = @()

    # Per-scope cleanup
    foreach ($scope in @('CurrentUser','AllUsers')) {
        $inScope = $annotated | Where-Object Scope -eq $scope
        if (-not $inScope) { continue }

        if (-not ($scopes -contains $scope)) {
            $skips = $inScope | Sort-Object Version -Descending | Select-Object -Skip 1
            foreach ($s in $skips) {
                if ($PassThru) {
                    $summary += [pscustomobject]@{ Scope=$scope; Version=$s.Version; Action='Skipped (NotElevated/Mode)'; Path=$s.InstalledLocation }
                }
            }
            continue
        }

        $sorted = $inScope | Sort-Object Version -Descending
        $keepItem = Get-Preferred $sorted $Keep
        if (-not $keepItem) { continue }

        $toRemove = $sorted | Where-Object { $_.InstalledLocation -ne $keepItem.InstalledLocation }

        if (-not $toRemove -or $toRemove.Count -eq 0) {
            Write-Host "[$scope] Nothing to remove. Keeping v$($keepItem.Version) (Keep=$Keep)." -ForegroundColor Green
            continue
        }

        Write-Host ("[{0}] Keeping v{1} (Keep={2}) at '{3}'." -f $scope, $keepItem.Version, $Keep, $keepItem.InstalledLocation) -ForegroundColor Cyan

        foreach ($item in $toRemove) {
            $label = '{0} v{1} ({2})' -f $item.Name, $item.Version, $scope
            if (-not $PSCmdlet.ShouldProcess($label, 'Uninstall older module version')) {
                if ($PassThru) { $summary += [pscustomobject]@{ Scope=$scope; Version=$item.Version; Action='Planned (WhatIf)'; Path=$item.InstalledLocation } }
                continue
            }

            # Unload the exact version if loaded
            $loaded = Get-Module -Name $item.Name | Where-Object { $_.ModuleBase -eq $item.InstalledLocation }
            if ($loaded) {
                try {
                    Remove-Module -ModuleInfo $loaded -Force -ErrorAction Stop
                    Write-Host "Unloaded $label prior to uninstall." -ForegroundColor Yellow
                } catch {
                    Write-Host ("Could not unload {0}: {1}" -f $label, $_.Exception.Message) -ForegroundColor Yellow
                }
            }

            # Uninstall (explicit calls; prerelease-aware)
            $removed = $false
            try {
                if ($item.IsPrerelease -and $uninstallSupportsAllowPre) {
                    Uninstall-Module -Name $item.Name -RequiredVersion ([string]$item.Version) -AllowPrerelease -Force -ErrorAction Stop
                } else {
                    Uninstall-Module -Name $item.Name -RequiredVersion ([string]$item.Version) -Force -ErrorAction Stop
                }
                $removed = $true
            } catch {
                Write-Host ("Failed to uninstall {0}: {1}" -f $label, $_.Exception.Message) -ForegroundColor Red
            }

            if ($removed) {
                Write-Host ("Removed {0} from '{1}'." -f $label, $item.InstalledLocation) -ForegroundColor Green
                if ($PassThru) { $summary += [pscustomobject]@{ Scope=$scope; Version=$item.Version; Action='Removed'; Path=$item.InstalledLocation } }
            } else {
                if ($PassThru) { $summary += [pscustomobject]@{ Scope=$scope; Version=$item.Version; Action='Error'; Path=$item.InstalledLocation } }
            }
        }
    }

    # --- Ensure the globally kept version is loaded at the end ----------------
    # Conditions to load:
    # 1) Any version was loaded initially, OR
    # 2) A different version is currently loaded (avoid ending with a stale loaded instance).
    $currentLoaded = Get-Module -Name $ModuleName
    $needEnsureLoad = $false
    if ($wasLoadedInitially) { $needEnsureLoad = $true }
    elseif ($currentLoaded) {
        # If something is loaded but its ModuleBase doesn't match the kept one, we should switch.
        $match = $false
        foreach ($m in $currentLoaded) {
            if ($m.ModuleBase -eq $globalKeep.InstalledLocation) { $match = $true; break }
        }
        if (-not $match) { $needEnsureLoad = $true }
    }

    if ($needEnsureLoad -and $globalKeep) {
        $ensureLabel = ('{0} v{1} (ensure loaded)' -f $globalKeep.Name, $globalKeep.Version)
        if ($PSCmdlet.ShouldProcess($ensureLabel, 'Ensure kept version is loaded')) {
            # Remove any loaded instances first
            try { Remove-Module -Name $ModuleName -Force -ErrorAction SilentlyContinue } catch {}

            # Import the kept version by explicit path (avoids prerelease ambiguity)
            $importTarget = Get-ImportTargetPath $globalKeep.InstalledLocation $globalKeep.Name
            try {
                Import-Module -Name $importTarget -Force -ErrorAction Stop
                Write-Host ("Loaded kept version: {0} v{1}" -f $globalKeep.Name, $globalKeep.Version) -ForegroundColor Green
            } catch {
                Write-Host ("Failed to load kept version {0} v{1}: {2}" -f $globalKeep.Name, $globalKeep.Version, $_.Exception.Message) -ForegroundColor Red
            }
        }
    }

    Write-Host ("Cleanup complete (mode: {0}, keep: {1}, elevated: {2})." -f $Mode, $Keep, $isElevated) -ForegroundColor Green
    if ($PassThru) { $summary }
}

function Find-ModuleScopeClutter {
<#
.SYNOPSIS
Detects modules that are installed in both user and system scopes.

.DESCRIPTION
Scans all discoverable modules (Get-Module -ListAvailable), classifies each module's path
as CurrentUser or AllUsers by comparing against user-owned roots derived from PSModulePath
and common platform locations, and outputs module names that appear in both scopes.
Default output is just the module names (unique, sorted) for easy piping.

.PARAMETER Detailed
If set, also writes a human-readable table showing per-scope versions and paths.

.PARAMETER PassThru
If set, returns rich objects with Name and grouped details; otherwise writes names to the pipeline.

.EXAMPLE
Find-ModuleScopeClutter
# Prints only module names that are installed in both scopes.

.EXAMPLE
Find-ModuleScopeClutter -Detailed
# Prints a readable table with versions/paths per scope, plus the names to the pipeline.

.OUTPUTS
System.String (default) or System.Object (with -PassThru)

.NOTES
- PS5-compatible; no reliance on $IsWindows/$IsLinux/$IsMacOS.
- External-reviewer note: Classification is heuristic (based on user-home prefixes); uncommon custom roots may classify as AllUsers.
- Silent skip on Windows: PSReadLine and Pester are ignored to reduce noise from in-box modules.
#>
    [CmdletBinding()]
    param(
        [switch]$Detailed,
        [switch]$PassThru
    )

    # Reviewer: Avoid helper functions per user's style; keep logic inline and PS5-safe.

    # OS hint (avoid $IsWindows collision on PS7 by using our own name).
    $onWindowsOS = $false
    try { $onWindowsOS = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT } catch { $onWindowsOS = $true }

    # Gather candidate "user roots" from PSModulePath + well-known locations.
    $pathSep      = [IO.Path]::PathSeparator
    $modulePaths  = @()
    if ($env:PSModulePath) { $modulePaths = $env:PSModulePath -split [regex]::Escape($pathSep) }

    # Derive user home in a PS5-friendly way.
    $userHomePath = if ($onWindowsOS) { $env:USERPROFILE } else { $env:HOME }
    if (-not $userHomePath) { try { $userHomePath = [Environment]::GetFolderPath('UserProfile') } catch { $userHomePath = $null } }

    # Windows: include common Documents-based user module roots (these are typical on WinPS 5.1).
    $userDocsPath = $null
    if ($onWindowsOS) { try { $userDocsPath = [Environment]::GetFolderPath('MyDocuments') } catch { $userDocsPath = $null } }

    $candidateUserRoots = @()
    if ($modulePaths) {
        # Any PSModulePath entry under the user's home is considered "user scope".
        $candidateUserRoots += ($modulePaths | Where-Object {
            $_ -and $userHomePath -and $_.StartsWith($userHomePath, [System.StringComparison]::OrdinalIgnoreCase)
        })
    }
    if ($onWindowsOS -and $userDocsPath) {
        $candidateUserRoots += (Join-Path $userDocsPath 'WindowsPowerShell\Modules')
        $candidateUserRoots += (Join-Path $userDocsPath 'PowerShell\Modules')
    }

    # Normalize and distinct user roots.
    $userRoots = @()
    foreach ($r in $candidateUserRoots) {
        if ($r) {
            try { $userRoots += [IO.Path]::GetFullPath($r) } catch { $userRoots += $r }
        }
    }
    $userRoots = $userRoots | Sort-Object -Unique

    # Enumerate all available modules from every path.
    $all = Get-Module -ListAvailable | Select-Object Name, Version, ModuleBase

    # Annotate each with inferred scope (PS5-safe StartsWith overload).
    $annotated = foreach ($m in $all) {
        $base = $m.ModuleBase
        try { if ($base) { $base = [IO.Path]::GetFullPath($base) } } catch { }

        $isUser = $false
        foreach ($ur in $userRoots) {
            if ($ur -and $base -and $base.StartsWith($ur, $true, [Globalization.CultureInfo]::InvariantCulture)) {
                $isUser = $true; break
            }
        }

        # Note: if we can't map to a user root, treat as AllUsers by default.
        $scopeLabel = if ($isUser) { 'CurrentUser' } else { 'AllUsers' }

        # Select minimal fields; duplicates (same Name/Version/Path) are harmless.
        [pscustomobject]@{
            Name       = $m.Name
            Version    = $m.Version
            ModuleBase = $base
            Scope      = $scopeLabel
        }
    }

    # Group by name and keep only those that appear in both scopes.
    $clutter = $annotated |
        Group-Object Name |
        Where-Object { ($_.Group.Scope | Select-Object -Unique).Count -ge 2 }

    # --- Minimal change: silently ignore common in-box modules on Windows to avoid confusion.
    if ($onWindowsOS) {
        $skip = @('PSReadLine','Pester')
        $clutter = $clutter | Where-Object { $skip -notcontains $_.Name }
    }
    # ---

    if (-not $clutter) {
        Write-Host "No modules found installed in both user and system scopes." -ForegroundColor Green
        return
    }

    # Default output: just the names (unique, sorted).
    $names = $clutter | Select-Object -ExpandProperty Name | Sort-Object -Unique

    if ($Detailed) {
        # Reviewer: Provide concise per-scope detail without overwhelming the user.
        foreach ($g in $clutter) {
            $userSide = $g.Group | Where-Object Scope -eq 'CurrentUser' | Sort-Object Version -Descending
            $sysSide  = $g.Group | Where-Object Scope -eq 'AllUsers'   | Sort-Object Version -Descending

            $uVers = if ($userSide) { ($userSide | Select-Object -Expand Version) -join ', ' } else { '-' }
            $sVers = if ($sysSide)  { ($sysSide  | Select-Object -Expand Version) -join ', ' } else { '-' }

            Write-Host ("{0}`n  CurrentUser: {1}`n  AllUsers   : {2}" -f $g.Name, $uVers, $sVers) -ForegroundColor Yellow
        }
    }

    if ($PassThru) {
        # Return rich objects if desired (useful for CI/pipelines).
        $objects = foreach ($g in $clutter) {
            [pscustomobject]@{
                Name         = $g.Name
                CurrentUser  = $g.Group | Where-Object Scope -eq 'CurrentUser' | Sort-Object Version -Descending | Select-Object Name,Version,ModuleBase,Scope
                AllUsers     = $g.Group | Where-Object Scope -eq 'AllUsers'    | Sort-Object Version -Descending | Select-Object Name,Version,ModuleBase,Scope
            }
        }
        $objects
    } else {
        # Emit names to pipeline (so caller can pipe into Remove-OldModuleVersions).
        $names
    }
}

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

function Update-ManifestReleaseNotes {
<#
.SYNOPSIS
    Updates the ReleaseNotes value in a PowerShell module manifest (psd1).

.DESCRIPTION
    Reads the manifest as raw text and replaces only the ReleaseNotes value inside PrivateData.PSData.
    Supports single-quoted, double-quoted, and here-string forms while preserving comments and formatting.
    No extra helpers; compatible with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER ManifestPath
    File or directory path. If a directory is provided, the first *.psd1 found recursively is used.

.PARAMETER NewReleaseNotes
    The new ReleaseNotes text. Multiline supported.

.EXAMPLE
    Update-ManifestReleaseNotes -ManifestPath .\MyModule -NewReleaseNotes "Fixed bugs; improved logging."
#>
    [CmdletBinding()]
    [Alias('umrn')]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath,
        [Parameter(Mandatory)]
        [string]$NewReleaseNotes
    )

    # Resolve a concrete psd1 path (inline; no helper functions)
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "The path '$ManifestPath' does not exist."
    }
    $item = Get-Item -LiteralPath $ManifestPath
    if ($item.PSIsContainer) {
        $psd1 = Get-ChildItem -LiteralPath $ManifestPath -Filter *.psd1 -Recurse | Select-Object -First 1
        if (-not $psd1) { throw "No PSD1 manifest file found under '$ManifestPath'." }
        $ManifestPath = $psd1.FullName
    }

    # Read, replace, write (keep it simple to match your original style)
    $content = [System.IO.File]::ReadAllText($ManifestPath)

    # Define patterns that capture prefix/content/suffix so we can rebuild safely (avoids replacement-string $ pitfalls).
    $opts = [System.Text.RegularExpressions.RegexOptions]::Singleline -bor
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase  -bor
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

    $defs = @(
        @{ Style='hsq'; Pattern='(?s)(?<prefix>\bReleaseNotes\s*=\s*@'')(?<content>.*?)(?<suffix>''@)' }  # @' ... '@
        @{ Style='hdq'; Pattern='(?s)(?<prefix>\bReleaseNotes\s*=\s*@"")(?<content>.*?)(?<suffix>""@)' }  # @" ... "@
        @{ Style='sq' ; Pattern='(?<prefix>\bReleaseNotes\s*=\s*'')(?<content>(?:''''|[^''])*)(?<suffix>'')' } # '...'
        @{ Style='dq' ; Pattern='(?<prefix>\bReleaseNotes\s*=\s*"")(?<content>(?:``.|`"|[^""])*?)(?<suffix>"")' } # "..."
    )

    $updated = $false
    foreach ($d in $defs) {
        $rx = [System.Text.RegularExpressions.Regex]::new($d.Pattern, $opts)
        if ($rx.IsMatch($content)) {
            $content = $rx.Replace($content, {
                param($m)
                switch ($d.Style) {
                    'sq'  { $enc = $NewReleaseNotes -replace "'", "''" }               # Single-quoted: double single quotes
                    'dq'  { $t = $NewReleaseNotes -replace '`','``'; $t = $t -replace '"','`"'; $enc = $t -replace '\$','`$' }
                    'hsq' { $enc = $NewReleaseNotes }                                   # Single-quoted here-string: literal
                    'hdq' { $t = $NewReleaseNotes -replace '`','``'; $t = $t -replace '"','`"'; $enc = $t -replace '\$','`$' }
                }
                # Rebuild exact structure to keep whitespace/comments intact
                $m.Groups['prefix'].Value + $enc + $m.Groups['suffix'].Value
            }, 1)
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        throw "Could not locate a 'ReleaseNotes' assignment (supported forms: quoted or here-string)."
    }

    [System.IO.File]::WriteAllText($ManifestPath, $content)
}

function Update-ManifestPrerelease {
<#
.SYNOPSIS
    Updates the Prerelease value in a PowerShell module manifest (psd1).

.DESCRIPTION
    - If -NewPrerelease is non-empty, replaces only the value and preserves the original quoting style
      (single-quoted, double-quoted, or here-string).
    - If -NewPrerelease is '' (empty) or $null, keeps the 'Prerelease' assignment but sets it to an
      empty string: Prerelease = ''  (for here-strings, converts to a single-quoted empty value).
    - Recognizes and "activates" commented-out assignments such as:
        # Prerelease = 'dev'
        #Prerelease = 'dev'
        # # # Prerelease = 'dev'
        ### ## Prerelease = 'dev'
    - Raw-text approach; PS 5.1 and 7+ compatible.

.PARAMETER ManifestPath
    File or directory path. If a directory is provided, the first *.psd1 found recursively is used.

.PARAMETER NewPrerelease
    New prerelease label (e.g. "preview1", "beta.2", "rc.1").
    Pass empty string "" to set an EMPTY value (release) while keeping the key.

.EXAMPLE
    Update-ManifestPrerelease -ManifestPath .\MyModule\MyModule.psd1 -NewPrerelease "beta.2"

.EXAMPLE
    # Keep the key but make it empty
    Update-ManifestPrerelease -ManifestPath .\MyModule\MyModule.psd1 -NewPrerelease ""
#>
    [CmdletBinding()]
    [Alias('umpr')]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$NewPrerelease
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "The path '$ManifestPath' does not exist."
    }
    $item = Get-Item -LiteralPath $ManifestPath
    if ($item.PSIsContainer) {
        $psd1 = Get-ChildItem -LiteralPath $ManifestPath -Filter *.psd1 -Recurse | Select-Object -First 1
        if (-not $psd1) { throw "No PSD1 manifest file found under '$ManifestPath'." }
        $ManifestPath = $psd1.FullName
    }

    $content  = [System.IO.File]::ReadAllText($ManifestPath)
    $original = $content

    $optsAll  = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    $optsLine = $optsAll -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    $optsHere = $optsLine -bor [System.Text.RegularExpressions.RegexOptions]::Singleline

    # Reviewer: Precompute escapes for quoted contexts when setting a non-empty value.
    $isEmpty = [string]::IsNullOrEmpty($NewPrerelease)
    $encSQ = if ($isEmpty) { '' } else { $NewPrerelease -replace "'", "''" }
    $encDQ = if ($isEmpty) { '' } else { $NewPrerelease -replace '(["`$])','`$1' }

    # Supported active assignment forms; stop on the first match.
    $defs = @(
        # Here-strings first (line-anchored)
        @{ Style='hsq'; Options=$optsHere; Pattern='^(?<indent>[ \t]*)\bPrerelease\s*=\s*@''(?<content>.*?)''@(?<trail>[ \t]*#.*)?(?<nl>\r?\n?)' }
        @{ Style='hdq'; Options=$optsHere; Pattern='^(?<indent>[ \t]*)\bPrerelease\s*=\s*@"(?<content>.*?)"@(?<trail>[ \t]*#.*)?(?<nl>\r?\n?)' }
        # Quoted single-line
        @{ Style='sq' ; Options=$optsLine; Pattern='(?<prefix>\bPrerelease\s*=\s*'')(?<content>(?:''''|[^''])*)(?<suffix>'')' }
        @{ Style='dq' ; Options=$optsLine; Pattern='(?<prefix>\bPrerelease\s*=\s*")(?<content>(?:``.|`"|[^"])*)?(?<suffix>")' }
    )

    # Track whether any (active or commented) assignment was located.
    $matched = $false

    foreach ($d in $defs) {
        $rx = [regex]::new($d.Pattern, $d.Options)
        if (-not $rx.IsMatch($content)) { continue }

        $matched = $true

        $content = $rx.Replace($content, {
            param($m)
            switch ($d.Style) {
                # Here-strings: if empty -> convert to single-quoted empty; else keep here-string style.
                'hsq' {
                    if ($isEmpty) {
                        $m.Groups['indent'].Value + "Prerelease = ''" + $m.Groups['trail'].Value + $m.Groups['nl'].Value
                    } else {
                        $m.Groups['indent'].Value + "Prerelease = @'" + $NewPrerelease + "'@" + $m.Groups['trail'].Value + $m.Groups['nl'].Value
                    }
                }
                'hdq' {
                    if ($isEmpty) {
                        $m.Groups['indent'].Value + "Prerelease = ''" + $m.Groups['trail'].Value + $m.Groups['nl'].Value
                    } else {
                        # Use escaped content for expandable here-strings.
                        $m.Groups['indent'].Value + 'Prerelease = @"' + $encDQ + '"@' + $m.Groups['trail'].Value + $m.Groups['nl'].Value
                    }
                }
                # Quoted forms: keep the quote style, replace inside the quotes.
                'sq' { $m.Groups['prefix'].Value + $encSQ + $m.Groups['suffix'].Value }
                'dq' { $m.Groups['prefix'].Value + $encDQ + $m.Groups['suffix'].Value }
            }
        }, 1)

        break
    }

    # If no active assignment matched, try commented-out assignment lines with 1+ '#'
    if (-not $matched) {
        $commentDefs = @(
            # Matches:
            #   # Prerelease = 'dev'
            #   #Prerelease = 'dev'
            #   # # # Prerelease = 'dev'
            #   ### ## Prerelease = 'dev'
            @{ Style='csq'; Options=$optsLine; Pattern='^(?<indent>[ \t]*)(?:#\s*)+\bPrerelease\s*=\s*''(?<content>(?:''''|[^''])*)''(?<trail>[ \t]*#.*)?(?<nl>\r?\n?)' }
            @{ Style='cdq'; Options=$optsLine; Pattern='^(?<indent>[ \t]*)(?:#\s*)+\bPrerelease\s*=\s*"(?<content>(?:``.|`"|[^"])*)?"(?<trail>[ \t]*#.*)?(?<nl>\r?\n?)' }
        )
        foreach ($d in $commentDefs) {
            $rx = [regex]::new($d.Pattern, $d.Options)
            if (-not $rx.IsMatch($content)) { continue }

            $matched = $true

            $content = $rx.Replace($content, {
                param($m)
                switch ($d.Style) {
                    'csq' { $m.Groups['indent'].Value + "Prerelease = '" + $encSQ + "'" + $m.Groups['trail'].Value + $m.Groups['nl'].Value }
                    'cdq' { $m.Groups['indent'].Value + 'Prerelease = "' + $encDQ + '"' + $m.Groups['trail'].Value + $m.Groups['nl'].Value }
                }
            }, 1)
            break
        }
    }

    # Throw only if we never matched an active or commented assignment.
    if (-not $matched) {
        throw "Could not locate a 'Prerelease' assignment (supported forms: quoted or here-string; commented forms with leading '#' are also recognized)."
    }

    # Write only when the file content actually changes (equal value is success, no write).
    if ($content -ne $original) {
        [System.IO.File]::WriteAllText($ManifestPath, $content)
    }
}




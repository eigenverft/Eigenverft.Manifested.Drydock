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


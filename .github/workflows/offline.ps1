function Save-PSBootstrapPayload {
<#
.SYNOPSIS
Stage modules and (optionally) the NuGet provider to a share for offline PS5 bootstrap.

.DESCRIPTION
- Source=Local (default): copies the highest locally installed module versions, and the locally present NuGet provider.
- Source=Gallery: saves exact module versions from PSGallery (requires internet); NuGet provider is installed locally and then copied.
- Creates:
    <ShareRoot>\Modules\<Name>\<Version>\*
    <ShareRoot>\Providers\NuGet\<Version>\*
- PS5-friendly: Write-Host only; enables TLS 1.2 only when Source=Gallery.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ShareRoot,

        [Parameter()]
        [string[]]$Modules = @('PowerShellGet','PackageManagement'),

        [Parameter()]
        [ValidateSet('Local','Gallery')]
        [string]$Source = 'Local',

        [Parameter()]
        [hashtable]$ModuleVersions = @{},  # optional

        [Parameter()]
        [switch]$IncludeNuGetProvider,

        [Parameter()]
        [string]$NuGetVersion = '2.8.5.201',

        [Parameter()]
        [switch]$Force
    )

    if ($Source -eq 'Gallery') {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    }

    # Ensure base dirs
    $modulesRoot  = Join-Path -Path $ShareRoot -ChildPath 'Modules'
    $providerRoot = Join-Path -Path $ShareRoot -ChildPath 'Providers\NuGet'
    foreach ($p in @($modulesRoot,$providerRoot)) {
        try { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } } catch {}
    }

    # --- Stage Modules --------------------------------------------------------
    foreach ($name in $Modules) {
        if ($Source -eq 'Local') {
            $want = $ModuleVersions[$name]
            $candidates = Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending
            $picked = $null
            if ($want) {
                $picked = $candidates | Where-Object { $_.Version -eq [Version]$want } | Select-Object -First 1
            } else {
                $picked = $candidates | Select-Object -First 1
            }

            if (-not $picked) {
                if ($want) { Write-Host "[Skip] Local $name $want not found." } else { Write-Host "[Skip] Local $name not installed." }
                continue
            }

            $targetVer = $picked.Version.ToString()
            $srcPath   = $picked.ModuleBase
            $dstPath   = Join-Path -Path (Join-Path -Path $modulesRoot -ChildPath $name) -ChildPath $targetVer

            if ((Test-Path $dstPath) -and -not $Force) {
                Write-Host "[Skip] $name $targetVer already staged → $dstPath"
            } else {
                try {
                    if (-not (Test-Path $dstPath)) { New-Item -ItemType Directory -Path $dstPath -Force | Out-Null }
                    Copy-Item -Path (Join-Path -Path $srcPath -ChildPath '*') -Destination $dstPath -Recurse -Force
                    Write-Host "[OK] Staged (local) $name $targetVer → $dstPath"
                } catch {
                    Write-Host "Error: Copy $name $targetVer failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        } else {
            # Source = Gallery
            $targetVer = $ModuleVersions[$name]
            if (-not $targetVer) {
                try {
                    $fm = Find-Module -Name $name -Repository PSGallery -ErrorAction Stop
                    $targetVer = $fm.Version.ToString()
                    Write-Host "[Info] Latest PSGallery version for $name is $targetVer"
                } catch {
                    Write-Host "Error: Find-Module $name failed: $($_.Exception.Message)" -ForegroundColor Red
                    continue
                }
            }
            $dstBase = Join-Path -Path $modulesRoot -ChildPath $name
            try {
                Write-Host "[Action] Saving $name $targetVer from PSGallery..."
                Save-Module -Name $name -RequiredVersion $targetVer -Repository PSGallery -Path $dstBase -Force -ErrorAction Stop
                $savedPath = Join-Path -Path $dstBase -ChildPath $targetVer
                Write-Host "[OK] Saved (gallery) $name $targetVer → $savedPath"
            } catch {
                Write-Host "Error: Save-Module $name $targetVer failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # --- Stage NuGet Provider -------------------------------------------------
    if ($IncludeNuGetProvider) {
        if ($Source -eq 'Local') {
            $pfBase = Join-Path -Path $env:ProgramFiles -ChildPath 'PackageManagement\ProviderAssemblies\nuget'
            $laBase = Join-Path -Path $env:LOCALAPPDATA  -ChildPath 'PackageManagement\ProviderAssemblies\nuget'
            $cand1  = Join-Path -Path $pfBase -ChildPath $NuGetVersion
            $cand2  = Join-Path -Path $laBase -ChildPath $NuGetVersion

            $src = @( $cand1, $cand2 ) | Where-Object { Test-Path $_ } | Select-Object -First 1

            # If requested version not present, fall back to highest local version folder
            if (-not $src) {
                $roots = @( $pfBase, $laBase ) | Where-Object { Test-Path $_ }
                $verDir = $roots | ForEach-Object { Get-ChildItem -Path $_ -Directory } | Sort-Object Name -Descending | Select-Object -First 1
                if ($verDir) { $src = $verDir.FullName; $NuGetVersion = $verDir.Name }
            }

            if (-not $src) {
                Write-Host "[Skip] No local NuGet provider found; nothing staged."
            } else {
                $dst = Join-Path -Path $providerRoot -ChildPath $NuGetVersion
                if ((Test-Path $dst) -and -not $Force) {
                    Write-Host "[Skip] NuGet provider $NuGetVersion already staged → $dst"
                } else {
                    try { Copy-Item -Path $src -Destination $dst -Recurse -Force; Write-Host "[OK] Staged (local) NuGet $NuGetVersion → $dst" }
                    catch { Write-Host "Error: Copy NuGet provider failed: $($_.Exception.Message)" -ForegroundColor Red }
                }
            }
        } else {
            try {
                Write-Host "[Action] Ensuring NuGet provider >= $NuGetVersion..."
                Install-PackageProvider -Name NuGet -MinimumVersion $NuGetVersion -Force -ForceBootstrap | Out-Null
            } catch {
                Write-Host "Error: Install-PackageProvider NuGet failed: $($_.Exception.Message)" -ForegroundColor Red
            }

            $pfBase = Join-Path -Path $env:ProgramFiles -ChildPath 'PackageManagement\ProviderAssemblies\nuget'
            $laBase = Join-Path -Path $env:LOCALAPPDATA  -ChildPath 'PackageManagement\ProviderAssemblies\nuget'
            $cand1  = Join-Path -Path $pfBase -ChildPath $NuGetVersion
            $cand2  = Join-Path -Path $laBase -ChildPath $NuGetVersion
            $src    = @( $cand1, $cand2 ) | Where-Object { Test-Path $_ } | Select-Object -First 1

            if ($src) {
                $dst = Join-Path -Path $providerRoot -ChildPath $NuGetVersion
                try { Copy-Item -Path $src -Destination $dst -Recurse -Force; Write-Host "[OK] Staged (gallery) NuGet $NuGetVersion → $dst" }
                catch { Write-Host "Error: Copy NuGet provider failed: $($_.Exception.Message)" -ForegroundColor Red }
            } else {
                Write-Host "Error: NuGet provider $NuGetVersion not found locally after install." -ForegroundColor Red
            }
        }
    }

    Write-Host "[Result] Staging complete (Source=$Source)."
}

function Install-PowerShellBitsFromShare {
<#
.SYNOPSIS
Offline bootstrap for PS5 from a file share: NuGet provider + modules (latest version per module).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ShareRoot,

        [Parameter()]
        [ValidateSet('CurrentUser','AllUsers')]
        [string]$Scope = 'CurrentUser',

        [Parameter()]
        [string[]]$Modules,

        [Parameter()]
        [switch]$SkipNuGetProvider
    )

    # Guard: PS version / elevation
    if ($PSVersionTable.PSVersion.Major -ne 5) {
        Write-Host "[Skip] PowerShell $($PSVersionTable.PSVersion) is not 5.x; nothing to do."
        return
    }
    if ($Scope -eq 'AllUsers') {
        $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pri = [Security.Principal.WindowsPrincipal]$id
        if (-not $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Host "Error: 'AllUsers' requires an elevated session." -ForegroundColor Red
            return
        }
    }

    # Destinations
    $modulesDst = if ($Scope -eq 'AllUsers') {
        Join-Path -Path $env:ProgramFiles -ChildPath 'WindowsPowerShell\Modules'
    } else {
        Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'WindowsPowerShell\Modules'
    }
    $providerDst = if ($Scope -eq 'AllUsers') {
        Join-Path -Path $env:ProgramFiles  -ChildPath 'PackageManagement\ProviderAssemblies\nuget'
    } else {
        Join-Path -Path $env:LOCALAPPDATA -ChildPath 'PackageManagement\ProviderAssemblies\nuget'
    }

    function Copy-LatestVersionFolder {
        param(
            [Parameter(Mandatory)][string]$SourceRoot,
            [Parameter(Mandatory)][string]$DestinationRoot,
            [Parameter(Mandatory)][string]$Label
        )
        if (-not (Test-Path -Path $SourceRoot)) {
            Write-Host "[Skip] $Label source not found: $SourceRoot"
            return $null
        }
        $verDir = Get-ChildItem -Path $SourceRoot -Directory |
                  Sort-Object { try { [Version]$_.Name } catch { [version]'0.0.0.0' } } -Descending |
                  Select-Object -First 1
        if (-not $verDir) {
            Write-Host "[Skip] No version folders found under $SourceRoot"
            return $null
        }
        $dst = Join-Path -Path $DestinationRoot -ChildPath $verDir.Name
        if (-not (Test-Path -Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        & robocopy $verDir.FullName $dst /E /NFL /NDL /NJH /NJS /NP | Out-Null
        Write-Host "[OK] $Label $($verDir.Name) → $dst"
        return $verDir.Name
    }

    # NuGet provider
    if (-not $SkipNuGetProvider) {
        $provShareRoot = Join-Path -Path $ShareRoot -ChildPath 'Providers\NuGet'
        $null = New-Item -ItemType Directory -Path $providerDst -Force -ErrorAction SilentlyContinue
        $null = Copy-LatestVersionFolder -SourceRoot $provShareRoot -DestinationRoot $providerDst -Label 'NuGet provider'
    } else {
        Write-Host "[Skip] NuGet provider by request (-SkipNuGetProvider)."
    }

    # Modules list
    $modulesShareRoot = Join-Path -Path $ShareRoot -ChildPath 'Modules'
    if (-not $Modules -or $Modules.Count -eq 0) {
        if (Test-Path -Path $modulesShareRoot) {
            $Modules = Get-ChildItem -Path $modulesShareRoot -Directory | Select-Object -ExpandProperty Name
        } else {
            $Modules = @()
        }
    }
    if ($Modules.Count -eq 0) {
        Write-Host "[Skip] No modules found to install under $modulesShareRoot."
    }

    foreach ($name in $Modules) {
        $srcRoot = Join-Path -Path $modulesShareRoot -ChildPath $name
        $dstRoot = Join-Path -Path $modulesDst      -ChildPath $name
        $null = New-Item -ItemType Directory -Path $dstRoot -Force -ErrorAction SilentlyContinue

        $latest = Copy-LatestVersionFolder -SourceRoot $srcRoot -DestinationRoot $dstRoot -Label $name
        if ($latest) {
            try { Import-Module -Name $name -MinimumVersion $latest -Force -ErrorAction Stop; Write-Host "[OK] Imported $name $latest into session." }
            catch { Write-Host "[Warn] Import of $name $latest failed in this session: $($_.Exception.Message)" }
        }
    }

    Write-Host "[Result] Offline bootstrap completed for scope '$Scope'."
}

function Save-ModulesToRepoFolder {
<#
.SYNOPSIS
Stage PSGallery modules as .nupkg into Root\Nuget and copy NuGet provider DLLs into Root\Provider. (PS 5.1)

.DESCRIPTION
Downloads .nupkg files from the PowerShell Gallery (NuGet v2 feed) into Root\Nuget and
copies the local NuGet provider DLLs into Root\Provider for offline bootstrap.

.PARAMETER Folder
Root folder that will contain "Nuget" and "Provider" subfolders. Created if missing.

.PARAMETER Name
One or more module names to stage.

.PARAMETER Version
(Optional) Exact version to stage for all names. If omitted, latest is used.

.EXAMPLE
PS> Save-ModulesToRepoFolder -Folder C:\repo -Name Pester,PSScriptAnalyzer
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Folder,
        [Parameter(Mandatory, Position=1)]
        [string[]]$Name,
        [string]$Version
    )

    # Ensure TLS 1.2 on PS 5.1 for PSGallery.
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

    foreach ($n in $Name) {
        try {
            $p = @{
                Name         = $n
                Path         = $nugetDir
                ProviderName = "NuGet"
                Source       = $feed
                ErrorAction  = "Stop"
            }
            if ($Version) { $p["RequiredVersion"] = $Version }
            [void](Save-Package @p)
        } catch {
            Write-Error "Failed to save '$n' into '$nugetDir': $($_.Exception.Message)"
        }
    }

    # Stage NuGet provider DLLs for offline bootstrap.
    $providerCandidates = @(
        (Join-Path $Env:ProgramFiles "PackageManagement\ProviderAssemblies\NuGet"),
        (Join-Path $Env:LOCALAPPDATA  "PackageManagement\ProviderAssemblies\NuGet")
    ) | Where-Object { Test-Path -LiteralPath $_ }

    foreach ($src in $providerCandidates) {
        try {
            Copy-Item -Path (Join-Path $src "*") -Destination $providerDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Verbose "Provider copy from '$src' failed: $($_.Exception.Message)"
        }
    }

    Get-ChildItem -LiteralPath $nugetDir -Filter *.nupkg | Select-Object -ExpandProperty FullName
}

function Install-ModulesFromRepoFolder {
<#
.SYNOPSIS
Install modules from Root\Nuget using a temporary PSRepository; bootstrap NuGet provider from Root\Provider. (PS 5.1)

.DESCRIPTION
1) If NuGet provider is missing, copies DLLs from Root\Provider into ProgramFiles provider location.
2) Registers Root\Nuget as a temporary PowerShellGet v2 repository.
3) Installs PackageManagement, then PowerShellGet, then remaining requested modules.
4) Unregisters the temporary repository.

.PARAMETER Folder
Root folder that contains "Nuget" and optionally "Provider".

.PARAMETER Name
One or more module names to install from Root\Nuget.

.PARAMETER Scope
Install scope: CurrentUser (default) or AllUsers.

.EXAMPLE
PS> Install-ModulesFromRepoFolder -Folder C:\repo -Name Pester,PSScriptAnalyzer
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Folder,
        [Parameter(Mandatory, Position=1)]
        [string[]]$Name,
        [ValidateSet("CurrentUser","AllUsers")]
        [string]$Scope = "CurrentUser"
    )

    if (-not (Test-Path -LiteralPath $Folder)) {
        throw "Folder not found: $Folder"
    }

    $nugetDir    = Join-Path $Folder "Nuget"
    $providerDir = Join-Path $Folder "Provider"

    if (-not (Test-Path -LiteralPath $nugetDir)) {
        throw "Required subfolder missing: $nugetDir"
    }

    # 1) Ensure NuGet provider is available offline by copying from Provider if needed.
    $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
    if (-not $nuget) {
        if (-not (Test-Path -LiteralPath $providerDir)) {
            throw "NuGet provider not found. Expected staged provider under '$providerDir'."
        }
        $targetProviderRoot = Join-Path $Env:ProgramFiles "PackageManagement\ProviderAssemblies\NuGet"
        if (-not (Test-Path -LiteralPath $targetProviderRoot)) {
            New-Item -ItemType Directory -Path $targetProviderRoot -Force | Out-Null
        }
        try {
            Copy-Item -Path (Join-Path $providerDir "*") -Destination $targetProviderRoot -Recurse -Force -ErrorAction Stop
        } catch {
            throw "Failed to copy NuGet provider DLLs to '$targetProviderRoot': $($_.Exception.Message)"
        }
        $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
        if (-not $nuget) { throw "NuGet provider bootstrap failed after copy." }
    }

    # 2) Register a temporary repository pointing to Root\Nuget.
    $repoName = ("TempRepo_{0}" -f ([Guid]::NewGuid().ToString("N").Substring(0,8)))
    Register-PSRepository -Name $repoName -SourceLocation $nugetDir -PublishLocation $nugetDir -InstallationPolicy Trusted

    try {
        # 3) Priority install to upgrade the package stack if present in folder or requested.
        $priority = @("PackageManagement","PowerShellGet")

        function Test-PackagePresent([string]$moduleName, [string]$rootNuget) {
            $pattern = Join-Path $rootNuget ("{0}*.nupkg" -f $moduleName)
            return (Test-Path -Path $pattern)
        }

        foreach ($m in $priority) {
            if (($Name -contains $m) -or (Test-PackagePresent -moduleName $m -rootNuget $nugetDir)) {
                try {
                    Install-Module -Name $m -Repository $repoName -Scope $Scope -Force -ErrorAction Stop
                } catch {
                    Write-Error "Failed to install priority module '$m' from '$nugetDir': $($_.Exception.Message)"
                }
            }
        }

        # Install remaining requested modules (excluding priority ones).
        $remaining = $Name | Where-Object { $priority -notcontains $_ }
        foreach ($n in $remaining) {
            try {
                Install-Module -Name $n -Repository $repoName -Scope $Scope -Force -ErrorAction Stop
            } catch {
                Write-Error "Failed to install '$n' from '$nugetDir': $($_.Exception.Message)"
            }
        }
    }
    finally {
        # 4) Always unregister the temporary repo.
        try { Unregister-PSRepository -Name $repoName -ErrorAction SilentlyContinue } catch { }
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
            if ($mv) { $p["RequiredVersion"] = $mv }
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
CurrentUser (default) or AllUsers.

.EXAMPLE
PS> Install-ModulesFromRepoFolder -Folder C:\repo -Name Pester,PSScriptAnalyzer
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Folder,
        [Parameter(Mandatory, Position=1)]
        [string[]]$Name,
        [ValidateSet("CurrentUser","AllUsers")]
        [string]$Scope = "CurrentUser"
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

    # Determine elevation and pick provider target accordingly
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $targetProviderRoot = if ($isAdmin -or $Scope -eq "AllUsers") {
        Join-Path $Env:ProgramFiles "PackageManagement\ProviderAssemblies\NuGet"
    } else {
        Join-Path $Env:LOCALAPPDATA "PackageManagement\ProviderAssemblies\NuGet"
    }

    # Ensure NuGet provider from Provider if missing
    $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
    if (-not $nuget) {
        Write-Host "[INFO] NuGet provider not found. Attempting offline bootstrap from Provider folder..."
        if (-not (Test-Path -LiteralPath $providerDir)) {
            throw ("NuGet provider not found. Expected staged provider under '{0}'." -f $providerDir)
        }
        if (-not (Test-Path -LiteralPath $targetProviderRoot)) {
            New-Item -ItemType Directory -Path $targetProviderRoot -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $providerDir "*") -Destination $targetProviderRoot -Recurse -Force -ErrorAction Stop
        $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
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
                    Install-Module -Name $m -Repository $repoName -Scope $Scope -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
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
                Install-Module -Name $n -Repository $repoName -Scope $Scope -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
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

    # Return staged package paths for confirmation
    Get-ChildItem -LiteralPath $nugetDir -Filter *.nupkg | Select-Object -ExpandProperty FullName
}

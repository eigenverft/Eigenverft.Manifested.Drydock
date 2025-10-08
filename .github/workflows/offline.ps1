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


#Save-PSBootstrapPayload -ShareRoot C:\temp\psboot -Modules @('PowerShellGet','PackageManagement','Eigenverft.Manifested.Drydock') -IncludeNuGetProvider
#Install-PowerShellBitsFromShare -ShareRoot C:\temp\psboot
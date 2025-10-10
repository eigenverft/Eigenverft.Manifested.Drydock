function Register-LocalGalleryRepository {
    <#
    .SYNOPSIS
        Registers a local PowerShell repository for gallery modules.

    .DESCRIPTION
        This function ensures that the specified local repository folder exists, removes any existing
        repository with the given name, and registers the repository with a Trusted installation policy.

    .PARAMETER RepositoryPath
        The file system path to the local repository folder. Default is "$HOME/source/gallery".

    .PARAMETER RepositoryName
        The name to assign to the registered repository. Default is "LocalGallery".

    .EXAMPLE
        Register-LocalGalleryRepository
        Registers the local repository using the default path and repository name.

    .EXAMPLE
        Register-LocalGalleryRepository -RepositoryPath "C:\MyRepo" -RepositoryName "MyGallery"
        Registers the repository at "C:\MyRepo" with the name "MyGallery".
    #>
    [CmdletBinding()]
    [alias("rlgr")]
    param(
        [string]$RepositoryPath = "$HOME/source/gallery",
        [string]$RepositoryName = "LocalGallery"
    )

    # Normalize the repository path by replacing forward and backslashes with the platform's directory separator.
    $RepositoryPath = $RepositoryPath -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar

    # Ensure the local repository folder exists; if not, create it.
    if (-not (Test-Path -Path $RepositoryPath)) {
        New-Item -ItemType Directory -Path $RepositoryPath | Out-Null
    }

    # If a repository with the specified name exists, unregister it.
    if (Get-PSRepository -Name $RepositoryName -ErrorAction SilentlyContinue) {
        Write-Host "Repository '$RepositoryName' already exists. Removing it." -ForegroundColor Yellow
        Unregister-PSRepository -Name $RepositoryName
    }

    # Register the local PowerShell repository with a Trusted installation policy.
    Register-PSRepository -Name $RepositoryName -SourceLocation $RepositoryPath -InstallationPolicy Trusted

    Write-Host "Local repository '$RepositoryName' registered at: $RepositoryPath" -ForegroundColor Green
}

function Convert-DateTimeToVersion64SecondsString {
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
        PS C:\> $result = Convert-DateTimeToVersion64SecondsString -VersionBuild 1 -VersionMajor 0
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

function Update-ModuleIfNewer {
    <#
    .SYNOPSIS
        Installs or updates a module from a repository only if a newer version is available.

    .DESCRIPTION
        This function uses Find-Module to search for a module (default repository is PSGallery) and compares the
        remote version with the locally installed version (if any) using Get-InstalledModule. If the module is not installed
        or the remote version is newer, it then installs the module using Install-Module. This prevents forcing a download
        when the installed module is already up to date.

    .PARAMETER ModuleName
        The name of the module to check and install/update.

    .PARAMETER Repository
        The repository from which to search for the module. Defaults to 'PSGallery'.

    .EXAMPLE
        PS C:\> Update-ModuleIfNewer -ModuleName 'STROM.NANO.PSWH.CICD'
        Searches PSGallery for the module 'STROM.NANO.PSWH.CICD' and installs it only if it is not installed or if a newer version is available.
    #>
    [CmdletBinding()]
    [alias("umn")]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleName,

        [Parameter(Mandatory = $false)]
        [string]$Repository = 'PSGallery'
    )

    try {
        Write-Verbose "Searching for module '$ModuleName' in repository '$Repository'..."
        $remoteModule = Find-Module -Name $ModuleName -Repository $Repository -ErrorAction Stop

        if (-not $remoteModule) {
            Write-Error "Module '$ModuleName' not found in repository '$Repository'."
            return
        }

        $remoteVersion = [version]$remoteModule.Version

        # Check if the module is installed locally.
        $localModule = Get-InstalledModule -Name $ModuleName -ErrorAction SilentlyContinue

        if ($localModule) {
            $localVersion = [version]$localModule.Version
            if ($remoteVersion -gt $localVersion) {
                Write-Host "A newer version ($remoteVersion) is available (local version: $localVersion). Installing update..."
                Install-Module -Name $ModuleName -Repository $Repository -Force
            }
            else {
                Write-Host "The installed module ($localVersion) is up to date."
            }
        }
        else {
            Write-Host "Module '$ModuleName' is not installed. Installing version $remoteVersion..."
            Install-Module -Name $ModuleName -Repository $Repository -Force
        }
    }
    catch {
        Write-Error "An error occurred: $_"
    }
}

function Remove-OldModuleVersions {
    <#
    .SYNOPSIS
        Removes older versions of an installed PowerShell module, keeping only the latest version.

    .DESCRIPTION
        This function retrieves all installed versions of a specified module, sorts them by version in descending
        order (so that the latest version is first), and removes all versions except the latest one.
        It helps clean up local installations accumulated from repeated updates.

    .PARAMETER ModuleName
        The name of the module for which to remove older versions. Only versions beyond the latest one are removed.

    .EXAMPLE
        PS C:\> Remove-OldModuleVersions -ModuleName 'STROM.NANO.PSWH.CICD'
        Removes all installed versions of 'STROM.NANO.PSWH.CICD' except for the latest version.
    #>
    [CmdletBinding()]
    [alias("romv")]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleName
    )

    try {
        # Retrieve all installed versions of the module.
        $installedModules = Get-InstalledModule -Name $ModuleName -AllVersions -ErrorAction SilentlyContinue

        if (-not $installedModules) {
            Write-Host "No installed module found with the name '$ModuleName'." -ForegroundColor Yellow
            return
        }

        # Sort installed versions descending; latest version comes first.
        $sortedModules = $installedModules | Sort-Object -Property Version -Descending

        # Retain the latest version (first item) and select all older versions.
        $latestModule = $sortedModules[0]
        $oldModules = $sortedModules | Select-Object -Skip 1

        if (-not $oldModules) {
            Write-Host "Only one version of '$ModuleName' is installed. Nothing to remove." -ForegroundColor Green
            return
        }

        foreach ($module in $oldModules) {
            Write-Host "Removing $ModuleName version $($module.Version)..." -ForegroundColor Cyan
            Uninstall-Module -Name $ModuleName -RequiredVersion $module.Version -Force
        }
        Write-Host "Old versions of '$ModuleName' have been removed. Latest version $($latestModule.Version) is retained." -ForegroundColor Green
    }
    catch {
        Write-Error "An error occurred while removing old versions: $_"
    }
}

function Install-UserModule {
    <#
    .SYNOPSIS
      Installs a module for the current user.
      
    .DESCRIPTION
      This wrapper function calls Install-Module with the -Scope CurrentUser parameter,
      ensuring that modules are installed for the current user.
      
    .PARAMETER Args
      Additional parameters for Install-Module.
      
    .EXAMPLE
      Install-UserModule -Name Pester -Force
      Installs the Pester module for the current user.
    #>
    [alias("ium")]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        $Args
    )
    Install-Module -Scope CurrentUser @Args
}

function Initialize-DotNet {
    <#
    .SYNOPSIS
        Installs specified .NET channels and sets environment variables for both the current session and the user profile.

    .DESCRIPTION
        This function performs the following actions:
        
          1. For each provided channel (defaulting to 8.0 and 9.0 if none are specified):
             - Sets TLS12 as the security protocol.
             - Downloads and executes the dotnet-install.ps1 script using Invoke-WebRequest with RawContent,
               and passes the -channel parameter.
          
          2. Sets the DOTNET_ROOT environment variable to "$HOME\.dotnet" for the user and current session.
          3. Updates the user's PATH environment variable to include both DOTNET_ROOT and the tools folder
             ("$HOME\.dotnet\tools") and updates the current session PATH accordingly.

    .PARAMETER Channels
        An array of .NET channels to install. If omitted, the function defaults to installing channels 8.0 and 9.0.

    .EXAMPLE
        PS C:\> Initialize-DotNet
        Installs .NET channels 8.0 and 9.0, and configures the environment variables for immediate and persistent use.

    .EXAMPLE
        PS C:\> Initialize-DotNet -Channels @("2.1","2.2","3.0","3.1","5.0", "6.0", "7.0", "8.0", "9.0")
        Installs the specified .NET channels and configures the environment variables.
    #>
    [CmdletBinding()]
    [alias("idot")]
    param(
        [string[]]$Channels = @("8.0", "9.0")
    )

    $dotnetInstallUrl = 'https://dot.net/v1/dotnet-install.ps1'

    foreach ($channel in $Channels) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "Installing .NET channel $channel..." -ForegroundColor Cyan
        & ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing $dotnetInstallUrl))) -channel $channel -InstallDir "$HOME\.dotnet"
    }

    # Set DOTNET_ROOT environment variable for both persistent and current session.
    $dotnetRoot = "$HOME\.dotnet"
    [Environment]::SetEnvironmentVariable('DOTNET_ROOT', $dotnetRoot, 'User')
    $env:DOTNET_ROOT = $dotnetRoot
    Write-Host "DOTNET_ROOT set to $dotnetRoot" -ForegroundColor Green
    [Environment]::SetEnvironmentVariable('DOTNET_CLI_TELEMETRY_OPTOUT', 'true', 'User')
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = 'true'
    Write-Host "DOTNET_CLI_TELEMETRY_OPTOUT set to true" -ForegroundColor Green

    # Define the tools folder.
    $toolsFolder = "$dotnetRoot\tools"

    # Update PATH to include DOTNET_ROOT and the tools folder for persistent storage.
    $currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $pathsToAdd = @()

    if (-not $currentPath.ToLower().Contains($dotnetRoot.ToLower())) {
        $pathsToAdd += $dotnetRoot
    }
    if (-not $currentPath.ToLower().Contains($toolsFolder.ToLower())) {
        $pathsToAdd += $toolsFolder
    }
    if ($pathsToAdd.Count -gt 0) {
        $newPath = "$currentPath;" + ($pathsToAdd -join ';')
        [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
        # Also update the current session's PATH immediately.
        $env:PATH = $newPath
        Write-Host "PATH updated to include: $($pathsToAdd -join ', ')" -ForegroundColor Green
    }
    else {
        Write-Host "PATH already contains DOTNET_ROOT and tools folder." -ForegroundColor Yellow
    }
}


function Initialize-NugetRepositorys {
    <#
    .SYNOPSIS
        Initializes the default NuGet package sources using the dotnet CLI.

    .DESCRIPTION
        This function uses the dotnet CLI to manage NuGet sources. It retrieves the currently registered
        sources via 'dotnet nuget list source' and for each default source defined below, it checks:
          - If the source URL is not found, it adds the source.
          - If the source is found but is marked as [Disabled], it removes it and re-adds it.
        The function currently registers the following default sources:
          • nuget.org        : https://api.nuget.org/v3/index.json
          • int.nugettest.org: https://apiint.nugettest.org/v3/index.json

    .EXAMPLE
        Initialize-NugetRepositorys
        Invokes the dotnet CLI to ensure that the default NuGet sources are registered and enabled.
    #>
    [CmdletBinding()]
    [alias("inugetx")]
    param()
    # Define the default NuGet sources using v3 endpoints.
    $defaultSources = @(
        [PSCustomObject]@{ Name = "nuget.org";          Location = "https://api.nuget.org/v3/index.json" },
        [PSCustomObject]@{ Name = "int.nugettest.org";  Location = "https://apiint.nugettest.org/v3/index.json" }
    )

    Write-Host "Retrieving registered NuGet sources using dotnet CLI..." -ForegroundColor Cyan
    $listOutput = dotnet nuget list source 2>&1
    $lines = $listOutput -split "`n"

    foreach ($source in $defaultSources) {
        $foundIndex = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match [regex]::Escape($source.Location)) {
                $foundIndex = $i
                break
            }
        }
        if ($foundIndex -ne $null) {
            # Assume the preceding line contains the name and status, e.g., " 1.  nuget.org [Enabled]"
            $statusLine = if ($foundIndex -gt 0) { $lines[$foundIndex - 1] } else { "" }
            if ($statusLine -match '^\s*\d+\.\s*(?<Name>\S+)\s*\[(?<Status>\w+)\]') {
                $registeredName = $Matches["Name"]
                $status = $Matches["Status"]
                if ($status -eq "Disabled") {
                    Write-Host "Source '$registeredName' ($($source.Location)) is disabled. Removing and re-adding it as enabled." -ForegroundColor Yellow
                    dotnet nuget remove source $registeredName
                    Write-Host "Adding source '$($source.Name)' with URL '$($source.Location)'." -ForegroundColor Green
                    dotnet nuget add source $source.Location --name $source.Name
                }
                else {
                    Write-Host "Source '$registeredName' with URL '$($source.Location)' is already registered and enabled. Skipping." -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "Could not parse status for source with URL '$($source.Location)'. Skipping." -ForegroundColor Red
            }
        }
        else {
            Write-Host "Source '$($source.Name)' not found. Registering it." -ForegroundColor Green
            dotnet nuget add source $source.Location --name $source.Name
        }
    }
}

function Initialize-NugetRepositories {
    <#
    .SYNOPSIS
        Initializes the default NuGet package sources.

    .DESCRIPTION
        This function registers the default NuGet package sources if they are not already present.
        It uses enhanced logic: if a repository with a matching URL exists but is not trusted,
        it will be re-registered with the Trusted flag. If the repository exists and is already trusted,
        it is skipped.

    .EXAMPLE
        Init-NugetRepositorys
        Initializes and registers the default NuGet package sources, ensuring they are trusted.
    #>
    [CmdletBinding()]
    [alias("inuget")]
    param()
    # Define the default NuGet repository sources.
    $defaultSources = @(
        [PSCustomObject]@{ Name = "nuget.org";         Location = "https://api.nuget.org/v3/index.json" },
        [PSCustomObject]@{ Name = "int.nugettest.org"; Location = "https://apiint.nugettest.org/v3/index.json" }
    )

    # Retrieve the currently registered NuGet package sources.
    $existingSources = Get-PackageSource -ProviderName NuGet -ErrorAction SilentlyContinue

    foreach ($source in $defaultSources) {
        $found = $existingSources | Where-Object { $_.Location -eq $source.Location }
        if ($found) {
            # Check if the found source is trusted.
            if (-not $($found.IsTrusted)) {
                Write-Host "Repository '$($source.Name)' exists but is not trusted. Updating trust setting." -ForegroundColor Yellow
                # Unregister the untrusted source and re-register it with the Trusted flag.
                Unregister-PackageSource -Name $found.Name -ProviderName NuGet -Force -ErrorAction SilentlyContinue
                Register-PackageSource -Name $source.Name -Location $source.Location -ProviderName NuGet -Trusted
            }
            else {
                Write-Host "Repository '$($source.Name)' with URL '$($source.Location)' is already registered and trusted. Skipping." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "Registering repository '$($source.Name)' with URL '$($source.Location)'." -ForegroundColor Green
            Register-PackageSource -Name $source.Name -Location $source.Location -ProviderName NuGet -Trusted | Out-Null
        }
    }
}





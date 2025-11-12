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


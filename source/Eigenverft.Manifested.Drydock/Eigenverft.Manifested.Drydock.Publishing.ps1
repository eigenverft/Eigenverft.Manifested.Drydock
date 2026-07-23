function Publish-PowerShellModuleRelease {
    <#
    .SYNOPSIS
        Publishes one PowerShell module release to one target.

    .DESCRIPTION
        Provides a single-target publishing abstraction for CI/CD scripts. Each invocation publishes
        exactly one module directory to exactly one target. Call the function repeatedly with separate
        parameter hashtables when a release must be published to multiple destinations.

        Supported targets:
        - Local: creates a local PowerShell repository, publishes to it, and removes the registration.
        - PowerShellRepository: registers and publishes to a caller-defined PowerShellGet repository.
        - GitHubPackages: configures both dotnet NuGet and PowerShellGet for GitHub Packages, publishes,
          and removes both temporary registrations.
        - PSGallery: publishes directly to the registered PSGallery repository.

        GitHub Packages uses an explicit PSCredential by default. The legacy implicit-credential path
        is available only through -UseLegacyGitHubRegistration because its behavior differs between
        PowerShell host versions.

    .PARAMETER Path
        Directory containing the PowerShell module manifest to publish.

    .PARAMETER Target
        Exactly one publish target: Local, PowerShellRepository, GitHubPackages, or PSGallery.

    .PARAMETER RepositoryName
        Repository name used by Local, PowerShellRepository, or GitHubPackages. Target-specific defaults
        are LocalPowershellGallery and github.

    .PARAMETER RepositoryPath
        Local repository directory for Target Local. Default: $HOME/source/LocalPowershellGallery.

    .PARAMETER SourceLocation
        Source endpoint for Target PowerShellRepository.

    .PARAMETER PublishLocation
        Publish endpoint for Target PowerShellRepository. Defaults to SourceLocation.

    .PARAMETER InstallationPolicy
        PowerShellGet installation policy used for temporary repository registrations.

    .PARAMETER RepositoryCredential
        Optional credential used while registering Target PowerShellRepository.

    .PARAMETER ApiKey
        NuGet API key used by Target PowerShellRepository or PSGallery.

    .PARAMETER GitHubOwner
        GitHub organization or user owning the package feed.

    .PARAMETER GitHubToken
        GitHub token used both for the NuGet source and module publication.

    .PARAMETER UseLegacyGitHubRegistration
        Omits -Credential from Register-PSRepository for GitHub Packages. This reproduces the historical
        implicit behavior and should only be used for controlled compatibility diagnostics.

    .PARAMETER KeepRepositoryRegistration
        Keeps temporary PowerShellGet and dotnet NuGet registrations after publication. By default,
        temporary registrations are removed in a finally block.

    .PARAMETER PassThru
        Returns one result object. Without PassThru, the function emits no pipeline object.

    .EXAMPLE
        $publishParametersTargetLocal = @{
            Path           = $manifestFile.DirectoryName
            Target         = 'Local'
            RepositoryName = 'LocalPowershellGallery'
        }
        Publish-PowerShellModuleRelease @publishParametersTargetLocal

    .EXAMPLE
        $publishParametersTargetGitHub = @{
            Path           = $manifestFile.DirectoryName
            Target         = 'GitHubPackages'
            RepositoryName = 'github'
            GitHubOwner    = 'eigenverft'
            GitHubToken    = $NuGetGitHubPush
        }
        Publish-PowerShellModuleRelease @publishParametersTargetGitHub

    .EXAMPLE
        $publishParametersTargetPsGallery = @{
            Path      = $manifestFile.DirectoryName
            Target    = 'PSGallery'
            ApiKey    = $PsGalleryApiKey
        }
        Publish-PowerShellModuleRelease @publishParametersTargetPsGallery

    .EXAMPLE
        $publishParametersTargetTestGallery = @{
            Path             = $manifestFile.DirectoryName
            Target           = 'PowerShellRepository'
            RepositoryName   = 'PSGalleryTest'
            SourceLocation   = $testGallerySource
            PublishLocation  = $testGalleryPublish
            ApiKey           = $testGalleryApiKey
        }
        Publish-PowerShellModuleRelease @publishParametersTargetTestGallery
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Local', 'PowerShellRepository', 'GitHubPackages', 'PSGallery')]
        [string]$Target,

        [Parameter()]
        [string]$RepositoryName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath = "$HOME/source/LocalPowershellGallery",

        [Parameter()]
        [string]$SourceLocation,

        [Parameter()]
        [string]$PublishLocation,

        [Parameter()]
        [ValidateSet('Trusted', 'Untrusted')]
        [string]$InstallationPolicy = 'Trusted',

        [Parameter()]
        [AllowNull()]
        [System.Management.Automation.PSCredential]$RepositoryCredential,

        [Parameter()]
        [string]$ApiKey,

        [Parameter()]
        [string]$GitHubOwner,

        [Parameter()]
        [string]$GitHubToken,

        [Parameter()]
        [switch]$UseLegacyGitHubRegistration,

        [Parameter()]
        [switch]$KeepRepositoryRegistration,

        [Parameter()]
        [switch]$PassThru
    )

    function local:Write-PublishReleaseLog {
        [Diagnostics.CodeAnalysis.SuppressMessage('PSUseApprovedVerbs', '')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,

            [Parameter()]
            [ValidateSet('DBG', 'INF', 'WRN')]
            [string]$Level = 'INF'
        )

        if (Get-Command -Name 'Write-ConsoleLog' -ErrorAction SilentlyContinue) {
            Write-ConsoleLog -Message $Message -Level $Level
        }
        else {
            Write-Host "[$Level] $Message"
        }
    }

    function local:Assert-PublishReleaseString {
        [Diagnostics.CodeAnalysis.SuppressMessage('PSUseApprovedVerbs', '')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [string]$Value,

            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$ParameterName,

            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$TargetName
        )

        if ([string]::IsNullOrWhiteSpace($Value)) {
            throw "Target '$TargetName' requires parameter '$ParameterName'."
        }
    }

    $moduleDirectory = $null
    try {
        $moduleDirectory = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    }
    catch {
        throw "Module path '$Path' could not be resolved. $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $moduleDirectory -PathType Container)) {
        throw "Module path '$moduleDirectory' is not a directory."
    }

    $manifestFile = Get-ChildItem -LiteralPath $moduleDirectory -Filter '*.psd1' -File -ErrorAction Stop |
        Select-Object -First 1

    if ($null -eq $manifestFile) {
        throw "No PowerShell module manifest was found in '$moduleDirectory'."
    }

    $manifestInfo = Test-ModuleManifest -Path $manifestFile.FullName -ErrorAction Stop
    $moduleName = [string]$manifestInfo.Name
    $moduleVersion = [string]$manifestInfo.Version

    if ([string]::IsNullOrWhiteSpace($moduleName)) {
        $moduleName = [string]$manifestFile.BaseName
    }

    if ($UseLegacyGitHubRegistration -and $Target -ne 'GitHubPackages') {
        throw '-UseLegacyGitHubRegistration is valid only for Target GitHubPackages.'
    }

    $effectiveRepositoryName = $RepositoryName
    $effectiveSourceLocation = $SourceLocation
    $effectivePublishLocation = $PublishLocation
    $authenticationMode = 'None'
    $registeredPsRepository = $false
    $registeredDotnetSource = $false
    $published = $false
    $cleanupRequested = -not $KeepRepositoryRegistration
    $cleanupCompleted = $true
    $operationError = $null

    $result = [ordered]@{
        Target                 = $Target
        ModuleName             = $moduleName
        ModuleVersion          = $moduleVersion
        ModulePath             = $moduleDirectory
        RepositoryName         = $null
        SourceLocation         = $null
        AuthenticationMode     = $authenticationMode
        Published              = $false
        CleanupRequested       = $cleanupRequested
        CleanupCompleted       = $false
        PowerShellVersion      = [string]$PSVersionTable.PSVersion
    }

    try {
        switch ($Target) {
            'Local' {
                if ([string]::IsNullOrWhiteSpace($effectiveRepositoryName)) {
                    $effectiveRepositoryName = 'LocalPowershellGallery'
                }

                $effectiveSourceLocation = $RepositoryPath
                $result.RepositoryName = $effectiveRepositoryName
                $result.SourceLocation = $effectiveSourceLocation

                if ($PSCmdlet.ShouldProcess(
                    "$moduleName $moduleVersion -> $effectiveRepositoryName",
                    'Publish PowerShell module release to local repository')) {

                    Write-PublishReleaseLog -Message (
                        "Publishing module '{0}' version '{1}' to local repository '{2}'." -f
                        $moduleName, $moduleVersion, $effectiveRepositoryName
                    )

                    $effectiveRepositoryName = Register-LocalPSGalleryRepository `
                        -RepositoryPath $RepositoryPath `
                        -RepositoryName $effectiveRepositoryName `
                        -InstallationPolicy $InstallationPolicy

                    $registeredPsRepository = $true
                    $result.RepositoryName = $effectiveRepositoryName

                    Publish-Module `
                        -Path $moduleDirectory `
                        -Repository $effectiveRepositoryName `
                        -ErrorAction Stop | Out-Null

                    $published = $true
                }
            }

            'PowerShellRepository' {
                Assert-PublishReleaseString -Value $effectiveRepositoryName -ParameterName 'RepositoryName' -TargetName $Target
                Assert-PublishReleaseString -Value $effectiveSourceLocation -ParameterName 'SourceLocation' -TargetName $Target

                if ([string]::IsNullOrWhiteSpace($effectivePublishLocation)) {
                    $effectivePublishLocation = $effectiveSourceLocation
                }

                $result.RepositoryName = $effectiveRepositoryName
                $result.SourceLocation = $effectiveSourceLocation
                if ($null -ne $RepositoryCredential) {
                    $authenticationMode = 'ExplicitCredential'
                }
                elseif (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
                    $authenticationMode = 'ApiKey'
                }
                $result.AuthenticationMode = $authenticationMode

                if ($PSCmdlet.ShouldProcess(
                    "$moduleName $moduleVersion -> $effectiveRepositoryName",
                    'Publish PowerShell module release to custom PowerShell repository')) {

                    $existingRepository = Get-PSRepository -Name $effectiveRepositoryName -ErrorAction SilentlyContinue
                    if ($null -ne $existingRepository) {
                        Write-PublishReleaseLog -Message (
                            "Removing existing PowerShell repository registration '{0}'." -f $effectiveRepositoryName
                        ) -Level 'WRN'
                        Unregister-PSRepository -Name $effectiveRepositoryName -ErrorAction Stop | Out-Null
                    }

                    $repositoryRegistration = @{
                        Name                  = $effectiveRepositoryName
                        SourceLocation        = $effectiveSourceLocation
                        PublishLocation       = $effectivePublishLocation
                        ScriptSourceLocation  = $effectiveSourceLocation
                        ScriptPublishLocation = $effectivePublishLocation
                        InstallationPolicy    = $InstallationPolicy
                        ErrorAction           = 'Stop'
                    }

                    if ($null -ne $RepositoryCredential) {
                        $repositoryRegistration.Credential = $RepositoryCredential
                    }

                    Register-PSRepository @repositoryRegistration | Out-Null
                    $registeredPsRepository = $true

                    $publishParameters = @{
                        Path        = $moduleDirectory
                        Repository  = $effectiveRepositoryName
                        ErrorAction = 'Stop'
                    }
                    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
                        $publishParameters.NuGetApiKey = $ApiKey
                    }

                    Publish-Module @publishParameters | Out-Null
                    $published = $true
                }
            }

            'GitHubPackages' {
                Assert-PublishReleaseString -Value $GitHubOwner -ParameterName 'GitHubOwner' -TargetName $Target
                Assert-PublishReleaseString -Value $GitHubToken -ParameterName 'GitHubToken' -TargetName $Target

                if ([string]::IsNullOrWhiteSpace($effectiveRepositoryName)) {
                    $effectiveRepositoryName = 'github'
                }

                $effectiveSourceLocation = "https://nuget.pkg.github.com/$GitHubOwner/index.json"
                $effectivePublishLocation = $effectiveSourceLocation
                $authenticationMode = if ($UseLegacyGitHubRegistration) {
                    'LegacyImplicitCredential'
                }
                else {
                    'ExplicitCredential'
                }

                $result.RepositoryName = $effectiveRepositoryName
                $result.SourceLocation = $effectiveSourceLocation
                $result.AuthenticationMode = $authenticationMode

                if ($PSCmdlet.ShouldProcess(
                    "$moduleName $moduleVersion -> GitHub Packages/$GitHubOwner",
                    'Publish PowerShell module release to GitHub Packages')) {

                    if (-not (Get-Command -Name 'dotnet' -ErrorAction SilentlyContinue)) {
                        throw "Target '$Target' requires the dotnet CLI."
                    }

                    $existingRepository = Get-PSRepository -Name $effectiveRepositoryName -ErrorAction SilentlyContinue
                    if ($null -ne $existingRepository) {
                        Write-PublishReleaseLog -Message (
                            "Removing existing PowerShell repository registration '{0}'." -f $effectiveRepositoryName
                        ) -Level 'WRN'
                        Unregister-PSRepository -Name $effectiveRepositoryName -ErrorAction Stop | Out-Null
                    }

                    Unregister-LocalNuGetDotNetPackageSource -SourceName $effectiveRepositoryName

                    Invoke-ProcessTyped `
                        -Executable 'dotnet' `
                        -Arguments @(
                            'nuget', 'add', 'source',
                            '--username', $GitHubOwner,
                            '--password', $GitHubToken,
                            '--store-password-in-clear-text',
                            '--name', $effectiveRepositoryName,
                            $effectiveSourceLocation
                        ) `
                        -CaptureOutput $false `
                        -CaptureOutputDump $false `
                        -HideValues @($GitHubToken) | Out-Null

                    $registeredDotnetSource = $true

                    $repositoryRegistration = @{
                        Name                  = $effectiveRepositoryName
                        SourceLocation        = $effectiveSourceLocation
                        PublishLocation       = $effectivePublishLocation
                        ScriptSourceLocation  = $effectiveSourceLocation
                        ScriptPublishLocation = $effectivePublishLocation
                        InstallationPolicy    = $InstallationPolicy
                        ErrorAction           = 'Stop'
                    }

                    if ($UseLegacyGitHubRegistration) {
                        Write-PublishReleaseLog -Message (
                            'Legacy implicit GitHub repository authentication is enabled. ' +
                            'This behavior is host-version dependent and is known to differ between PowerShell 7.4 and 7.6.'
                        ) -Level 'WRN'
                    }
                    else {
                        $secureToken = ConvertTo-SecureString $GitHubToken -AsPlainText -Force
                        $githubCredential = [System.Management.Automation.PSCredential]::new(
                            $GitHubOwner,
                            $secureToken
                        )
                        $repositoryRegistration.Credential = $githubCredential
                    }

                    Register-PSRepository @repositoryRegistration | Out-Null
                    $registeredPsRepository = $true

                    Publish-Module `
                        -Path $moduleDirectory `
                        -Repository $effectiveRepositoryName `
                        -NuGetApiKey $GitHubToken `
                        -ErrorAction Stop | Out-Null

                    $published = $true
                }
            }

            'PSGallery' {
                Assert-PublishReleaseString -Value $ApiKey -ParameterName 'ApiKey' -TargetName $Target

                $effectiveRepositoryName = 'PSGallery'
                $authenticationMode = 'ApiKey'
                $result.RepositoryName = $effectiveRepositoryName
                $result.SourceLocation = 'PSGallery'
                $result.AuthenticationMode = $authenticationMode

                if ($PSCmdlet.ShouldProcess(
                    "$moduleName $moduleVersion -> PSGallery",
                    'Publish PowerShell module release to PSGallery')) {

                    Publish-Module `
                        -Path $moduleDirectory `
                        -Repository 'PSGallery' `
                        -NuGetApiKey $ApiKey `
                        -ErrorAction Stop | Out-Null

                    $published = $true
                }
            }
        }
    }
    catch {
        $operationError = $_
    }
    finally {
        if ($cleanupRequested) {
            if ($registeredPsRepository) {
                try {
                    $registeredRepository = Get-PSRepository -Name $effectiveRepositoryName -ErrorAction SilentlyContinue
                    if ($null -ne $registeredRepository) {
                        Write-PublishReleaseLog -Message (
                            "Removing temporary PowerShell repository registration '{0}'." -f $effectiveRepositoryName
                        ) -Level 'DBG'
                        Unregister-PSRepository -Name $effectiveRepositoryName -ErrorAction Stop | Out-Null
                    }
                }
                catch {
                    $cleanupCompleted = $false
                    Write-PublishReleaseLog -Message (
                        "Failed to remove PowerShell repository registration '{0}': {1}" -f
                        $effectiveRepositoryName, $_.Exception.Message
                    ) -Level 'WRN'
                }
            }

            if ($registeredDotnetSource) {
                try {
                    Unregister-LocalNuGetDotNetPackageSource -SourceName $effectiveRepositoryName
                }
                catch {
                    $cleanupCompleted = $false
                    Write-PublishReleaseLog -Message (
                        "Failed to remove dotnet NuGet source '{0}': {1}" -f
                        $effectiveRepositoryName, $_.Exception.Message
                    ) -Level 'WRN'
                }
            }
        }
    }

    $result.Published = $published
    $result.CleanupCompleted = if ($cleanupRequested) { $cleanupCompleted } else { $null }

    if ($null -ne $operationError) {
        # Emit the original target-specific message as the public error contract after cleanup.
        throw $operationError.Exception.Message
    }

    if ($cleanupRequested -and -not $cleanupCompleted) {
        throw "Module publication completed, but cleanup of temporary repository registrations failed for '$effectiveRepositoryName'."
    }

    if ($published) {
        Write-PublishReleaseLog -Message (
            "Published module '{0}' version '{1}' to target '{2}' using repository '{3}'." -f
            $moduleName, $moduleVersion, $Target, $effectiveRepositoryName
        )
    }

    if ($PassThru) {
        return [pscustomobject]$result
    }
}

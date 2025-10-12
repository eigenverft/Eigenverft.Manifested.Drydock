param (
    [string]$POWERSHELL_GALLERY
) 

# Keep this script compatible with PowerShell 5.1 and PowerShell 7+
# Lean, pipeline-friendly style—simple, readable, and easy to modify, failfast on errors.
Write-Host "Powershell script $(Split-Path -Leaf $PSCommandPath) has started."

# Provides lightweight reachability guards for external services.
# Detection only—no installs, imports, network changes, or pushes. (e.g Test-PSGalleryConnectivity)
# Designed to short-circuit local and CI/CD workflows when dependencies are offline (e.g., skip a push if the Git host is unreachable).
. "$PSScriptRoot\cicd.bootstrap.ps1"

$remoteRessourcesOk = Test-RemoteRessourcesAvailable -Quiet

# Ensure connectivity to PowerShell Gallery before attempting module installation, if not assuming being offline, installation is present check existance with Test-ModuleAvailable
if ($remoteRessourcesOk)
{
    # Install the required modules to run this script, Eigenverft.Manifested.Drydock needs to be Powershell 5.1 and Powershell 7+ compatible
    Install-Module -Name 'Eigenverft.Manifested.Drydock' -Repository "PSGallery" -Scope CurrentUser -Force -AllowClobber -AllowPrerelease -ErrorAction Stop
}

Test-ModuleAvailable -Name 'Eigenverft.Manifested.Drydock' -IncludePrerelease -ExitIfNotFound -Quiet

# Required for updating PowerShellGet and PackageManagement providers in local PowerShell 5.x environments
Initialize-PowerShellMiniBootstrap

# Clean up previous versions of the module to avoid conflicts in local PowerShell environments
Uninstall-PreviousModuleVersions -ModuleName 'Eigenverft.Manifested.Drydock'

# Import optional integration script if it exists
Import-Script -File @("$PSScriptRoot\cicd.integration.ps1") -ErrorIfMissing
Write-IntegrationMsg -Message "This function is defined in the optional integration script. That should be integrated into this main module script."

# In the case the secrets are not passed as parameters, try to get them from the secrets file, local development or CI/CD environment
$POWERSHELL_GALLERY = Get-ConfigValue -Check $POWERSHELL_GALLERY -FilePath (Join-Path $PSScriptRoot 'cicd.secrets.json') -Property 'POWERSHELL_GALLERY'
Test-VariableValue -Variable { $POWERSHELL_GALLERY } -ExitIfNullOrEmpty -HideValue

# Verify required commands are available
if ($cmd = Test-CommandAvailable -Command "git") { Write-Host "Test-CommandAvailable: $($cmd.Name) $($cmd.Version) found at $($cmd.Source)" } else { Write-Error "git not found"; exit 1 }
if ($cmd = Test-CommandAvailable -Command "dotnet") { Write-Host "Test-CommandAvailable: $($cmd.Name) $($cmd.Version) found at $($cmd.Source)" } else { Write-Error "dotnet not found"; exit 1 }

# Preload environment information
$runEnvironment = Get-RunEnvironment
$gitTopLevelDirectory = Get-GitTopLevelDirectory
$gitCurrentBranch = Get-GitCurrentBranch
$gitCurrentBranchRoot = Get-GitCurrentBranchRoot
$gitRepositoryName = Get-GitRepositoryName
$gitRemoteUrl = Get-GitRemoteUrl

# Failfast / guard if any of the required preloaded environment information is not available
Test-VariableValue -Variable { $runEnvironment } -ExitIfNullOrEmpty
Test-VariableValue -Variable { $gitTopLevelDirectory } -ExitIfNullOrEmpty
Test-VariableValue -Variable { $gitCurrentBranch } -ExitIfNullOrEmpty
Test-VariableValue -Variable { $gitCurrentBranchRoot } -ExitIfNullOrEmpty
Test-VariableValue -Variable { $gitRepositoryName } -ExitIfNullOrEmpty
Test-VariableValue -Variable { $gitRemoteUrl } -ExitIfNullOrEmpty

# Generate deployment info based on the current branch name
$deploymentInfo = Convert-BranchToDeploymentInfo -BranchName "$gitCurrentBranch"

# Generates a version based on the current date time to verify the version functions work as expected
$generatedVersion = Convert-DateTimeTo64SecPowershellVersion -VersionBuild 0
$probeGeneratedVersion = Convert-64SecPowershellVersionToDateTime -VersionBuild $generatedVersion.VersionBuild -VersionMajor $generatedVersion.VersionMajor -VersionMinor $generatedVersion.VersionMinor 
Test-VariableValue -Variable { $generatedVersion } -ExitIfNullOrEmpty
Test-VariableValue -Variable { $probeGeneratedVersion } -ExitIfNullOrEmpty

#######

$manifestFile = Find-FilesByPattern -Path "$gitTopLevelDirectory" -Pattern "*.psd1" -ErrorAction Stop
Update-ManifestModuleVersion -ManifestPath "$($manifestFile.DirectoryName)" -NewVersion "$($generatedVersion.VersionFull)"
Update-ManifestPrerelease -ManifestPath "$($manifestFile.DirectoryName)" -NewPrerelease "$($deploymentInfo.Affix.Label)"

Write-Host "===> Testing module manifest at: $($manifestFile.FullName)" -ForegroundColor Cyan
Test-ModuleManifest -Path $($manifestFile.FullName)

if ($remoteRessourcesOk)
{
    try {
        Publish-Module -Path $($manifestFile.DirectoryName) -Repository "PSGallery" -NuGetApiKey "$POWERSHELL_GALLERY" -ErrorAction Stop    
    }
    catch {
        Write-Error "Failed to publish module: $_"
    }
}


if ($remoteRessourcesOk)
{
    if ($($runEnvironment.IsCI)) {
        Invoke-GitAddCommitPush -TopLevelDirectory "$gitTopLevelDirectory" -Folders @("$($manifestFile.DirectoryName)") -CurrentBranch "$gitCurrentBranch" -UserName "github-actions[bot]" -UserEmail "github-actions[bot]@users.noreply.github.com" -CommitMessage "Auto ver bump from CICD to $($generatedVersion.VersionFull) [skip ci]" -Tags @( "$($generatedVersion.VersionFull)-$($deploymentInfo.Affix.Label)" ) -ErrorAction Stop
    } else {
        Invoke-GitAddCommitPush -TopLevelDirectory "$gitTopLevelDirectory" -Folders @("$($manifestFile.DirectoryName)") -CurrentBranch "$gitCurrentBranch" -UserName "eigenverft" -UserEmail "eigenverft@outlook.com" -CommitMessage "Auto ver bump from local to $($generatedVersion.VersionFull) [skip ci]" -Tags @( "$($generatedVersion.VersionFull)-$($deploymentInfo.Affix.Label)" ) -ErrorAction Stop
    }
}




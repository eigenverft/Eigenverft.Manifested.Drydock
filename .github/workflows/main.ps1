param (
    [string]$POWERSHELL_GALLERY
)

#Keep this script compatible with PowerShell 5.1 and PowerShell 7+

#Install the required modules to run this script Eigenverft.Manifested.Drydock needs to be Powershell 5.1 and Powershell 7+ compatible
Install-Module -Name Eigenverft.Manifested.Drydock -Repository "PSGallery" -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop

# Required for updating PowerShellGet and PackageManagement providers in local PowerShell 5.x environments
Initialize-PowerShellMiniBootstrap

#In the case the screts are not passed as parameters, try to get them from the secrets file, local development or CI/CD environment
$POWERSHELL_GALLERY = Get-ConfigValue -Check $POWERSHELL_GALLERY -FilePath (Join-Path $PSScriptRoot 'main_secrets.json') -Property 'POWERSHELL_GALLERY'
Test-VariableValue -Variable { $POWERSHELL_GALLERY } -ExitIfNullOrEmpty -HideValue

$cicdEnvironment = $(Get-RunEnvironment).IsCI

$generatedPowershellVersion = Convert-DateTimeTo64SecPowershellVersion -VersionBuild 0
$gitTopLevelDirectory = Get-GitTopLevelDirectory
$gitCurrentBranch = Get-GitCurrentBranch
#$gitCurrentBranchRoot = Get-GitCurrentBranchRoot
#$gitRepositoryName = Get-GitRepositoryName
#$gitRemoteUrl = Get-GitRemoteUrl

Write-Host "===> generatedPowershellVersion at: $($generatedPowershellVersion.VersionFull)" -ForegroundColor Cyan
Write-Host "===> gitTopLevelDirectory at: $gitTopLevelDirectory" -ForegroundColor Cyan
Write-Host "===> gitCurrentBranch at: $gitCurrentBranch" -ForegroundColor Cyan
#Write-Host "===> gitCurrentBranchRoot at: $gitCurrentBranchRoot" -ForegroundColor Cyan
#Write-Host "===> gitRepositoryName at: $gitRepositoryName" -ForegroundColor Cyan
#Write-Host "===> gitRemoteUrl at: $gitRemoteUrl" -ForegroundColor Cyan


$manifestFile = Find-FilesByPattern -Path "$gitTopLevelDirectory" -Pattern "*.psd1" -ErrorAction Stop
Update-ManifestModuleVersion -ManifestPath "$($manifestFile.DirectoryName)" -NewVersion "$($generatedPowershellVersion.VersionFull)"
Write-Host "===> Testing module manifest at: $($manifestFile.FullName)" -ForegroundColor Cyan
Test-ModuleManifest -Path $($manifestFile.FullName)

try {
    Publish-Module -Path $($manifestFile.DirectoryName) -Repository "PSGallery" -NuGetApiKey "$POWERSHELL_GALLERY" -ErrorAction Stop    
}
catch {
    Write-Error "Failed to publish module: $_"
}

if ($cicdEnvironment -eq $true) {
    Invoke-GitAddCommitPush -TopLevelDirectory "$gitTopLevelDirectory" -ModuleFolder "$($manifestFile.DirectoryName)" -CurrentBranch "$gitCurrentBranch" -UserName "github-actions[bot]" -UserEmail "github-actions[bot]@users.noreply.github.com" -CommitMessage "Automated version bump to $($generatedPowershellVersion.VersionFull) [skip ci]" -ErrorAction Stop
} else {
    Invoke-GitAddCommitPush -TopLevelDirectory "$gitTopLevelDirectory" -ModuleFolder "$($manifestFile.DirectoryName)" -CurrentBranch "$gitCurrentBranch" -UserName "eigenverft" -UserEmail "eigenverft@outlook.com" -CommitMessage "Automated version bump to $($generatedPowershellVersion.VersionFull) [skip ci]" -ErrorAction Stop
}



param (
    [string]$POWERSHELL_GALLERY
)

Install-Module -Name Eigenverft.Manifested.Drydock -Repository "PSGallery" -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop

$POWERSHELL_GALLERY = Get-ConfigValue -Check $POWERSHELL_GALLERY -FilePath (Join-Path $PSScriptRoot 'main_secrets.json') -Property 'POWERSHELL_GALLERY'

Write-Host "===> Get-RunEnvironment" -ForegroundColor Cyan
Get-RunEnvironment

Ensure-Variable -Variable { $POWERSHELL_GALLERY } -ExitIfNullOrEmpty -HideValue

$generatedPowershellVersion = Convert-DateTimeTo64SecPowershellVersion -VersionBuild 0
$gitTopLevelDirectory = Get-GitTopLevelDirectory
$gitCurrentBranch = Get-GitCurrentBranch
#$gitCurrentBranchRoot = Get-GitCurrentBranchRoot
#$gitRepositoryName = Get-GitRepositoryName
#$gitRemoteUrl = Get-GitRemoteUrl

Write-Host "===> generatedPowershellVersion at: $($generatedPowershellVersion.VersionBuild).$($generatedPowershellVersion.VersionMajor).$($generatedPowershellVersion.VersionMinor)" -ForegroundColor Cyan
Write-Host "===> gitTopLevelDirectory at: $gitTopLevelDirectory" -ForegroundColor Cyan
Write-Host "===> gitCurrentBranch at: $gitCurrentBranch" -ForegroundColor Cyan
#Write-Host "===> gitCurrentBranchRoot at: $gitCurrentBranchRoot" -ForegroundColor Cyan
#Write-Host "===> gitRepositoryName at: $gitRepositoryName" -ForegroundColor Cyan
#Write-Host "===> gitRemoteUrl at: $gitRemoteUrl" -ForegroundColor Cyan


$manifestFile = Find-FilesByPattern -Path "$gitTopLevelDirectory" -Pattern "*.psd1" -ErrorAction Stop
Update-ManifestModuleVersion -ManifestPath "$($manifestFile.DirectoryName)" -NewVersion "$($generatedPowershellVersion.VersionBuild).$($generatedPowershellVersion.VersionMajor).$($generatedPowershellVersion.VersionMinor)"
Write-Host "===> Testing module manifest at: $($manifestFile.FullName)" -ForegroundColor Cyan
Test-ModuleManifest -Path $($manifestFile.FullName)

try {
    Publish-Module -Path $($manifestFile.DirectoryName) -Repository "PSGallery" -NuGetApiKey "$POWERSHELL_GALLERY" -ErrorAction Stop    
}
catch {
    Write-Error "Failed to publish module: $_"
}

Invoke-GitAddCommitPush -TopLevelDirectory "$gitTopLevelDirectory" -ModuleFolder "$($manifestFile.DirectoryName)" -CurrentBranch "$gitCurrentBranch"


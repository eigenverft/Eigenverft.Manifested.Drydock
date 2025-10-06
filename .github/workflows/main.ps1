param (
    [string]$POWERSHELL_GALLERY
)

Install-Module -Name Eigenverft.Manifested.Drydock -Repository "PSGallery" -Force -AllowClobber -ErrorAction Stop

Import-ScriptIfPresent -FullPath (Join-Path $PSScriptRoot 'main_secrets.ps1')
Ensure-Variable -Variable { $POWERSHELL_GALLERY } -ExitIfNullOrEmpty -HideValue

$generatedPowershellVersion = Convert-DateTimeTo64SecPowershellVersion -VersionBuild 0
$gitTopLevelDirectory = Get-GitTopLevelDirectory
$gitCurrentBranch = Get-GitCurrentBranch
$gitCurrentBranchRoot = Get-GitCurrentBranchRoot
$gitRepositoryName = Get-GitRepositoryName
$gitRemoteUrl = Get-GitRemoteUrl

Write-Host "===> gitTopLevelDirectory at: $generatedPowershellVersion" -ForegroundColor Cyan
Write-Host "===> gitTopLevelDirectory at: $gitTopLevelDirectory" -ForegroundColor Cyan
Write-Host "===> gitCurrentBranch at: $gitCurrentBranch" -ForegroundColor Cyan
Write-Host "===> gitCurrentBranchRoot at: $gitCurrentBranchRoot" -ForegroundColor Cyan
Write-Host "===> gitRepositoryName at: $gitRepositoryName" -ForegroundColor Cyan
Write-Host "===> gitRemoteUrl at: $gitRemoteUrl" -ForegroundColor Cyan

##############################

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

#Stage only module changes
# (optional, avoids ownership warnings on GH runners)
# 2) Commit without user changes (use [skip ci] for GitHub; [no ci] is not recognized)
# 4) Push
git -C "$gitTopLevelDirectory" add -v -A -- "$moduleFolder"
git -C "$gitTopLevelDirectory" config --global --add safe.directory "$gitTopLevelDirectory"
git -C "$gitTopLevelDirectory" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" commit -m "Updated from Workflow [skip ci]"
git -C "$gitTopLevelDirectory" push origin "$gitCurrentBranch"


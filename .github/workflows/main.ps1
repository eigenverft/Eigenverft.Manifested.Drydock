param (
    [string]$POWERSHELL_GALLERY
)

# If any of the parameters are empty, try loading them from a secrets file.
if ([string]::IsNullOrEmpty($POWERSHELL_GALLERY)) {
    if (Test-Path "$PSScriptRoot\main_secrets.ps1") {
        . "$PSScriptRoot\main_secrets.ps1"
        Write-Host "Secrets loaded from file."
    }
    if ([string]::IsNullOrEmpty($POWERSHELL_GALLERY))
    {
        exit 1
    }
}

#Install-Module -Name Eigenverft.Manifested.Drydock -Repository "PSGallery" -Force -AllowClobber -RequiredVersion 0.20255.47830 -ErrorAction Stop
Install-Module -Name Eigenverft.Manifested.Drydock -Repository "PSGallery" -Force -AllowClobber -ErrorAction Stop

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

# Define the path to your module folder (adjust "MyModule" as needed)
$moduleFolder = "$gitTopLevelDirectory/source/Eigenverft.Manifested.Drydock"
Update-ManifestModuleVersion -ManifestPath "$moduleFolder" -NewVersion "$($generatedPowershellVersion.VersionBuild).$($generatedPowershellVersion.VersionMajor).$($generatedPowershellVersion.VersionMinor)"
$moduleManifest = "$moduleFolder/Eigenverft.Manifested.Drydock.psd1" -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar

# Validate the module manifest
Write-Host "===> Testing module manifest at: $moduleManifest" -ForegroundColor Cyan
Test-ModuleManifest -Path $moduleManifest

try {
    Publish-Module -Path $moduleFolder -Repository "PSGallery" -NuGetApiKey "$POWERSHELL_GALLERY" -ErrorAction Stop    
}
catch {
    Write-Error "Failed to publish module: $_"
}

#Stage only module changes
# (optional, avoids ownership warnings on GH runners)
# 2) Commit without user changes (use [skip ci] for GitHub; [no ci] is not recognized)
# 4) Push
git -C "$gitTopLevelDirectory" add -v -- "$moduleFolder"
git -C "$gitTopLevelDirectory" config --global --add safe.directory "$gitTopLevelDirectory"
git -C "$gitTopLevelDirectory" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" commit -m "Updated from Workflow [skip ci]"
git -C "$gitTopLevelDirectory" push origin "$gitCurrentBranch"


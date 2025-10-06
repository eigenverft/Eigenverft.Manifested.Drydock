param (
    [string]$POWERSHELL_GALLERY
)

# If any of the parameters are empty, try loading them from a secrets file.
if ([string]::IsNullOrEmpty($POWERSHELL_GALLERY)) {
    if (Test-Path "$PSScriptRoot\cicd_secrets.ps1") {
        . "$PSScriptRoot\cicd_secrets.ps1"
        Write-Host "Secrets loaded from file."
    }
    if ([string]::IsNullOrEmpty($POWERSHELL_GALLERY))
    {
        exit 1
    }
}

Install-Module -Name BlackBytesBox.Manifested.Initialize -Repository "PSGallery" -Force -AllowClobber
Install-Module -Name BlackBytesBox.Manifested.Version -Repository "PSGallery" -Force -AllowClobber
Install-Module -Name BlackBytesBox.Manifested.Git -Repository "PSGallery" -Force -AllowClobber

Install-Module -Name Eigenverft.Manifested.Drydock -Repository "PSGallery" -Force -AllowClobber

$GeneratedPowershellVersion = Convert-DateTimeTo64SecPowershellVersion -VersionBuild 0
$gitTopLevelDirectory = Get-GitTopLevelDirectory
$gitCurrentBranch = Get-GitCurrentBranch
$gitCurrentBranchRoot = Get-GitCurrentBranchRoot
$gitRepositoryName = Get-GitRepositoryName
$gitRemoteUrl = Get-GitRemoteUrl

Write-Host "===> gitTopLevelDirectory at: $gitTopLevelDirectory" -ForegroundColor Cyan
Write-Host "===> gitCurrentBranch at: $gitCurrentBranch" -ForegroundColor Cyan
Write-Host "===> gitCurrentBranchRoot at: $gitCurrentBranchRoot" -ForegroundColor Cyan
Write-Host "===> gitRepositoryName at: $gitRepositoryName" -ForegroundColor Cyan
Write-Host "===> gitRemoteUrl at: $gitRemoteUrl" -ForegroundColor Cyan

##############################

# Define the path to your module folder (adjust "MyModule" as needed)
$moduleFolder = "$gitTopLevelDirectory/source/Eigenverft.Manifested.Drydock"
Update-ManifestModuleVersion -ManifestPath "$moduleFolder" -NewVersion "$($GeneratedPowershellVersion.VersionBuild).$($GeneratedPowershellVersion.VersionMajor).$($GeneratedPowershellVersion.VersionMinor)"
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

git -C "$gitTopLevelDirectory" add -v -- "$moduleFolder"

# (optional, avoids ownership warnings on GH runners)
git -C "$gitTopLevelDirectory" config --global --add safe.directory "$gitTopLevelDirectory"

# 2) Commit without user changes (use [skip ci] for GitHub; [no ci] is not recognized)
git -C "$gitTopLevelDirectory" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" commit -m "Updated from Workflow [skip ci]"

# 4) Push
git -C "$gitTopLevelDirectory" push origin "$gitCurrentBranch"


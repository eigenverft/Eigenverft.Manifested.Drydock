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


$GeneratedPowershellVersion = Convert-DateTimeTo64SecPowershellVersion -VersionBuild 0
$GitTopLevelDirectory = Get-GitTopLevelDirectory
##############################

# Define the path to your module folder (adjust "MyModule" as needed)
$moduleFolder = "$GitTopLevelDirectory/source/Eigenverft.Manifested.Drydock"
Update-ManifestModuleVersion -ManifestPath "$moduleFolder" -NewVersion "$($GeneratedPowershellVersion.VersionBuild).$($GeneratedPowershellVersion.VersionMajor).$($GeneratedPowershellVersion.VersionMinor)"
$moduleManifest = "$moduleFolder/Eigenverft.Manifested.Drydock.psd1" -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar

# Validate the module manifest
Write-Host "===> Testing module manifest at: $moduleManifest" -ForegroundColor Cyan
Test-ModuleManifest -Path $moduleManifest

Publish-Module -Path $moduleFolder -Repository "PSGallery" -NuGetApiKey "$POWERSHELL_GALLERY"

exit

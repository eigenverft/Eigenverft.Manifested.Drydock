param (
    [string]$POWERSHELL_GALLERY
)

<#
.SYNOPSIS
Checks whether the current user has sufficient privileges to execute an operation in the desired scope.

.PARAMETER Scope
Specifies the desired scope. This can be one of the following values: "CurrentUser" or "LocalMachine".

.EXAMPLE
The following example checks whether the current user has sufficient privileges to execute an operation in the "LocalMachine" scope:
$canExecute = CanExecuteInDesiredScope -Scope LocalMachine

.NOTES
This function has an alias "cedc" for ease of use.
#>
function CanExecuteInDesiredScope {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "")]
    [alias("cedc")]
    param (
        [ModuleScope]$Scope
    )

    $IsAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    #Microsoft just does this inside Install-PowerShellRemoting.ps1
    #if (! ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
    #Write-Error "WinRM registration requires Administrator rights. To run this cmdlet, start PowerShell with the `"Run as administrator`" option."
    #return


    if ($Scope -eq [ModuleScope]::CurrentUser) {
        return $true
    } elseif ($Scope -eq [ModuleScope]::LocalMachine) {
        if ($IsAdmin -eq $true) {
            return $true
        } elseif (CouldRunAsAdministrator) {
            # The current user is not running as admin, but is a member of the local admin group
            Write-Error "The operation cannot be executed in the desired scope due to insufficient privileges of the process. You need to run the process as an administrator."
            return $false
        } else {
            # The current user is not an administrator
            Write-Error "The operation cannot be executed in the desired scope due to insufficient privileges of the user. You need to run the process as an administrator for this you need to be member of the local Administrators group."
            return $false
        }
    }
}

<#
.SYNOPSIS
    Adds a custom enumeration type if the 'ModuleRecordState' type does not exist.

.DESCRIPTION
    The code block checks if the 'ModuleRecordState' type exists. If it does not exist, it adds a custom enumeration type named 'ModuleRecordState' with three values: 'Latest', 'Previous', and 'All'. This enumeration type is used in certain functions and scripts to specify the module version range of PowerShell modules.

.NOTES
    - This code block is used in PowerShell if there is no 'ModuleRecordState' type defined.
    - The 'ModuleRecordState' enumeration is used to indicate the desired range of module versions to be returned when searching for multiple versions of a module.
    - If the 'ModuleRecordState' type already exists, this code block has no effect.
#>

if (-not ([System.Management.Automation.PSTypeName]'ModuleRecordState').Type) {
    Add-Type @"
    public enum ModuleRecordState {
        Latest,
        Previous,
        All
    }
"@
}

<#
.SYNOPSIS
    Adds a custom enumeration type if the 'ModuleScope' type does not exist.

.DESCRIPTION
    The code block checks if the 'ModuleScope' type exists. If it does not exist, it adds a custom enumeration type named 'ModuleScope' with two values: 'CurrentUser' and 'LocalMachine'. This enumeration type is used in certain functions and scripts to specify the scope of PowerShell modules.

.NOTES
    - This code block is used in PowerShell if there is no 'ModuleScope' type defined.
    - The 'ModuleScope' enumeration is used to indicate whether a PowerShell module should be retrieved from the current user's scope or the local machine's scope.
    - If the 'ModuleScope' type already exists, this code block has no effect.
#>
if (-not ([System.Management.Automation.PSTypeName]'ModuleScope').Type) {
    Add-Type @"
    public enum ModuleScope {
        CurrentUser,
        LocalMachine,
        Process
    }
"@
}

function Initialize-NugetPackageProvider {
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
    param (
        [ModuleScope]$Scope = [ModuleScope]::CurrentUser
    )
    # Check if the current process can execute in the desired scope
    if (-not(CanExecuteInDesiredScope -Scope $Scope))
    {
        return
    }

    $nugetProvider = Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue | Where-Object Name -eq "nuget"
    if (-not($nugetProvider -and $nugetProvider.Version -ge "2.8.5.201")) {
        $originalProgressPreference = $global:ProgressPreference
        $global:ProgressPreference = 'SilentlyContinue'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope $Scope -Force | Out-Null
        $global:ProgressPreference = $originalProgressPreference
    }
}



Install-Module -Name Eigenverft.Manifested.Drydock -Repository "PSGallery" -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop



$POWERSHELL_GALLERY = Get-ConfigValue -Check $POWERSHELL_GALLERY -FilePath (Join-Path $PSScriptRoot 'main_secrets.json') -Property 'POWERSHELL_GALLERY'
Ensure-Variable -Variable { $POWERSHELL_GALLERY } -ExitIfNullOrEmpty -HideValue

Write-Host "===> Get-RunEnvironment" -ForegroundColor Cyan
Get-RunEnvironment



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


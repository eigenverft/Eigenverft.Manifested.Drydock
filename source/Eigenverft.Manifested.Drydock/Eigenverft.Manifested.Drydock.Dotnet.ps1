function Invoke-DotnetToolRestore {
<#
.SYNOPSIS
Restore .NET local tools using a manifest.

.DESCRIPTION
When no ToolDirectory is specified, navigates one level up from the caller script's directory to align with the
dotnet local tool *root* (where the manifest typically lives). This helps when the script runs from a subfolder
(e.g., /scripts) and the manifest is at the repository root.

.PARAMETER ManifestFile
Path to the dotnet local tools manifest (dotnet-tools.json). Defaults to $PSScriptRoot\dotnet-tools.json.

.PARAMETER ToolDirectory
Optional working directory to run the restore in. If omitted or empty, the function goes one directory up from
the caller script's directory.

.EXAMPLE
Invoke-DotnetToolRestore
#>
    param(

        [Parameter(Mandatory=$false)]
        [string]$ManifestFile = "$PSScriptRoot\dotnet-tools.json",

        [Parameter(Mandatory=$false)]
        [string]$ToolDirectory = ""
    )

    # Need depth 2 to resolve through the Invoke-DotnetToolRestore and Get-CallerScriptInfo stack frames.
    $info = Get-CallerScriptInfo -Depth 2
    Write-Host "Caller script file: $($info.CallerFileInfo.FullName)" -ForegroundColor DarkGray
    Write-Host "Caller script directory: $($info.CallerFileInfo.DirectoryName)" -ForegroundColor DarkGray

    # Check: manifest file must exist (leaf).
    if (-not (Test-Path -LiteralPath $ManifestFile -PathType Leaf)) {
        Write-Error "Manifest file not found: '$ManifestFile'. Ensure this points to a valid 'dotnet-tools.json'."
        return
    }

    if ([string]::IsNullOrEmpty($ToolDirectory)) {
        # Intention: dotnet local tools look for the manifest (dotnet-tools.json) in the *tool root* (e.g., repo root).
        # Calling from a nested script folder (e.g., /scripts) may not find the manifest.
        # Therefore, go one directory up from the caller script's directory before restoring.
        Write-Host "Setlocation $(Split-Path -Parent $info.CallerFileInfo.DirectoryName)" -ForegroundColor DarkGray
        Set-Location (Split-Path -Parent $info.CallerFileInfo.DirectoryName)
    }
    else {
        # Check: provided tool directory must exist (container) before changing to it.
        if (-not (Test-Path -LiteralPath $ToolDirectory -PathType Container)) {
            Write-Error "Tool directory not found: '$ToolDirectory'."
            return
        }
        Set-Location $ToolDirectory
    }

    Invoke-Exec -Executable "dotnet" -Arguments @("tool", "restore", "--verbosity", "diagnostic", "--tool-manifest", $ManifestFile)

    # Reset location after the call.
    Set-Location "$($info.CallerFileInfo.DirectoryName)"
    Write-Host "Setlocation $($info.CallerFileInfo.DirectoryName)" -ForegroundColor DarkGray
}




#Set-Location "$PSScriptRoot\.."
#Invoke-Exec -Executable "dotnet" -Arguments @("tool", "restore", "--verbosity", "diagnostic","--tool-manifest",[System.IO.Path]::Combine("$PSScriptRoot","dotnet-tools.json"))
#Set-Location "$PSScriptRoot"
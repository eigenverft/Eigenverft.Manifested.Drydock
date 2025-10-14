
function Invoke-DotnetToolRestore {
    Write-Host "===> Restoring dotnet tools from manifest at: $PSScriptRoot" -ForegroundColor Cyan
    $info = Get-CallerScriptInfo
    Write-Host "Caller script info: $($info.CallerFileInfo)" -ForegroundColor DarkGray
}

#Set-Location "$PSScriptRoot\.."
#Invoke-Exec -Executable "dotnet" -Arguments @("tool", "restore", "--verbosity", "diagnostic","--tool-manifest",[System.IO.Path]::Combine("$PSScriptRoot","dotnet-tools.json"))
#Set-Location "$PSScriptRoot"
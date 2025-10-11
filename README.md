# Eigenverft.Manifested.Drydock

PowerShell helper functions for the Eigenverft Manifested Drydock project, focused on building and deploying locally and in CI/CD; see .github/workflow/main.ps1 and .yml for how it works.


[Eigenverft.Manifested.Drydock – PowerShell Gallery](https://www.powershellgallery.com/packages/Eigenverft.Manifested.Drydock)


## Installation

Install `Eigenverft.Manifested.Drydock` from a Windows PowerShell or PowerShell 7+ prompt.

PowerShell 7+ (recommended):

```powershell
Install-Module -Name Eigenverft.Manifested.Drydock -Repository PSGallery -Scope CurrentUser -Force
Import-Module Eigenverft.Manifested.Drydock
```

Windows PowerShell 5.1 (legacy bootstrap):

```batch
powershell -NoProfile -ExecutionPolicy Unrestricted -Command "& { $Install=@('PowerShellGet','PackageManagement','Eigenverft.Manifested.Drydock');$Scope='CurrentUser';if($PSVersionTable.PSVersion.Major -ne 5){return};Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Unrestricted -Force;[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $minNuget=[Version]'2.8.5.201'; Install-PackageProvider -Name NuGet -MinimumVersion $minNuget -Scope $Scope -Force -ForceBootstrap | Out-Null; try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop } catch { Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -ScriptSourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted -ErrorAction Stop }; Find-Module -Name $Install -Repository PSGallery | Select-Object Name,Version | Where-Object { -not (Get-Module -ListAvailable -Name $_.Name | Sort-Object Version -Descending | Select-Object -First 1 | Where-Object Version -eq $_.Version) } | ForEach-Object { Install-Module -Name $_.Name -RequiredVersion $_.Version -Repository PSGallery -Scope $Scope -Force -AllowClobber; try { Remove-Module -Name $_.Name -ErrorAction SilentlyContinue } catch {}; Import-Module -Name $_.Name -MinimumVersion $_.Version -Force }; Write-Host 'Done' }; "
```

## Module function reference

Below is a concise reference grouped by area. See built-in help for parameters and examples, e.g. `Get-Help Update-ManifestModuleVersion -Full`.

### Git helpers 

- **Get-GitTopLevelDirectory (ggtd)** Return repository root using `git rev-parse --show-toplevel`.
  Example: `Get-GitTopLevelDirectory`
- **Get-GitCurrentBranch (ggcb)** Return current branch; on detached HEAD, try containing branches or fall back to commit hash.
  Example: `Get-GitCurrentBranch`
- **Get-GitCurrentBranchRoot (ggcbr)** Return the first path segment of the branch (e.g., `feature` from `feature/foo`).
  Example: `Get-GitCurrentBranchRoot`
- **Get-GitRepositoryName (ggrn)** Parse repository name from `remote.origin.url` (HTTPS/SSH supported).
  Example: `Get-GitRepositoryName`
- **Get-GitRemoteUrl (gru)** Return `remote.origin.url` as configured.
  Example: `Get-GitRemoteUrl`
- **Invoke-GitAddCommitPush (igacp)** Stage folders, commit with transient identity, push branch, optionally tag.
  Example: `Invoke-GitAddCommitPush -TopLevelDirectory (Get-GitTopLevelDirectory) -Folders @('source/Eigenverft.Manifested.Drydock') -CurrentBranch (Get-GitCurrentBranch)`

### Versioning
- **Convert-DateTimeTo64SecVersionComponents (cdv64)** Encode DateTime to `Build.Major.Minor.Revision` with 64s granularity.
  Example: `Convert-DateTimeTo64SecVersionComponents -VersionBuild 1 -VersionMajor 0`
- **Convert-64SecVersionComponentsToDateTime (cdv64r)** Decode four-part 64s-packed version back to approximate UTC DateTime.
  Example: `Convert-64SecVersionComponentsToDateTime -VersionBuild 1 -VersionMajor 0 -VersionMinor 20250 -VersionRevision 1234`
- **Convert-DateTimeTo64SecPowershellVersion (cdv64ps)** Map to simplified three-part `Build.NewMajor.NewMinor` version.
  Example: `Convert-DateTimeTo64SecPowershellVersion -VersionBuild 1`
- **Convert-64SecPowershellVersionToDateTime (cdv64psr)** Reverse the simplified mapping to reconstruct approximate DateTime.
  Example: `Convert-64SecPowershellVersionToDateTime -VersionBuild 1 -VersionMajor 20250 -VersionMinor 1234`

### Deployment/channel mapping

- **Convert-BranchToDeploymentInfo** Validate/split branch, map first segment to channel, and generate label/prefix/suffix tokens.
  Example: `Convert-BranchToDeploymentInfo -BranchName 'feature/awesome'`

### CI/runtime utilities (`source/.../Eigenverft.Manifested.Drydock.ps1`)
- **Invoke-Exec (iexec)** Run external command with per-call and common arguments; enforce allowed exit codes; optional timing/capture.
  Example: `Invoke-Exec -Executable 'dotnet' -Arguments @('build','MyApp.csproj') -CommonArguments @('--configuration','Release')`
- **Find-FilesByPattern (ffbp)** Recursively find files under a path by `-Filter` pattern.
  Example: `Find-FilesByPattern -Path (Get-GitTopLevelDirectory) -Pattern '*.psd1'`
- **Get-ConfigValue (gcv)** If -Check is empty, read JSON and resolve a dotted property path.
  Example: `Get-ConfigValue -Check $env:POWERSHELL_GALLERY -FilePath '.github/workflows/cicd.secrets.json' -Property 'POWERSHELL_GALLERY'`
- **Test-VariableValue (tvv)** Show variable name/value from a scriptblock; optional hide or exit-on-empty.
  Example: ``$branch='main'; Test-VariableValue -Variable { $branch }``
- **Test-CommandAvailable** Resolve a command (cmdlet/function/app/script); optionally throw or exit.
  Example: `Test-CommandAvailable -Command 'git'`
- **Get-RunEnvironment (gre)** Detect CI provider/hosting vs local.
  Example: `Get-RunEnvironment`

### PowerShell environment bootstrap

- **Test-InstallationScopeCapability** Return `AllUsers` if elevated, otherwise `CurrentUser`.
  Example: `Test-InstallationScopeCapability`
- **Set-PSGalleryTrust** Ensure `PSGallery` exists and is trusted (PowerShellGet preferred).
  Example: `Set-PSGalleryTrust`
- **Use-Tls12** Enable TLS 1.2 for the current PS5.x session.
  Example: `Use-Tls12`
- **Test-PSGalleryConnectivity** HEAD→GET probe for PSGallery API (HTTP 200–399 is success).
  Example: `Test-PSGalleryConnectivity`
- **Initialize-NugetPackageProvider** Ensure NuGet provider (>= 2.8.5.201) for scope.
  Example: `Initialize-NugetPackageProvider -Scope CurrentUser`
- **Initialize-PowerShellGet** Ensure PowerShellGet (>= 2.2.5.1) with PSGallery trusted.
  Example: `Initialize-PowerShellGet -Scope CurrentUser`
- **Initialize-PackageManagement** Ensure PackageManagement (>= 1.4.8.1).
  Example: `Initialize-PackageManagement -Scope CurrentUser`
- **Initialize-PowerShellBootstrap** PS5.x-only bootstrap sequence.
  Example: `Initialize-PowerShellBootstrap`
- **Initialize-PowerShellMiniBootstrap** Minimal PS5.x bootstrap.
  Example: `Initialize-PowerShellMiniBootstrap`
- **Import-Script** Globalize and execute function/filter declarations from `.ps1` files.
  Example: `Import-Script -File @('.github/workflows/cicd.migration.ps1') -ErrorIfMissing`
- **Export-OfflineModuleBundle** Export PSGallery modules and provider for offline install.
  Example: `Export-OfflineModuleBundle -Folder 'C:\Bundle' -Modules @('PowerShellGet','PackageManagement')`
- **Uninstall-PreviousModuleVersions** Remove older versions of a module.
  Example: `Uninstall-PreviousModuleVersions -ModuleName 'Eigenverft.Manifested.Drydock'`
- **Find-ModuleScopeClutter** Detect modules installed in both user and system scopes.
  Example: `Find-ModuleScopeClutter -ModuleName 'PowerShellGet'`
- **Update-ManifestModuleVersion (ummv)** Update `ModuleVersion` in a `.psd1` manifest.
  Example: `Update-ManifestModuleVersion -ManifestPath .\ -NewVersion '2.0.0'`
- **Update-ManifestReleaseNotes (umrn)** Update `PSData.ReleaseNotes` in a `.psd1` manifest.
  Example: `Update-ManifestReleaseNotes -ManifestPath .\ -NewReleaseNotes 'Fixed bugs; improved logging.'`
- **Update-ManifestPrerelease (umpr)** Update `PSData.Prerelease` in a `.psd1` manifest.
  Example: `Update-ManifestPrerelease -ManifestPath .\ -NewPrerelease 'rc.1'`

### Scheduled Tasks

- **New-CompatScheduledTask** Create/update a Windows Scheduled Task via COM with clear run context, triggers, and guidance.
  Example:
  ````powershell
  New-CompatScheduledTask -TaskName 'MyDaily' -RunAsAccount System -DailyAtTime '02:00' `
    -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\job.ps1"'
  ````

Notes:
- Use `Get-Help <FunctionName> -Detailed` for parameters, examples, and notes.
- Aliases are shown in parentheses where available.

## Usage tips

- Ensure git is on PATH for Git helper functions.
- All datetime-based conversions use UTC by default.
- The 64-second encoding is lossy: reconstruction yields an approximate DateTime.

## License / Contact

See `LICENSE` for license details. For questions, open an issue in this repository.
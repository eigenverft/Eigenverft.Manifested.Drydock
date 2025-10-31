# Eigenverft.Manifested.Drydock

[![PowerShell Gallery Version](https://img.shields.io/powershellgallery/v/Eigenverft.Manifested.Drydock?label=PSGallery&logo=powershell)](https://www.powershellgallery.com/packages/Eigenverft.Manifested.Drydock)
[![PowerShell Gallery Platform Support](https://img.shields.io/powershellgallery/p/Eigenverft.Manifested.Drydock?logo=windows)](https://www.powershellgallery.com/packages/Eigenverft.Manifested.Drydock)
[![License](https://img.shields.io/github/license/eigenverft/Eigenverft.Manifested.Drydock?logo=mit)](LICENSE)

PowerShell helper functions for the Eigenverft Manifested Drydock, optimized for lightning-fast iteration and reliable local + CI/CD workflows.

🚀 **Key Features:**
- Lightning-fast iteration with built-in auto-versioning
- Parity-driven tasks: same commands run locally and in CI/CD
- Offline-capable with `Export-OfflineModuleBundle` support
- Comprehensive .NET project tooling and reporting
- Robust Git operations and deployment management

---

## 📥 Installation

```powershell
# PowerShell 5.1+ or PowerShell Core
Install-Module -Name Eigenverft.Manifested.Drydock -Repository PSGallery -Scope CurrentUser -Force

# For offline systems, export bundle first:
Export-OfflineModuleBundle -Folder C:\temp\export -Name @(
    'PowerShellGet',
    'PackageManagement',
    'Pester',
    'PSScriptAnalyzer',
    'Eigenverft.Manifested.Drydock'
)
```

### 🔧 First-time Bootstrap (Windows)

No admin rights needed, sets up PowerShellGet and PackageManagement for CurrentUser:

```batch
# From Command Prompt:
powershell -NoProfile -ExecutionPolicy Unrestricted -Command "& { irm -Uri https://tinyurl.com/DrydockInit | iex }"

# From PowerShell 5.1:
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process ; irm -Uri https://tinyurl.com/DrydockInit | iex
```

---

## 📚 Function Reference

> 💡 Use `Get-Help <FunctionName> -Full` for detailed documentation and examples.

### 🔄 Git Operations 

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

### 📊 Versioning & Deployments
- **Convert-DateTimeTo64SecVersionComponents (cdv64)** Encode DateTime to `Build.Major.Minor.Revision` with 64s granularity.
  Example: `Convert-DateTimeTo64SecVersionComponents -VersionBuild 1 -VersionMajor 0`
- **Convert-64SecVersionComponentsToDateTime (cdv64r)** Decode four-part 64s-packed version back to approximate UTC DateTime.
  Example: `Convert-64SecVersionComponentsToDateTime -VersionBuild 1 -VersionMajor 0 -VersionMinor 20250 -VersionRevision 1234`
- **Convert-DateTimeTo64SecPowershellVersion (cdv64ps)** Map to simplified three-part `Build.NewMajor.NewMinor` version.
  Example: `Convert-DateTimeTo64SecPowershellVersion -VersionBuild 1`
- **Convert-64SecPowershellVersionToDateTime (cdv64psr)** Reverse the simplified mapping to reconstruct approximate DateTime.
  Example: `Convert-64SecPowershellVersionToDateTime -VersionBuild 1 -VersionMajor 20250 -VersionMinor 1234`

### ⚙️ CI/Runtime Utilities

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

### 🛠️ PowerShell Environment

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
  Example: `Find-ModuleScopeClutter -detailed`
- **Update-ManifestModuleVersion (ummv)** Update `ModuleVersion` in a `.psd1` manifest.
  Example: `Update-ManifestModuleVersion -ManifestPath .\ -NewVersion '2.0.0'`
- **Update-ManifestReleaseNotes (umrn)** Update `PSData.ReleaseNotes` in a `.psd1` manifest.
  Example: `Update-ManifestReleaseNotes -ManifestPath .\ -NewReleaseNotes 'Fixed bugs; improved logging.'`
- **Update-ManifestPrerelease (umpr)** Update `PSData.Prerelease` in a `.psd1` manifest.
  Example: `Update-ManifestPrerelease -ManifestPath .\ -NewPrerelease 'rc.1'`

### 📅 Scheduled Tasks

- **New-CompatScheduledTask** Create/update a Windows Scheduled Task via COM with clear run context, triggers, and guidance.
  Example:
  ```powershell
  New-CompatScheduledTask -TaskFolder "MyTasks" -TaskName 'MyDaily' -DailyAtTime '12:00' `
    -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\job.ps1"'
  
  New-CompatScheduledTask -TaskFolder "MyTasks" -TaskName 'MyLogin' -LogonThisUser `
     -ActionPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
     -ActionArguments '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\job.ps1"'
  ```

### 📦 .NET Tools and Package Management

- **Enable-TempDotnetTools** Install local-tools from a manifest into an ephemeral cache for the current session.
  Example: `Enable-TempDotnetTools -ManifestFile '.config\dotnet-tools.json'`
- **Disable-TempDotnetTools** Remove ephemeral tool cache from PATH and optionally delete it.
  Example: `Disable-TempDotnetTools -ManifestFile '.config\dotnet-tools.json' -Delete`
- **Register-LocalNuGetDotNetPackageSource** Register a NuGet source using dotnet CLI.
  Example: `Register-LocalNuGetDotNetPackageSource -SourceLocation 'C:\nuget-local'`
- **Unregister-LocalNuGetDotNetPackageSource** Unregister a NuGet source by name.
  Example: `Unregister-LocalNuGetDotNetPackageSource -SourceName 'local-feed'`
- **New-DotnetBillOfMaterialsReport** Generate a Bill of Materials report from package listings.
  Example: `New-DotnetBillOfMaterialsReport -jsonInput $json -OutputFormat markdown -OutputFile 'reports/bom.md'`
- **New-DotnetVulnerabilitiesReport** Generate a vulnerabilities report from package scans.
  Example: `New-DotnetVulnerabilitiesReport -jsonInput $json -OutputFormat markdown -OutputFile 'reports/vuln.md'`
- **New-DotnetDeprecatedReport** Generate a deprecation report for packages.
  Example: `New-DotnetDeprecatedReport -jsonInput $json -OutputFormat markdown -OutputFile 'reports/deprecated.md'`
- **New-DotnetOutdatedReport** Generate an outdated packages report.
  Example: `New-DotnetOutdatedReport -jsonInput $json -OutputFormat markdown -OutputFile 'reports/outdated.md'`
- **New-ThirdPartyNotice** Create/update THIRD-PARTY-NOTICES.txt from license data.
  Example: `New-ThirdPartyNotice -LicenseJsonPath 'licenses.json' -OutputPath 'THIRD-PARTY-NOTICES.txt'`

Notes:
- Use `Get-Help <FunctionName> -Detailed` for parameters, examples, and notes.
- Aliases are shown in parentheses where available.

---

## 📝 Usage Tips

- 🔍 Ensure `git` is on PATH for Git helper functions
- 🕒 All datetime-based conversions use UTC by default
- ⚠️ The 64-second encoding is lossy: reconstruction yields an approximate DateTime
- 📊 Report outputs support both text and markdown formats
- 🔄 All functions are idempotent and safe to run repeatedly

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 📫 Contact & Support

For questions and support:
- 🐛 Open an [issue](../../../issues) in this repository
- 📝 Review the [documentation](../../wiki)
- 🤝 Submit a [pull request](../../pulls) with improvements

---

<div align="center">
Made with ❤️ by Eigenverft
</div>


# Eigenverft.Manifested.Drydock

PowerShell helper functions used by the Eigenverft Manifested Drydock project. The module provides Git helpers, a compact date/time->version encoding (64-second granularity), and a manifest version updater.

## Installation

Install Eigenverft.Manifested.Drydock from cmd.

```batch
powershell -NoProfile -ExecutionPolicy Unrestricted -Command "& { $Install=@('PowerShellGet','PackageManagement','Eigenverft.Manifested.Drydock');$Scope='CurrentUser';if($PSVersionTable.PSVersion.Major -ne 5){return};Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Unrestricted -Force;[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $minNuget=[Version]'2.8.5.201'; Install-PackageProvider -Name NuGet -MinimumVersion $minNuget -Scope $Scope -Force -ForceBootstrap | Out-Null; try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop } catch { Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -ScriptSourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted -ErrorAction Stop }; Find-Module -Name $Install -Repository PSGallery | Select-Object Name,Version | Where-Object { -not (Get-Module -ListAvailable -Name $_.Name | Sort-Object Version -Descending | Select-Object -First 1 | Where-Object Version -eq $_.Version) } | ForEach-Object { Install-Module -Name $_.Name -RequiredVersion $_.Version -Repository PSGallery -Scope $Scope -Force -AllowClobber; try { Remove-Module -Name $_.Name -ErrorAction SilentlyContinue } catch {}; Import-Module -Name $_.Name -MinimumVersion $_.Version -Force }; Write-Host 'Done' }; "
```

## Functions

- Get-GitTopLevelDirectory (alias: ggtd)  
  Purpose: Return the repository root (git rev-parse --show-toplevel).  
  Parameters: none  
  Returns: path string or $null on error  
  Example: Get-GitTopLevelDirectory

- Get-GitCurrentBranch (alias: ggcb)  
  Purpose: Get the current branch name; on detached HEAD tries branches containing HEAD or falls back to commit hash.  
  Parameters: none  
  Returns: branch name or commit hash  
  Example: Get-GitCurrentBranch

- Get-GitCurrentBranchRoot (alias: ggcbr)  
  Purpose: Return the root segment of the branch name (split on / or \). Useful for branch-root workflows (e.g., feature/xyz -> feature).  
  Parameters: none  
  Returns: branch root string  
  Example: Get-GitCurrentBranchRoot

- Get-GitRepositoryName (alias: ggrn)  
  Purpose: Extract repo name from remote.origin.url (handles HTTPS and SSH forms).  
  Parameters: none  
  Returns: repository name string  
  Example: Get-GitRepositoryName

- Get-GitRemoteUrl (alias: gru)  
  Purpose: Return remote.origin.url exactly as configured.  
  Parameters: none  
  Returns: remote URL string  
  Example: Get-GitRemoteUrl

- Convert-DateTimeTo64SecVersionComponents (alias: cdv64)  
  Purpose: Encode a DateTime into four version components with 64-second granularity suitable for NuGet/assembly versioning. Produces VersionFull and components (VersionBuild, VersionMajor, VersionMinor, VersionRevision).  
  Parameters:
    - VersionBuild (int, mandatory)
    - VersionMajor (int, mandatory)
    - InputDate (datetime, optional, defaults to now UTC)  
  Returns: hashtable with VersionFull, VersionBuild, VersionMajor, VersionMinor, VersionRevision  
  Example:
  ```powershell
  Convert-DateTimeTo64SecVersionComponents -VersionBuild 1 -VersionMajor 0
  ```

- Convert-64SecVersionComponentsToDateTime (alias: cdv64r)  
  Purpose: Reconstruct an approximate DateTime from the four-part encoded version (lossy: 6 bits discarded).  
  Parameters:
    - VersionBuild (int)
    - VersionMajor (int)
    - VersionMinor (int) — encoded year*10 + highPart
    - VersionRevision (int) — low 16 bits  
  Returns: hashtable with VersionBuild, VersionMajor, ComputedDateTime  
  Example:
  ```powershell
  Convert-64SecVersionComponentsToDateTime -VersionBuild 1 -VersionMajor 0 -VersionMinor 20250 -VersionRevision 1234
  ```

- Convert-DateTimeTo64SecPowershellVersion (alias: cdv64ps)  
  Purpose: Simplified 3-part mapping of the 4-part encoding to "Build.NewMajor.NewMinor" for compact PowerShell-friendly versions.  
  Parameters:
    - VersionBuild (int, mandatory)
    - InputDate (datetime, optional)  
  Returns: hashtable with VersionFull, VersionBuild, VersionMajor, VersionMinor  
  Example:
  ```powershell
  Convert-DateTimeTo64SecPowershellVersion -VersionBuild 1
  ```

- Convert-64SecPowershellVersionToDateTime (alias: cdv64psr)  
  Purpose: Reconstruct approximate DateTime from the simplified 3-part version produced above. Assumes original VersionMajor was 0.  
  Parameters:
    - VersionBuild (int, mandatory)
    - VersionMajor (int, mandatory) — mapped original VersionMinor
    - VersionMinor (int, mandatory) — mapped original VersionRevision  
  Returns: hashtable with VersionFull, VersionBuild, ComputedDateTime  
  Example:
  ```powershell
  Convert-64SecPowershellVersionToDateTime -VersionBuild 1 -VersionMajor 20250 -VersionMinor 1234
  ```

- Update-ManifestModuleVersion (alias: ummv)  
  Purpose: Update ModuleVersion in a PSD1 manifest file by text/regex replacement while preserving formatting and comments. If given a directory, recursively finds the first *.psd1.  
  Parameters:
    - ManifestPath (string, mandatory) — file or directory
    - NewVersion (string, mandatory) — version to set (e.g., "1.2.3")  
  Returns: writes changes back to the manifest file; throws on missing path or missing PSD1 in directory.  
  Example:
  ```powershell
  Update-ManifestModuleVersion -ManifestPath .\ -NewVersion '2.0.0'
  ```

## Usage tips

- Ensure git is on PATH for Git helper functions.
- All datetime-based conversions use UTC by default.
- The 64-second encoding is lossy: reconstruction yields an approximate DateTime.

## License / Contact

See repository metadata for license and contact information.

# Eigenverft.Manifested.Drydock

PowerShell helper functions used by the Eigenverft Manifested Drydock project. The module provides Git helpers, a compact date/time->version encoding (64-second granularity), and a manifest version updater.

## Installation

Install Eigenverft.Manifested.Drydock from cmd.

```batch
powershell -NoProfile -ExecutionPolicy Unrestricted -Command "& { $Install=@('PowerShellGet','PackageManagement','Eigenverft.Manifested.Drydock');$Scope='CurrentUser';if($PSVersionTable.PSVersion.Major -ne 5){return};Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Unrestricted -Force;[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $minNuget=[Version]'2.8.5.201'; Install-PackageProvider -Name NuGet -MinimumVersion $minNuget -Scope $Scope -Force -ForceBootstrap | Out-Null; try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop } catch { Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -ScriptSourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted -ErrorAction Stop }; Find-Module -Name $Install -Repository PSGallery | Select-Object Name,Version | Where-Object { -not (Get-Module -ListAvailable -Name $_.Name | Sort-Object Version -Descending | Select-Object -First 1 | Where-Object Version -eq $_.Version) } | ForEach-Object { Install-Module -Name $_.Name -RequiredVersion $_.Version -Repository PSGallery -Scope $Scope -Force -AllowClobber; try { Remove-Module -Name $_.Name -ErrorAction SilentlyContinue } catch {}; Import-Module -Name $_.Name -MinimumVersion $_.Version -Force }; Write-Host 'Done' }; "
```

## Usage tips

- Ensure git is on PATH for Git helper functions.
- All datetime-based conversions use UTC by default.
- The 64-second encoding is lossy: reconstruction yields an approximate DateTime.

## License / Contact

See repository metadata for license and contact information.
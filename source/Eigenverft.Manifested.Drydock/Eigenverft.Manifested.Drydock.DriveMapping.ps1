function Set-CleanNetworkDrive {
<#
.SYNOPSIS
Remaps a network drive letter after cleaning cached Explorer mount point data.

.DESCRIPTION
Reads the current mapping of a given drive letter, removes WScript.Network and SMB
mappings, deletes HKCU:\Network\<DriveLetter> and related MountPoints2 entries,
then maps the drive again via WScript.Network so File Explorer sees the change.
Finally, it sends SHChangeNotify to nudge Explorer to refresh drive info.

.PARAMETER DriveLetter
Single drive letter without colon (for example Z).

.PARAMETER RemotePath
UNC path to map to (for example \\server\share).

.PARAMETER NonPersistent
If set, the mapping will not be stored persistently in the user profile.

.EXAMPLE
Set-CleanNetworkDrive -DriveLetter Z -RemotePath '\\hi-ma-uts.de.bosch.com\srv$'

.EXAMPLE
Set-CleanNetworkDrive -DriveLetter Z -RemotePath '\\hi230077\fkt'
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter,

        [Parameter(Mandatory)]
        [ValidatePattern('^\\\\')]
        [string]$RemotePath,

        [switch]$NonPersistent
    )

    $drive = ($DriveLetter.TrimEnd(':') + ':').ToUpper()

    # COM object for Explorer-visible mapping
    $nw = New-Object -ComObject WScript.Network

    # Read current SMB mapping before we touch anything
    $currentMapping = Get-SmbMapping -LocalPath $drive -ErrorAction SilentlyContinue

    if ($PSCmdlet.ShouldProcess($drive, "Reset mapping and clean Explorer cache")) {

        # 1) Remove COM / profile mapping (if any)
        try {
            $nw.RemoveNetworkDrive($drive, $true, $true)
        } catch {
            # ignore
        }

        # 2) Remove SMB mapping
        if ($currentMapping) {
            $currentMapping | Remove-SmbMapping -Force -ErrorAction SilentlyContinue
        }

        # 3) Remove HKCU:\Network\<DriveLetter>
        $networkKey = "HKCU:\Network\{0}" -f $DriveLetter.TrimEnd(':')
        Remove-Item $networkKey -Recurse -Force -ErrorAction SilentlyContinue

        # 4) Clean MountPoints2 entries related to this drive / UNC
        $mpBase = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'

        # MountPoints2 encodes UNC as "##server#share..."
        $oldSanitized = $null
        if ($currentMapping -and $currentMapping.RemotePath) {
            $oldSanitized = '##' + $currentMapping.RemotePath.TrimStart('\').Replace('\', '#')
        }
        $newSanitized = '##' + $RemotePath.TrimStart('\').Replace('\', '#')

        if (Test-Path $mpBase) {
            Get-ChildItem $mpBase -ErrorAction SilentlyContinue | ForEach-Object {
                $childName = $_.PSChildName

                $matchDriveKey = $childName -eq $drive -or
                                 $childName -eq $DriveLetter.TrimEnd(':')

                $matchOld = $false
                if ($oldSanitized) {
                    $matchOld = $childName -like "$oldSanitized*"
                }

                $matchNew = $childName -like "$newSanitized*"

                if ($matchDriveKey -or $matchOld -or $matchNew) {
                    Remove-Item $_.PsPath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # 5) Map new drive via COM (Explorer-compatible)
        $persistentFlag = -not $NonPersistent
        $nw.MapNetworkDrive($drive, $RemotePath, $persistentFlag)

        # 6) Optional: force the visible label to match the UNC
        try {
            $shell  = New-Object -ComObject Shell.Application
            $folder = $shell.NameSpace("$drive\")
            if ($folder -and $folder.Self) {
                $folder.Self.Name = $RemotePath
            }
        } catch {
            # If this fails, mapping is still correct; only label refresh might lag.
        }

        # 7) Shell notify: nudge Explorer to refresh drive info
        try {
            if (-not ('ExplorerRefresh' -as [type])) {
                Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ExplorerRefresh
{
    const uint SHCNE_ASSOCCHANGED = 0x08000000;
    const uint SHCNE_UPDATEDIR    = 0x00001000;
    const uint SHCNF_IDLIST       = 0x0000;
    const uint SHCNF_PATHW        = 0x0005;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(uint wEventId, uint uFlags, string dwItem1, string dwItem2);

    public static void RefreshDrive(string path)
    {
        // Global-ish refresh
        SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, null, null);
        // Targeted refresh for the drive path ("Z:\")
        if (!string.IsNullOrEmpty(path))
        {
            SHChangeNotify(SHCNE_UPDATEDIR, SHCNF_PATHW, path, null);
        }
    }
}
'@
            }

            [ExplorerRefresh]::RefreshDrive("$drive\")
        } catch {
            # Ignore notify failures; mapping itself is already correct.
        }
    }
}

function Remove-NetworkDrive {
<#
.SYNOPSIS
Removes a network drive and cleans related Explorer cache.

.DESCRIPTION
Removes the mapping for a given drive letter using WScript.Network and SMB,
deletes HKCU:\Network\<DriveLetter> and related MountPoints2 entries, and
notifies Explorer via SHChangeNotify so the UI updates accordingly.

.PARAMETER DriveLetter
Single drive letter without colon (for example Z).

.EXAMPLE
Remove-NetworkDrive -DriveLetter Z
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter
    )

    $drive = ($DriveLetter.TrimEnd(':') + ':').ToUpper()

    # COM object for Explorer-visible mapping
    $nw = New-Object -ComObject WScript.Network

    # Read current SMB mapping before we touch anything
    $currentMapping = Get-SmbMapping -LocalPath $drive -ErrorAction SilentlyContinue

    if ($PSCmdlet.ShouldProcess($drive, "Remove network drive and clean Explorer cache")) {

        # 1) Remove COM / profile mapping (if any)
        try {
            $nw.RemoveNetworkDrive($drive, $true, $true)
        } catch {
            # ignore
        }

        # 2) Remove SMB mapping
        if ($currentMapping) {
            $currentMapping | Remove-SmbMapping -Force -ErrorAction SilentlyContinue
        }

        # 3) Remove HKCU:\Network\<DriveLetter>
        $networkKey = "HKCU:\Network\{0}" -f $DriveLetter.TrimEnd(':')
        Remove-Item $networkKey -Recurse -Force -ErrorAction SilentlyContinue

        # 4) Clean MountPoints2 entries related to this drive / old UNC
        $mpBase = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'

        # MountPoints2 encodes UNC as "##server#share..."
        $oldSanitized = $null
        if ($currentMapping -and $currentMapping.RemotePath) {
            $oldSanitized = '##' + $currentMapping.RemotePath.TrimStart('\').Replace('\', '#')
        }

        if (Test-Path $mpBase) {
            Get-ChildItem $mpBase -ErrorAction SilentlyContinue | ForEach-Object {
                $childName = $_.PSChildName

                $matchDriveKey = $childName -eq $drive -or
                                 $childName -eq $DriveLetter.TrimEnd(':')

                $matchOld = $false
                if ($oldSanitized) {
                    $matchOld = $childName -like "$oldSanitized*"
                }

                if ($matchDriveKey -or $matchOld) {
                    Remove-Item $_.PsPath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # 5) Shell notify: nudge Explorer to refresh drive info
        try {
            if (-not ('ExplorerRefresh' -as [type])) {
                Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ExplorerRefresh
{
    const uint SHCNE_ASSOCCHANGED = 0x08000000;
    const uint SHCNE_UPDATEDIR    = 0x00001000;
    const uint SHCNF_IDLIST       = 0x0000;
    const uint SHCNF_PATHW        = 0x0005;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(uint wEventId, uint uFlags, string dwItem1, string dwItem2);

    public static void RefreshDrive(string path)
    {
        // Global-ish refresh
        SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, null, null);
        // Targeted refresh for the drive path ("Z:\")
        if (!string.IsNullOrEmpty(path))
        {
            SHChangeNotify(SHCNE_UPDATEDIR, SHCNF_PATHW, path, null);
        }
    }
}
"@
            }

            [ExplorerRefresh]::RefreshDrive("$drive\")
        } catch {
            # Ignore notify failures; the drive is already removed.
        }
    }
}

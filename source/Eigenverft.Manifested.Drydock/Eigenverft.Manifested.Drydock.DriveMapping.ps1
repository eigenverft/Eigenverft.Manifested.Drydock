function New-NetworkDriveMapping {
<#
.SYNOPSIS
Creates a new network drive mapping after clearing cached Explorer data.

.DESCRIPTION
Removes any existing mapping for the specified drive letter, cleans related
HKCU:\Network and MountPoints2 entries, then creates a new mapping so that
File Explorer sees the updated connection.

.PARAMETER DriveLetter
Single drive letter without colon (for example Z).

.PARAMETER RemotePath
UNC path to map to (for example \\server\share).

.PARAMETER NonPersistent
If set, the mapping will not be stored persistently in the user profile.

.EXAMPLE
New-NetworkDriveMapping -DriveLetter Z -RemotePath '\\server\share'

.EXAMPLE
New-NetworkDriveMapping -DriveLetter Z -RemotePath '\\server\share' -NonPersistent

.NOTES
This function is supported only on Windows. On non-Windows platforms it will
throw a terminating error before attempting any Windows-specific operations.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter,

        [Parameter(Mandatory=$true)]
        [ValidatePattern('^\\\\')]
        [string]$RemotePath,

        [Parameter()]
        [switch]$NonPersistent
    )

    function local:_Write-StandardMessage {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
            [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$Level='INF',
            [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$MinLevel
        )
        if ($null -eq $Message) { $Message = [string]::Empty }
        $sevMap=@{TRC=0;DBG=1;INF=2;WRN=3;ERR=4;FTL=5}
        if(-not $PSBoundParameters.ContainsKey('MinLevel')){
            $gv=Get-Variable ConsoleLogMinLevel -Scope Global -ErrorAction SilentlyContinue
            $MinLevel=if($gv -and $gv.Value -and -not [string]::IsNullOrEmpty([string]$gv.Value)){[string]$gv.Value}else{'INF'}
        }
        $lvl=$Level.ToUpperInvariant()
        $min=$MinLevel.ToUpperInvariant()
        $sev=$sevMap[$lvl];if($null -eq $sev){$lvl='INF';$sev=$sevMap['INF']}
        $gate=$sevMap[$min];if($null -eq $gate){$min='INF';$gate=$sevMap['INF']}
        if($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4){$lvl=$min;$sev=$gate}
        if($sev -lt $gate){return}
        $ts=[DateTime]::UtcNow.ToString('yy-MM-dd HH:mm:ss.ff')
        $stack=Get-PSCallStack ; $helperName=$MyInvocation.MyCommand.Name ; $helperScript=$MyInvocation.MyCommand.ScriptBlock.File ; $caller=$null
        if($stack){
            # 1: prefer first non-underscore function not defined in the helper's own file
            for($i=0;$i -lt $stack.Count;$i++){
                $f=$stack[$i];$fn=$f.FunctionName;$sn=$f.ScriptName
                if($fn -and $fn -ne $helperName -and -not $fn.StartsWith('_') -and (-not $helperScript -or -not $sn -or $sn -ne $helperScript)){$caller=$f;break}
            }
            # 2: fallback to first non-underscore function (any file)
            if(-not $caller){
                for($i=0;$i -lt $stack.Count;$i++){
                    $f=$stack[$i];$fn=$f.FunctionName
                    if($fn -and $fn -ne $helperName -and -not $fn.StartsWith('_')){$caller=$f;break}
                }
            }
            # 3: fallback to first non-helper frame not from helper's own file
            if(-not $caller){
                for($i=0;$i -lt $stack.Count;$i++){
                    $f=$stack[$i];$fn=$f.FunctionName;$sn=$f.ScriptName
                    if($fn -and $fn -ne $helperName -and (-not $helperScript -or -not $sn -or $sn -ne $helperScript)){$caller=$f;break}
                }
            }
            # 4: final fallback to first non-helper frame
            if(-not $caller){
                for($i=0;$i -lt $stack.Count;$i++){
                    $f=$stack[$i];$fn=$f.FunctionName
                    if($fn -and $fn -ne $helperName){$caller=$f;break}
                }
            }
        }
        if(-not $caller){$caller=[pscustomobject]@{ScriptName=$PSCommandPath;FunctionName=$null}}
        $lineNumber=$null ; 
        $p=$caller.PSObject.Properties['ScriptLineNumber'];if($p -and $p.Value){$lineNumber=[string]$p.Value}
        if(-not $lineNumber){
            $p=$caller.PSObject.Properties['Position']
            if($p -and $p.Value){
                $sp=$p.Value.PSObject.Properties['StartLineNumber'];if($sp -and $sp.Value){$lineNumber=[string]$sp.Value}
            }
        }
        if(-not $lineNumber){
            $p=$caller.PSObject.Properties['Location']
            if($p -and $p.Value){
                $m=[regex]::Match([string]$p.Value,':(\d+)\s+char:','IgnoreCase');if($m.Success -and $m.Groups.Count -gt 1){$lineNumber=$m.Groups[1].Value}
            }
        }
        $file=if($caller.ScriptName){Split-Path -Leaf $caller.ScriptName}else{'cmd'}
        if($file -ne 'console' -and $lineNumber){$file="{0}:{1}" -f $file,$lineNumber}
        $prefix="[$ts "
        $suffix="] [$file] $Message"
        $cfg=@{TRC=@{Fore='DarkGray';Back=$null};DBG=@{Fore='Cyan';Back=$null};INF=@{Fore='Green';Back=$null};WRN=@{Fore='Yellow';Back=$null};ERR=@{Fore='Red';Back=$null};FTL=@{Fore='Red';Back='DarkRed'}}[$lvl]
        $fore=$cfg.Fore
        $back=$cfg.Back
        $isInteractive = [System.Environment]::UserInteractive
        if($isInteractive -and ($fore -or $back)){
            Write-Host -NoNewline $prefix
            if($fore -and $back){Write-Host -NoNewline $lvl -ForegroundColor $fore -BackgroundColor $back}
            elseif($fore){Write-Host -NoNewline $lvl -ForegroundColor $fore}
            elseif($back){Write-Host -NoNewline $lvl -BackgroundColor $back}
            Write-Host $suffix
        } else {
            Write-Host "$prefix$lvl$suffix"
        }

        if($sev -ge 4 -and $ErrorActionPreference -eq 'Stop'){throw ("ConsoleLog.{0}: {1}" -f $lvl,$Message)}
    }

    _Write-StandardMessage -Message '--- New-NetworkDriveMapping: create or refresh a network drive mapping ---'

    # Ensure the function runs only on Windows
    $platform = [System.Environment]::OSVersion.Platform
    if ($platform -ne [System.PlatformID]::Win32NT) {
        _Write-StandardMessage -Message '[ERR] New-NetworkDriveMapping is only supported on Windows.' -Level 'ERR'
        throw 'New-NetworkDriveMapping is only supported on Windows.'
    }

    $normalizedLetter = $DriveLetter.TrimEnd(':')
    $driveRoot = ($normalizedLetter + ':').ToUpperInvariant()
    $uncPath = $RemotePath

    # Create WScript.Network COM object (Explorer-visible mapping)
    try {
        $wscriptNetwork = New-Object -ComObject WScript.Network
    }
    catch {
        $errMsg = '[ERR] Failed to create WScript.Network COM object. Verify that Windows Script Host is enabled.'
        _Write-StandardMessage -Message $errMsg -Level 'ERR'
        throw $errMsg
    }

    # Read current SMB mapping if the cmdlets are available
    $currentMapping = $null
    $getSmbMappingCmd = Get-Command -Name Get-SmbMapping -ErrorAction SilentlyContinue
    if ($null -ne $getSmbMappingCmd) {
        try {
            $currentMapping = Get-SmbMapping -LocalPath $driveRoot -ErrorAction SilentlyContinue
        }
        catch {
            _Write-StandardMessage -Message '[WRN] Get-SmbMapping failed. Continuing without SMB mapping cleanup.' -Level 'WRN'
        }
    }
    else {
        _Write-StandardMessage -Message '[WRN] Get-SmbMapping not available. Skipping SMB mapping cleanup.' -Level 'WRN'
    }

    # Remove COM / profile mapping (if any)
    try {
        _Write-StandardMessage -Message "[STATUS] Removing existing COM mapping for $driveRoot (if present)." -Level 'INF'
        $wscriptNetwork.RemoveNetworkDrive($driveRoot, $true, $true)
    }
    catch {
        _Write-StandardMessage -Message "[WRN] RemoveNetworkDrive reported a problem. The mapping may not have existed." -Level 'WRN'
    }

    # Remove SMB mapping (if present)
    if ($null -ne $currentMapping) {
        try {
            _Write-StandardMessage -Message "[STATUS] Removing existing SMB mapping for $driveRoot." -Level 'INF'
            $currentMapping | Remove-SmbMapping -Force -ErrorAction SilentlyContinue
        }
        catch {
            _Write-StandardMessage -Message '[WRN] Remove-SmbMapping reported a problem. The SMB mapping may already be gone.' -Level 'WRN'
        }
    }

    # Remove HKCU:\Network\<DriveLetter>
    $networkKeyPath = 'HKCU:\Network\{0}' -f $normalizedLetter
    if (Test-Path -LiteralPath $networkKeyPath) {
        try {
            _Write-StandardMessage -Message "[STATUS] Removing registry key $networkKeyPath." -Level 'INF'
            Remove-Item -LiteralPath $networkKeyPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            $err = "[ERR] Failed to remove registry key $networkKeyPath."
            _Write-StandardMessage -Message $err -Level 'ERR'
            throw $err
        }
    }

    # Clean MountPoints2 entries related to this drive and UNC
    $mountPointsBase = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
    $oldSanitized = $null
    if ($null -ne $currentMapping -and $null -ne $currentMapping.RemotePath) {
        $oldSanitized = '##' + $currentMapping.RemotePath.TrimStart('\').Replace('\', '#')
    }
    $newSanitized = '##' + $uncPath.TrimStart('\').Replace('\', '#')

    if (Test-Path -LiteralPath $mountPointsBase) {
        try {
            _Write-StandardMessage -Message '[STATUS] Cleaning MountPoints2 entries for the drive and UNC path.' -Level 'INF'
            Get-ChildItem -LiteralPath $mountPointsBase -ErrorAction SilentlyContinue | ForEach-Object {
                $childName = $_.PSChildName

                $matchDriveKey = ($childName -eq $driveRoot) -or ($childName -eq $normalizedLetter)

                $matchOld = $false
                if ($null -ne $oldSanitized) {
                    if ($childName -like ($oldSanitized + '*')) {
                        $matchOld = $true
                    }
                }

                $matchNew = $false
                if ($childName -like ($newSanitized + '*')) {
                    $matchNew = $true
                }

                if ($matchDriveKey -or $matchOld -or $matchNew) {
                    try {
                        Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop
                    }
                    catch {
                        _Write-StandardMessage -Message "[WRN] Failed to remove MountPoints2 entry $childName." -Level 'WRN'
                    }
                }
            }
        }
        catch {
            _Write-StandardMessage -Message '[WRN] Failed while enumerating MountPoints2 entries.' -Level 'WRN'
        }
    }

    # Map new drive via COM (Explorer-compatible mapping)
    try {
        $persistentFlag = $true
        if ($NonPersistent.IsPresent) {
            $persistentFlag = $false
        }

        _Write-StandardMessage -Message "[STATUS] Creating new network drive mapping $driveRoot -> $uncPath." -Level 'INF'
        $wscriptNetwork.MapNetworkDrive($driveRoot, $uncPath, $persistentFlag)
    }
    catch {
        $err = "[ERR] Failed to create network drive mapping $driveRoot -> $uncPath."
        _Write-StandardMessage -Message $err -Level 'ERR'
        throw $err
    }

    # Optional: force the visible label in Explorer to match the UNC
    try {
        $shellApplication = New-Object -ComObject Shell.Application
        $folder = $shellApplication.NameSpace($driveRoot + '\')
        if ($null -ne $folder -and $null -ne $folder.Self) {
            $folder.Self.Name = $uncPath
        }
    }
    catch {
        _Write-StandardMessage -Message '[WRN] Failed to update the Explorer folder label. Mapping itself is still valid.' -Level 'WRN'
    }

    # Notify Explorer to refresh drive info
    try {
        $explorerRefreshType = 'ExplorerRefresh' -as [type]
        if ($null -eq $explorerRefreshType) {
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
        SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, null, null);
        if (!string.IsNullOrEmpty(path))
        {
            SHChangeNotify(SHCNE_UPDATEDIR, SHCNF_PATHW, path, null);
        }
    }
}
'@
            $explorerRefreshType = 'ExplorerRefresh' -as [type]
        }

        if ($null -ne $explorerRefreshType) {
            [ExplorerRefresh]::RefreshDrive($driveRoot + '\')
            _Write-StandardMessage -Message "[OK] Explorer has been notified about $driveRoot." -Level 'INF'
        }
    }
    catch {
        _Write-StandardMessage -Message '[WRN] Failed to send a refresh notification to Explorer.' -Level 'WRN'
    }
}

function Remove-NetworkDriveMapping {
<#
.SYNOPSIS
Removes a network drive mapping and cleans related Explorer cache.

.DESCRIPTION
Removes the mapping for the specified drive letter using WScript.Network and
SMB (when available), deletes HKCU:\Network\<DriveLetter> and related MountPoints2
entries, then notifies Explorer so that the user interface is updated.

.PARAMETER DriveLetter
Single drive letter without colon (for example Z).

.EXAMPLE
Remove-NetworkDriveMapping -DriveLetter Z

.NOTES
This function is supported only on Windows. On non-Windows platforms it will
throw a terminating error before attempting any Windows-specific operations.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter
    )

    function local:_Write-StandardMessage {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
            [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$Level='INF',
            [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$MinLevel
        )
        if ($null -eq $Message) { $Message = [string]::Empty }
        $sevMap=@{TRC=0;DBG=1;INF=2;WRN=3;ERR=4;FTL=5}
        if(-not $PSBoundParameters.ContainsKey('MinLevel')){
            $gv=Get-Variable ConsoleLogMinLevel -Scope Global -ErrorAction SilentlyContinue
            $MinLevel=if($gv -and $gv.Value -and -not [string]::IsNullOrEmpty([string]$gv.Value)){[string]$gv.Value}else{'INF'}
        }
        $lvl=$Level.ToUpperInvariant()
        $min=$MinLevel.ToUpperInvariant()
        $sev=$sevMap[$lvl];if($null -eq $sev){$lvl='INF';$sev=$sevMap['INF']}
        $gate=$sevMap[$min];if($null -eq $gate){$min='INF';$gate=$sevMap['INF']}
        if($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4){$lvl=$min;$sev=$gate}
        if($sev -lt $gate){return}
        $ts=[DateTime]::UtcNow.ToString('yy-MM-dd HH:mm:ss.ff')
        $stack=Get-PSCallStack ; $helperName=$MyInvocation.MyCommand.Name ; $helperScript=$MyInvocation.MyCommand.ScriptBlock.File ; $caller=$null
        if($stack){
            # 1: prefer first non-underscore function not defined in the helper's own file
            for($i=0;$i -lt $stack.Count;$i++){
                $f=$stack[$i];$fn=$f.FunctionName;$sn=$f.ScriptName
                if($fn -and $fn -ne $helperName -and -not $fn.StartsWith('_') -and (-not $helperScript -or -not $sn -or $sn -ne $helperScript)){$caller=$f;break}
            }
            # 2: fallback to first non-underscore function (any file)
            if(-not $caller){
                for($i=0;$i -lt $stack.Count;$i++){
                    $f=$stack[$i];$fn=$f.FunctionName
                    if($fn -and $fn -ne $helperName -and -not $fn.StartsWith('_')){$caller=$f;break}
                }
            }
            # 3: fallback to first non-helper frame not from helper's own file
            if(-not $caller){
                for($i=0;$i -lt $stack.Count;$i++){
                    $f=$stack[$i];$fn=$f.FunctionName;$sn=$f.ScriptName
                    if($fn -and $fn -ne $helperName -and (-not $helperScript -or -not $sn -or $sn -ne $helperScript)){$caller=$f;break}
                }
            }
            # 4: final fallback to first non-helper frame
            if(-not $caller){
                for($i=0;$i -lt $stack.Count;$i++){
                    $f=$stack[$i];$fn=$f.FunctionName
                    if($fn -and $fn -ne $helperName){$caller=$f;break}
                }
            }
        }
        if(-not $caller){$caller=[pscustomobject]@{ScriptName=$PSCommandPath;FunctionName=$null}}
        $lineNumber=$null ; 
        $p=$caller.PSObject.Properties['ScriptLineNumber'];if($p -and $p.Value){$lineNumber=[string]$p.Value}
        if(-not $lineNumber){
            $p=$caller.PSObject.Properties['Position']
            if($p -and $p.Value){
                $sp=$p.Value.PSObject.Properties['StartLineNumber'];if($sp -and $sp.Value){$lineNumber=[string]$sp.Value}
            }
        }
        if(-not $lineNumber){
            $p=$caller.PSObject.Properties['Location']
            if($p -and $p.Value){
                $m=[regex]::Match([string]$p.Value,':(\d+)\s+char:','IgnoreCase');if($m.Success -and $m.Groups.Count -gt 1){$lineNumber=$m.Groups[1].Value}
            }
        }
        $file=if($caller.ScriptName){Split-Path -Leaf $caller.ScriptName}else{'cmd'}
        if($file -ne 'console' -and $lineNumber){$file="{0}:{1}" -f $file,$lineNumber}
        $prefix="[$ts "
        $suffix="] [$file] $Message"
        $cfg=@{TRC=@{Fore='DarkGray';Back=$null};DBG=@{Fore='Cyan';Back=$null};INF=@{Fore='Green';Back=$null};WRN=@{Fore='Yellow';Back=$null};ERR=@{Fore='Red';Back=$null};FTL=@{Fore='Red';Back='DarkRed'}}[$lvl]
        $fore=$cfg.Fore
        $back=$cfg.Back
        $isInteractive = [System.Environment]::UserInteractive
        if($isInteractive -and ($fore -or $back)){
            Write-Host -NoNewline $prefix
            if($fore -and $back){Write-Host -NoNewline $lvl -ForegroundColor $fore -BackgroundColor $back}
            elseif($fore){Write-Host -NoNewline $lvl -ForegroundColor $fore}
            elseif($back){Write-Host -NoNewline $lvl -BackgroundColor $back}
            Write-Host $suffix
        } else {
            Write-Host "$prefix$lvl$suffix"
        }

        if($sev -ge 4 -and $ErrorActionPreference -eq 'Stop'){throw ("ConsoleLog.{0}: {1}" -f $lvl,$Message)}
    }

    _Write-StandardMessage -Message '--- Remove-NetworkDriveMapping: remove a network drive mapping ---'

    # Ensure the function runs only on Windows
    $platform = [System.Environment]::OSVersion.Platform
    if ($platform -ne [System.PlatformID]::Win32NT) {
        _Write-StandardMessage -Message '[ERR] Remove-NetworkDriveMapping is only supported on Windows.' -Level 'ERR'
        throw 'Remove-NetworkDriveMapping is only supported on Windows.'
    }

    $normalizedLetter = $DriveLetter.TrimEnd(':')
    $driveRoot = ($normalizedLetter + ':').ToUpperInvariant()

    # Create WScript.Network COM object (Explorer-visible mapping)
    try {
        $wscriptNetwork = New-Object -ComObject WScript.Network
    }
    catch {
        $errMsg = '[ERR] Failed to create WScript.Network COM object. Verify that Windows Script Host is enabled.'
        _Write-StandardMessage -Message $errMsg -Level 'ERR'
        throw $errMsg
    }

    # Read current SMB mapping if the cmdlets are available
    $currentMapping = $null
    $getSmbMappingCmd = Get-Command -Name Get-SmbMapping -ErrorAction SilentlyContinue
    if ($null -ne $getSmbMappingCmd) {
        try {
            $currentMapping = Get-SmbMapping -LocalPath $driveRoot -ErrorAction SilentlyContinue
        }
        catch {
            _Write-StandardMessage -Message '[WRN] Get-SmbMapping failed. Continuing without SMB mapping cleanup.' -Level 'WRN'
        }
    }
    else {
        _Write-StandardMessage -Message '[WRN] Get-SmbMapping not available. Skipping SMB mapping cleanup.' -Level 'WRN'
    }

    # Remove COM / profile mapping (if any)
    try {
        _Write-StandardMessage -Message "[STATUS] Removing existing COM mapping for $driveRoot (if present)." -Level 'INF'
        $wscriptNetwork.RemoveNetworkDrive($driveRoot, $true, $true)
    }
    catch {
        _Write-StandardMessage -Message "[WRN] RemoveNetworkDrive reported a problem. The mapping may not have existed." -Level 'WRN'
    }

    # Remove SMB mapping (if present)
    if ($null -ne $currentMapping) {
        try {
            _Write-StandardMessage -Message "[STATUS] Removing existing SMB mapping for $driveRoot." -Level 'INF'
            $currentMapping | Remove-SmbMapping -Force -ErrorAction SilentlyContinue
        }
        catch {
            _Write-StandardMessage -Message '[WRN] Remove-SmbMapping reported a problem. The SMB mapping may already be gone.' -Level 'WRN'
        }
    }

    # Remove HKCU:\Network\<DriveLetter>
    $networkKeyPath = 'HKCU:\Network\{0}' -f $normalizedLetter
    if (Test-Path -LiteralPath $networkKeyPath) {
        try {
            _Write-StandardMessage -Message "[STATUS] Removing registry key $networkKeyPath." -Level 'INF'
            Remove-Item -LiteralPath $networkKeyPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            $err = "[ERR] Failed to remove registry key $networkKeyPath."
            _Write-StandardMessage -Message $err -Level 'ERR'
            throw $err
        }
    }

    # Clean MountPoints2 entries related to this drive and previous UNC
    $mountPointsBase = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
    $oldSanitized = $null
    if ($null -ne $currentMapping -and $null -ne $currentMapping.RemotePath) {
        $oldSanitized = '##' + $currentMapping.RemotePath.TrimStart('\').Replace('\', '#')
    }

    if (Test-Path -LiteralPath $mountPointsBase) {
        try {
            _Write-StandardMessage -Message '[STATUS] Cleaning MountPoints2 entries for the drive and previous UNC path.' -Level 'INF'
            Get-ChildItem -LiteralPath $mountPointsBase -ErrorAction SilentlyContinue | ForEach-Object {
                $childName = $_.PSChildName

                $matchDriveKey = ($childName -eq $driveRoot) -or ($childName -eq $normalizedLetter)

                $matchOld = $false
                if ($null -ne $oldSanitized) {
                    if ($childName -like ($oldSanitized + '*')) {
                        $matchOld = $true
                    }
                }

                if ($matchDriveKey -or $matchOld) {
                    try {
                        Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop
                    }
                    catch {
                        _Write-StandardMessage -Message "[WRN] Failed to remove MountPoints2 entry $childName." -Level 'WRN'
                    }
                }
            }
        }
        catch {
            _Write-StandardMessage -Message '[WRN] Failed while enumerating MountPoints2 entries.' -Level 'WRN'
        }
    }

    # Notify Explorer to refresh drive info
    try {
        $explorerRefreshType = 'ExplorerRefresh' -as [type]
        if ($null -eq $explorerRefreshType) {
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
        SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, null, null);
        if (!string.IsNullOrEmpty(path))
        {
            SHChangeNotify(SHCNE_UPDATEDIR, SHCNF_PATHW, path, null);
        }
    }
}
'@
            $explorerRefreshType = 'ExplorerRefresh' -as [type]
        }

        if ($null -ne $explorerRefreshType) {
            [ExplorerRefresh]::RefreshDrive($driveRoot + '\')
            _Write-StandardMessage -Message "[OK] Explorer has been notified about $driveRoot." -Level 'INF'
        }
    }
    catch {
        _Write-StandardMessage -Message '[WRN] Failed to send a refresh notification to Explorer.' -Level 'WRN'
    }
}


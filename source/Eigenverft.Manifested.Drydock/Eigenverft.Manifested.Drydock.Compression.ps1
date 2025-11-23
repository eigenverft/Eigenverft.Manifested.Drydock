function Compress-Directory {
<#
.SYNOPSIS
Creates a zip archive from a source directory in an idempotent, cross-platform way.

.DESCRIPTION
Uses Compress-Archive (Microsoft.PowerShell.Archive) to produce a .zip from the contents of a materialized
source directory. If the destination archive already exists, the default FilePolicy is OverwriteIfExists.
The function is idempotent: repeated runs converge without drift.

.PARAMETER SourceDirectory
Materialized directory whose contents will be zipped.

.PARAMETER DestinationFile
Full path to the resulting .zip file.

.PARAMETER FilePolicy
Behavior when DestinationFile already exists.
- SkipIfExists: skip work if the archive exists.
- OverwriteIfExists: replace any existing archive (default).

.PARAMETER CompressionLevel
Compression level for Compress-Archive.
Valid values: Optimal, Fastest, NoCompression.

.EXAMPLE
Compress-Directory -SourceDirectory "C:\Data\Reports" -DestinationFile "C:\Temp\reports.zip"
Creates or overwrites C:\Temp\reports.zip from directory contents (default policy).

.EXAMPLE
Compress-Directory -SourceDirectory "/home/carsten/projects/app" -DestinationFile "/tmp/app.zip" -FilePolicy SkipIfExists
Creates /tmp/app.zip if missing; skips if present.

.EXAMPLE
Compress-Directory -SourceDirectory "D:\build\out" -DestinationFile "D:\artifacts\out.zip" -CompressionLevel Fastest
Rebuilds out.zip using fastest compression.

.NOTES
- Compatible with Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
- No SupportsShouldProcess; no pipeline input; StrictMode-safe (v3).
- Emits minimal messages via _Write-StandardMessage for key actions only.
#>
    [CmdletBinding(PositionalBinding=$false)]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceDirectory,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationFile,

        [Parameter()]
        [ValidateSet('SkipIfExists','OverwriteIfExists')]
        [string]$FilePolicy = 'OverwriteIfExists',

        [Parameter()]
        [ValidateSet('Optimal','Fastest','NoCompression')]
        [string]$CompressionLevel = 'Optimal'
    )

    # Inline helper for minimal, consistent console logging (scoped locally).
    function local:_Write-StandardMessage {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        # This function is globally exempt from the GENERAL POWERSHELL REQUIREMENTS unless explicitly stated otherwise.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
            [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$Level='INF',
            [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$MinLevel
        )

        if ($null -eq $Message) {
            $Message = [string]::Empty
        }

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

    # First call: title (no tag prefix in message)
    _Write-StandardMessage -Message '--- Compress directory to zip archive ---' -Level 'INF'

    # Require Compress-Archive (fail fast if missing).
    $compressCmd = Get-Command -Name 'Compress-Archive' -ErrorAction SilentlyContinue
    if ($null -eq $compressCmd) {
        throw 'Required cmdlet "Compress-Archive" not found. Install/enable module "Microsoft.PowerShell.Archive" or update PowerShell (5.1+/7+).'
    }

    # Resolve and validate source directory (materialized).
    $SourceResolvedPath = Resolve-Path -LiteralPath $SourceDirectory -ErrorAction SilentlyContinue
    if ($null -eq $SourceResolvedPath) {
        throw ("Source directory not found: {0}" -f $SourceDirectory)
    }
    $SourceFullPath = $SourceResolvedPath.Path
    if (-not (Test-Path -LiteralPath $SourceFullPath -PathType Container)) {
        throw ("Path is not a directory: {0}" -f $SourceFullPath)
    }

    # Ensure destination parent directory exists when needed.
    $DestinationParentPath = Split-Path -Path $DestinationFile -Parent
    if ($null -ne $DestinationParentPath -and $DestinationParentPath -ne '') {
        if (-not (Test-Path -LiteralPath $DestinationParentPath -PathType Container)) {
            New-Item -ItemType Directory -Path $DestinationParentPath -Force | Out-Null
            $DestinationParentDirectory = $DestinationParentPath
            _Write-StandardMessage -Message ("[CREATE] Created output directory: {0}" -f $DestinationParentDirectory) -Level 'INF'
        }
    }

    # Idempotency gate: handle existing archive by policy (default OverwriteIfExists).
    $DestinationFileExists = Test-Path -LiteralPath $DestinationFile -PathType Leaf
    if ($DestinationFileExists) {
        if ($FilePolicy -eq 'SkipIfExists') {
            _Write-StandardMessage -Message ("[SKIP] Zip already present, skipped: {0}" -f $DestinationFile) -Level 'INF'
            return
        }
        if ($FilePolicy -eq 'OverwriteIfExists') {
            Remove-Item -LiteralPath $DestinationFile -Force
            _Write-StandardMessage -Message ("[OVERWRITE] Removed existing zip (overwrite policy): {0}" -f $DestinationFile) -Level 'INF'
        }
    }

    # Compress directory contents (not the root directory node).
    $SourceContentPattern = Join-Path -Path $SourceFullPath -ChildPath '*'

    $oldProgressPreference = $ProgressPreference
    try {
        # Temporarily suppress progress bar from Compress-Archive.
        $ProgressPreference = 'SilentlyContinue'

        _Write-StandardMessage -Message (
            "[STATUS] Starting compression from '{0}' to '{1}' (Level={2}, Policy={3})." -f
            $SourceFullPath, $DestinationFile, $CompressionLevel, $FilePolicy
        ) -Level 'INF'

        Compress-Archive -Path $SourceContentPattern -DestinationPath $DestinationFile -CompressionLevel $CompressionLevel
    } catch {
        $ErrorMessage = $_.Exception.Message
        _Write-StandardMessage -Message ("[ERR] Failed to create archive: {0}" -f $ErrorMessage) -Level 'ERR'
        throw ("Failed to create archive. {0}" -f $ErrorMessage)
    } finally {
        # Restore previous progress preference.
        $ProgressPreference = $oldProgressPreference
    }

    _Write-StandardMessage -Message ("[OK] Compression finished, created zip: {0}" -f $DestinationFile) -Level 'INF'
}

function Add-FileToZipArchive {
<#
.SYNOPSIS
    Adds or updates a single file in a zip archive.

.DESCRIPTION
    Uses System.IO.Compression.ZipArchive to add or update a single file inside a .zip archive.
    If the destination zip does not exist, it is created.
    Optionally deletes the source file after a successful update.
    Entry behavior when an item already exists inside the zip is controlled via EntryPolicy.
    Optionally places the file into a date-based subfolder inside the zip based on UTC time.
    Includes a retry policy and a failure policy (Strict vs BestEffort).

.PARAMETER SourceFile
    Full path to the file that should be stored inside the zip.

.PARAMETER DestinationZip
    Full path to the target .zip archive. Created if it does not exist.

.PARAMETER CompressionLevel
    Compression level for the zip entry.
    Valid values: Optimal, Fastest, NoCompression.

.PARAMETER EntryPolicy
    Behavior when an entry with the same name already exists in the zip.
    - OverwriteIfExists (default): overwrite the existing entry.
    - SkipIfExists: skip this file if an entry already exists.
    - FailIfExists: throw (or skip in BestEffort mode) if an entry already exists.

.PARAMETER DeleteSource
    Controls whether the source file is deleted after a successful write to the zip.
    - Delete (default): delete the source file.
    - Keep: keep the source file.

.PARAMETER DateFolderPattern
    Controls whether the entry is placed into a UTC date-based subfolder inside the zip.
    - None (default): no date subfolder, just the filename.
    - YYMMDD: folder like archived-at_utc_241123.
    - YYYYMMDD: folder like archived-at_utc_20251123.
    - YYYYMM: folder like archived-at_utc_202511.
    - YYYY: folder like archived-at_utc_2025.
    - YYYYMMDD_HH: folder like archived-at_utc_20251123_09 (hourly buckets).

.PARAMETER RetryCount
    Number of attempts to write into the zip before failing or skipping.
    Default: 3.

.PARAMETER RetryDelayMilliseconds
    Delay between retry attempts, in milliseconds.
    Default: 500.

.PARAMETER FailurePolicy
    Controls how failures are surfaced.
    - Strict (default): throw on unrecoverable failures.
    - BestEffort: log and skip on unrecoverable failures (no throw).

.EXAMPLE
    Add-FileToZipArchive -SourceFile "C:\Logs\app-2025-11-23.log" -DestinationZip "C:\Archives\logs.zip"

.EXAMPLE
    Add-FileToZipArchive -SourceFile "/var/log/app.log.1" -DestinationZip "/var/archive/app-logs.zip" -DeleteSource Keep

.EXAMPLE
    Add-FileToZipArchive -SourceFile "/var/log/app.log.1" -DestinationZip "/var/archive/app-logs.zip" -EntryPolicy SkipIfExists

.EXAMPLE
    # Store entries in daily UTC subfolders, e.g. archived-at_utc_241123/app.log
    Add-FileToZipArchive -SourceFile "C:\Logs\app.log" -DestinationZip "C:\Archives\logs.zip" -DateFolderPattern YYMMDD

.EXAMPLE
    # Best-effort behavior for scheduled tasks: never throw on zip contention
    Add-FileToZipArchive -SourceFile "C:\Logs\app.log" -DestinationZip "C:\Archives\logs.zip" -FailurePolicy BestEffort
#>
    [CmdletBinding(PositionalBinding=$false)]
    [Alias("Into-Zip")]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceFile,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationZip,

        [Parameter()]
        [ValidateSet('Optimal','Fastest','NoCompression')]
        [string]$CompressionLevel = 'Optimal',

        [Parameter()]
        [ValidateSet('OverwriteIfExists','SkipIfExists','FailIfExists')]
        [string]$EntryPolicy = 'OverwriteIfExists',

        [Parameter()]
        [ValidateSet('Delete','Keep')]
        [string]$DeleteSource = 'Delete',

        [Parameter()]
        [ValidateSet('None','YYMMDD','YYYYMMDD','YYYYMM','YYYY','YYYYMMDD_HH')]
        [string]$DateFolderPattern = 'None',

        [Parameter()]
        [ValidateRange(1,60)]
        [int]$RetryCount = 3,

        [Parameter()]
        [ValidateRange(10,600000)]
        [int]$RetryDelayMilliseconds = 500,

        [Parameter()]
        [ValidateSet('Strict','BestEffort')]
        [string]$FailurePolicy = 'BestEffort'
    )

    function local:_Write-StandardMessage {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
            [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$Level='INF',
            [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$MinLevel
        )

        if ($null -eq $Message) {
            $Message = [string]::Empty
        }

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
            for($i=0;$i -lt $stack.Count;$i++){
                $f=$stack[$i];$fn=$f.FunctionName;$sn=$f.ScriptName
                if($fn -and $fn -ne $helperName -and -not $fn.StartsWith('_') -and (-not $helperScript -or -not $sn -or $sn -ne $helperScript)){$caller=$f;break}
            }
            if(-not $caller){
                for($i=0;$i -lt $stack.Count;$i++){
                    $f=$stack[$i];$fn=$f.FunctionName
                    if($fn -and $fn -ne $helperName -and -not $fn.StartsWith('_')){$caller=$f;break}
                }
            }
            if(-not $caller){
                for($i=0;$i -lt $stack.Count;$i++){
                    $f=$stack[$i];$fn=$f.FunctionName;$sn=$f.ScriptName
                    if($fn -and $fn -ne $helperName -and (-not $helperScript -or -not $sn -or $sn -ne $helperScript)){$caller=$f;break}
                }
            }
            if(-not $caller){
                for($i=0;$i -lt $stack.Count;$i++){
                    $f=$stack[$i];$fn=$f.FunctionName
                    if($fn -and $fn -ne $helperName){$caller=$f;break}
                }
            }
        }
        if(-not $caller){$caller=[pscustomobject]@{ScriptName=$PSCommandPath;FunctionName=$null}}
        $lineNumber=$null
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
        $cfg=@{
            TRC=@{Fore='DarkGray';Back=$null}
            DBG=@{Fore='Cyan';Back=$null}
            INF=@{Fore='Green';Back=$null}
            WRN=@{Fore='Yellow';Back=$null}
            ERR=@{Fore='Red';Back=$null}
            FTL=@{Fore='Red';Back='DarkRed'}
        }[$lvl]
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

    # First call: title (no tag prefix in message)
    _Write-StandardMessage -Message '--- Add single file into zip archive ---' -Level 'INF'

    # Resolve and validate source file, but SKIP/WARN if missing or invalid.
    $SourceResolved = Resolve-Path -LiteralPath $SourceFile -ErrorAction SilentlyContinue
    if ($null -eq $SourceResolved) {
        _Write-StandardMessage -Message ("[SKIP] Source file not found; skipping: {0}" -f $SourceFile) -Level 'WRN'
        return
    }
    $SourceFullPath = $SourceResolved.Path
    if (-not (Test-Path -LiteralPath $SourceFullPath -PathType Leaf)) {
        _Write-StandardMessage -Message ("[SKIP] Path is not a file; skipping: {0}" -f $SourceFullPath) -Level 'WRN'
        return
    }

    # Build date-based subfolder (UTC) if requested, using "archived-at_utc_<pattern>".
    $utcNow     = [DateTime]::UtcNow
    $dateCore   = $null
    switch ($DateFolderPattern) {
        'None'        { $dateCore = $null }
        'YYMMDD'      { $dateCore = $utcNow.ToString('yyMMdd') }
        'YYYYMMDD'    { $dateCore = $utcNow.ToString('yyyyMMdd') }
        'YYYYMM'      { $dateCore = $utcNow.ToString('yyyyMM') }
        'YYYY'        { $dateCore = $utcNow.ToString('yyyy') }
        'YYYYMMDD_HH' { $dateCore = $utcNow.ToString('yyyyMMdd_HH') }
        default       { $dateCore = $null }
    }

    $dateFolder = if ([string]::IsNullOrEmpty($dateCore)) {
        $null
    } else {
        "archived-at_utc_{0}" -f $dateCore
    }

    # Ensure destination parent directory exists when needed.
    $DestinationParentPath = Split-Path -Path $DestinationZip -Parent
    if ($null -ne $DestinationParentPath -and $DestinationParentPath -ne '') {
        if (-not (Test-Path -LiteralPath $DestinationParentPath -PathType Container)) {
            New-Item -ItemType Directory -Path $DestinationParentPath -Force | Out-Null
            _Write-StandardMessage -Message ("[CREATE] Created output directory: {0}" -f $DestinationParentPath) -Level 'INF'
        }
    }

    $zipExists       = Test-Path -LiteralPath $DestinationZip -PathType Leaf
    $entryLeafName   = [System.IO.Path]::GetFileName($SourceFullPath)
    $entryName       = if ([string]::IsNullOrEmpty($dateFolder)) {
                           $entryLeafName
                       } else {
                           "{0}/{1}" -f $dateFolder, $entryLeafName
                       }

    $operationResult = 'None' # 'None' | 'Wrote' | 'Skipped'

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $fs  = $null
        $zip = $null

        try {
            $fsMode  = if ($zipExists) { [System.IO.FileMode]::Open } else { [System.IO.FileMode]::Create }
            $zipMode = if ($zipExists) { [System.IO.Compression.ZipArchiveMode]::Update } else { [System.IO.Compression.ZipArchiveMode]::Create }

            if (-not $zipExists -and $attempt -eq 1) {
                _Write-StandardMessage -Message ("[CREATE] Creating new zip archive: {0}" -f $DestinationZip) -Level 'INF'
            } elseif ($zipExists -and $attempt -eq 1) {
                _Write-StandardMessage -Message ("[STATUS] Opening existing zip archive: {0}" -f $DestinationZip) -Level 'INF'
            }

            $fs  = [System.IO.File]::Open($DestinationZip, $fsMode, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $zip = New-Object System.IO.Compression.ZipArchive($fs, $zipMode, $false)

            # Inspect existing entries (match by full entry name, including optional date folder).
            $existingEntry = $null
            foreach ($e in $zip.Entries) {
                if ($e.FullName -eq $entryName) {
                    $existingEntry = $e
                    break
                }
            }

            if ($existingEntry) {
                switch ($EntryPolicy) {
                    'SkipIfExists' {
                        _Write-StandardMessage -Message ("[SKIP] Entry '{0}' already exists in '{1}'; skipping and keeping source file: {2}" -f $entryName, $DestinationZip, $SourceFullPath) -Level 'INF'
                        $operationResult = 'Skipped'
                        return
                    }
                    'FailIfExists' {
                        if ($FailurePolicy -eq 'BestEffort') {
                            _Write-StandardMessage -Message (
                                "[SKIP] (BestEffort) Entry '{0}' already exists in '{1}' (EntryPolicy=FailIfExists, FailurePolicy=BestEffort); treating as warning and skipping, keeping source file: {2}" -f
                                $entryName, $DestinationZip, $SourceFullPath
                            ) -Level 'WRN'
                            $operationResult = 'Skipped'
                            return
                        } else {
                            _Write-StandardMessage -Message (
                                "[ERR] Entry '{0}' already exists in '{1}' (EntryPolicy=FailIfExists)." -f
                                $entryName, $DestinationZip
                            ) -Level 'ERR'
                            throw ("Zip entry '{0}' already exists in '{1}' and EntryPolicy is FailIfExists." -f $entryName, $DestinationZip)
                        }
                    }
                    'OverwriteIfExists' {
                        _Write-StandardMessage -Message ("[STATUS] Entry '{0}' already exists in '{1}'; overwriting per EntryPolicy." -f $entryName, $DestinationZip) -Level 'INF'
                        $existingEntry.Delete()
                    }
                }
            } else {
                if ($zipExists) {
                    _Write-StandardMessage -Message ("[STATUS] Adding new entry '{0}' to existing archive: {1}" -f $entryName, $DestinationZip) -Level 'INF'
                }
            }

            _Write-StandardMessage -Message (
                "[STATUS] Writing file '{0}' as entry '{1}' to '{2}' (Level={3}, EntryPolicy={4}, Attempt={5}/{6})." -f
                $SourceFullPath, $entryName, $DestinationZip, $CompressionLevel, $EntryPolicy, $attempt, $RetryCount
            ) -Level 'INF'

            $compressionEnum = [System.IO.Compression.CompressionLevel]::$CompressionLevel
            $entry           = $zip.CreateEntry($entryName, $compressionEnum)

            $sourceStream = $null
            $entryStream  = $null
            try {
                $sourceStream = [System.IO.File]::OpenRead($SourceFullPath)
                $entryStream  = $entry.Open()
                $sourceStream.CopyTo($entryStream)
            } finally {
                if ($entryStream)  { $entryStream.Dispose() }
                if ($sourceStream) { $sourceStream.Dispose() }
            }

            _Write-StandardMessage -Message ("[OK] File stored in zip as '{0}' in '{1}'." -f $entryName, $DestinationZip) -Level 'INF'
            $operationResult = 'Wrote'
            break
        } catch {
            $err = $_.Exception.Message
            if ($attempt -lt $RetryCount) {
                _Write-StandardMessage -Message (
                    "[RETRY] Failed to add file to zip (attempt {0}/{1}); retrying in {2} ms. Error: {3}" -f
                    $attempt, $RetryCount, $RetryDelayMilliseconds, $err
                ) -Level 'WRN'
                Start-Sleep -Milliseconds $RetryDelayMilliseconds
                continue
            } else {
                if ($FailurePolicy -eq 'BestEffort') {
                    _Write-StandardMessage -Message (
                        "[SKIP] (BestEffort) Failed to add file to zip after {0} attempts; treating as warning and giving up, continuing run. Error: {1}" -f
                        $RetryCount, $err
                    ) -Level 'WRN'
                    $operationResult = 'Skipped'
                    return
                } else {
                    _Write-StandardMessage -Message (
                        "[ERR] Failed to add file to zip after {0} attempts: {1}" -f
                        $RetryCount, $err
                    ) -Level 'ERR'
                    throw ("Failed to add file to zip after {0} attempts. {1}" -f $RetryCount, $err)
                }
            }
        } finally {
            if ($zip) { $zip.Dispose() }
            if ($fs)  { $fs.Dispose()  }
        }
    }

    if ($operationResult -eq 'Wrote' -and $DeleteSource -eq 'Delete') {
        try {
            Remove-Item -LiteralPath $SourceFullPath -Force
            _Write-StandardMessage -Message ("[DELETE] Removed source file: {0}" -f $SourceFullPath) -Level 'INF'
        } catch {
            $err2 = $_.Exception.Message
            if ($FailurePolicy -eq 'BestEffort') {
                _Write-StandardMessage -Message (
                    "[WRN] (BestEffort) Failed to delete source file '{0}'; treating as warning and continuing. Error: {1}" -f
                    $SourceFullPath, $err2
                ) -Level 'WRN'
                return
            } else {
                _Write-StandardMessage -Message (
                    "[WRN] Failed to delete source file '{0}': {1}" -f
                    $SourceFullPath, $err2
                ) -Level 'WRN'
                throw ("Failed to delete source file '{0}': {1}" -f $SourceFullPath, $err2)
            }
        }
    }
}

# Add-FileToZipArchive -SourceFile "C:\Temp\Eigenverft.App.ReverseProxy-drops\sln\Eigenverft.App.ReverseProxy\production\0.1.20256.47288\LICENSE-SERILOG_EXTENSIONS_HOSTING" -DestinationZip "C:\Archives\logs.zip" -DateFolderPattern YYYYMMDD
# Write-Output "Done"
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
    function _Write-StandardMessage {
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
        $ts=[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss:fff')
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
            _Write-StandardMessage -Message ("Created output directory: {0}" -f $DestinationParentDirectory)
        }
    }

    # Idempotency gate: handle existing archive by policy (default OverwriteIfExists).
    $DestinationFileExists = Test-Path -LiteralPath $DestinationFile -PathType Leaf
    if ($DestinationFileExists) {
        if ($FilePolicy -eq 'SkipIfExists') {
            _Write-StandardMessage -Message ("Zip already present, skipped: {0}" -f $DestinationFile)
            return
        }
        if ($FilePolicy -eq 'OverwriteIfExists') {
            Remove-Item -LiteralPath $DestinationFile -Force
            _Write-StandardMessage -Message ("Removed existing zip (overwrite policy): {0}" -f $DestinationFile)
        }
    }

    # Compress directory contents (not the root directory node).
    $SourceContentPattern = Join-Path -Path $SourceFullPath -ChildPath '*'
    try {
        Compress-Archive -Path $SourceContentPattern -DestinationPath $DestinationFile -CompressionLevel $CompressionLevel
    } catch {
        $ErrorMessage = $_.Exception.Message
        throw ("Failed to create archive. {0}" -f $ErrorMessage)
    }

    _Write-StandardMessage -Message ("Created zip: {0}" -f $DestinationFile)
}


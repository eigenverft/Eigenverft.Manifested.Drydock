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
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Message,
            [Parameter(Mandatory=$false)]
            [ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')]
            [string]$Level = 'INF',
            [Parameter(Mandatory=$false)]
            [ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')]
            [string]$MinLevel
        )
        if (-not $PSBoundParameters.ContainsKey('MinLevel')) {
            if ($Global:ConsoleLogMinLevel) { $MinLevel = $Global:ConsoleLogMinLevel } else { $MinLevel = 'INF' }
        }
        $sevMap = @{ TRC=0; DBG=1; INF=2; WRN=3; ERR=4; FTL=5 }
        $lvl = $Level.ToUpperInvariant()
        $min = $MinLevel.ToUpperInvariant()
        $sev = $sevMap[$lvl]
        $gate= $sevMap[$min]
        if ($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4) { $lvl = $min ; $sev = $gate }
        if ($sev -lt $gate) { return }
        $ts = ([DateTime]::UtcNow).ToString('yyyy-MM-dd HH:mm:ss:fff')
        $stack      = Get-PSCallStack
        $helperName = $MyInvocation.MyCommand.Name
        $orgFunc    = $null
        $caller     = $null
        if ($stack) {
            $orgIdx = -1
            for ($i = 0; $i -lt $stack.Count; $i++) {
                if ($stack[$i].FunctionName -ne $helperName) { $orgFunc = $stack[$i]; $orgIdx = $i; break }
            }
            if ($orgIdx -ge 0) {
                $callerIdx = $orgIdx + 1
                if ($stack.Count -gt $callerIdx) { $caller = $stack[$callerIdx] } else { $caller = $orgFunc }
            }
        }
        if (-not $caller) { $caller = [pscustomobject]@{ ScriptName = $PSCommandPath; FunctionName = '<scriptblock>' } }
        $file = if ($caller.ScriptName) { Split-Path -Leaf $caller.ScriptName } else { 'console' }
        $func = if ($caller.FunctionName) { $caller.FunctionName } else { '<scriptblock>' }
        $line = "[{0} {1}] [{2}] [{3}] {4}" -f $ts, $lvl, $file, $func, $Message
        if ($sev -ge 4) {
            if ($ErrorActionPreference -eq 'Stop') {
                Write-Error -Message $line -ErrorId ("ConsoleLog.{0}" -f $lvl) -Category NotSpecified -ErrorAction Stop
            } else {
                Write-Error -Message $line -ErrorId ("ConsoleLog.{0}" -f $lvl) -Category NotSpecified
            }
        } else {
            Write-Information -MessageData $line -InformationAction Continue
        }
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


function Convert-FilePlaceholders {
<#
.SYNOPSIS
Transforms a template file by replacing {{Placeholders}} with provided values and writes the result to an output file.

.DESCRIPTION
Reads all text from an input file, replaces placeholders of the form {{Name}} using values from a hashtable,
and writes the rendered content to the output file. The function:
- Preserves the input file's encoding (BOM-aware) when writing the output.
- Creates the output directory if missing.
- Is idempotent: skips writing when no content change is detected.
- Emits minimal, standardized messages via _Write-StandardMessage for key actions only.

.PARAMETER InputFile
Full path to the template file containing placeholders like {{Name}}.

.PARAMETER OutputFile
Full path for the rendered output file.

.PARAMETER Replacements
Hashtable where keys are placeholder names (without braces) and values are replacement strings.

.EXAMPLE
# Basic usage (Windows paths)
$map = @{ sourceCodeDirectory = 'C:\Projects\MyApp'; outputDirectory = 'C:\Out' }
Convert-FilePlaceholders -InputFile 'C:\Tpl\appsettings.template.json' -OutputFile 'C:\Out\appsettings.json' -Replacements $map

.EXAMPLE
# Cross-platform usage (macOS/Linux paths)
$map = @{ imagePath = '/opt/app/images'; dataRoot = '/var/data/app' }
Convert-FilePlaceholders -InputFile '/srv/tpl/config.tpl' -OutputFile '/srv/app/config.json' -Replacements $map

.EXAMPLE
# Warns about unused keys or unresolved placeholders (default behavior)
$map = @{ Foo = 'X'; Bar = 'Y' }
Convert-FilePlaceholders -InputFile './in.tpl' -OutputFile './out.txt' -Replacements $map

.NOTES
- Compatibility: Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
- No SupportsShouldProcess, no pipeline binding, StrictMode 3 safe.
- Keys must match: letters, digits, underscore, hyphen, or dot.
#>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $InputFile,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputFile,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable] $Replacements
    )

    # Inline helpers (local scope, deterministic, no pipeline writes)

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
            if ($Global:ConsoleLogMinLevel) {
                $MinLevel = $Global:ConsoleLogMinLevel
            } else {
                $MinLevel = 'INF'
            }
        }
        $sevMap = @{ TRC=0; DBG=1; INF=2; WRN=3; ERR=4; FTL=5 }
        $lvl = $Level.ToUpperInvariant()
        $min = $MinLevel.ToUpperInvariant()
        $sev = $sevMap[$lvl]
        $gate = $sevMap[$min]
        if ($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4) {
            $lvl = $min
            $sev = $gate
        }
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
        $line = ("[{0} {1}] [{2}] [{3}] {4}" -f $ts, $lvl, $file, $func, $Message)
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

    function _Validate-Keys {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [hashtable] $Map
        )
        $pattern = '^[A-Za-z0-9_\.\-]+$'
        foreach ($k in $Map.Keys) {
            if ($null -eq $k) {
                _Write-StandardMessage -Message "Null key detected in Replacements." -Level ERR
                throw "Replacement keys must be non-null."
            }
            $keyText = [string]$k
            if (-not ([System.Text.RegularExpressions.Regex]::IsMatch($keyText, $pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant))) {
                _Write-StandardMessage -Message ("Invalid key '{0}'. Allowed: letters, digits, underscore, hyphen, dot." -f $keyText) -Level ERR
                throw ("Invalid replacement key '{0}'." -f $keyText)
            }
        }
    }

    function _Read-AllTextWithEncoding {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([string] $Path)
        $encoding = $null
        $content = $null
        $fs = $null
        $sr = $null
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $sr = New-Object System.IO.StreamReader($fs, $true)
            $content = $sr.ReadToEnd()
            $encoding = $sr.CurrentEncoding
        } finally {
            if ($null -ne $sr) { $sr.Dispose() }
            if ($null -ne $fs) { $fs.Dispose() }
        }
        [pscustomobject]@{ Content = $content; Encoding = $encoding }
    }

    function _Write-AllTextWithEncoding {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string] $Path,
            [string] $Text,
            [System.Text.Encoding] $Encoding
        )
        [System.IO.File]::WriteAllText($Path, $Text, $Encoding)
    }

    function _Replace-Placeholders {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string] $Text,
            [hashtable] $Map
        )
        $pattern = '\{\{(?<name>[A-Za-z0-9_\.\-]+)\}\}'
        $regexOptions = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
        $regex = New-Object System.Text.RegularExpressions.Regex($pattern, $regexOptions)
        $used = @{}
        $missing = @{}
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
            param([System.Text.RegularExpressions.Match] $m)
            $n = $m.Groups['name'].Value
            if ($Map.ContainsKey($n)) {
                $used[$n] = $true
                return [string]$Map[$n]
            } else {
                $missing[$n] = $true
                return $m.Value
            }
        }
        $out = $regex.Replace($Text, $evaluator)
        [pscustomobject]@{
            Text = $out
            UsedKeys = @($used.Keys)
            MissingNames = @($missing.Keys)
        }
    }

    # Validate input existence and map keys
    if (-not [System.IO.File]::Exists($InputFile)) {
        _Write-StandardMessage -Message ("Input file not found: {0}" -f $InputFile) -Level ERR
        throw ("Input file not found: {0}" -f $InputFile)
    }
    if ($Replacements.Count -eq 0) {
        _Write-StandardMessage -Message "No replacements provided; nothing to do." -Level WRN
        return
    }
    _Validate-Keys -Map $Replacements

    # Read input (preserve encoding)
    $readIn = $null
    try {
        $readIn = _Read-AllTextWithEncoding -Path $InputFile
    } catch {
        _Write-StandardMessage -Message ("Failed to read input file: {0}" -f $InputFile) -Level ERR
        throw ("Failed to read input file: {0}" -f $InputFile)
    }
    $inputText = $readIn.Content
    $inputEncoding = $readIn.Encoding

    # Replace placeholders
    $rep = _Replace-Placeholders -Text $inputText -Map $Replacements
    $rendered = $rep.Text

    # Warn about unresolved placeholders and unused keys
    if ($rep.MissingNames.Count -gt 0) {
        _Write-StandardMessage -Message ("Unresolved placeholders in content: {0}" -f ([string]::Join(', ', $rep.MissingNames))) -Level WRN
    }
    $unused = @()
    foreach ($k in $Replacements.Keys) {
        if (-not ($rep.UsedKeys -contains $k)) { $unused += [string]$k }
    }
    if ($unused.Count -gt 0) {
        _Write-StandardMessage -Message ("Provided keys not found in content: {0}" -f ([string]::Join(', ', $unused))) -Level WRN
    }

    # Ensure output directory exists
    $outDir = [System.IO.Path]::GetDirectoryName($OutputFile)
    if ($null -ne $outDir -and $outDir.Length -gt 0) {
        if (-not [System.IO.Directory]::Exists($outDir)) {
            try {
                [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
                _Write-StandardMessage -Message ("Created directory: {0}" -f $outDir) -Level INF
            } catch {
                _Write-StandardMessage -Message ("Failed to create directory: {0}" -f $outDir) -Level ERR
                throw ("Failed to create directory: {0}" -f $outDir)
            }
        }
    }

    # Idempotent write: only write when content differs or file missing; preserve input encoding
    $shouldWrite = $true
    if ([System.IO.File]::Exists($OutputFile)) {
        $readOut = $null
        try {
            $readOut = _Read-AllTextWithEncoding -Path $OutputFile
        } catch {
            _Write-StandardMessage -Message ("Failed to read output file for comparison: {0}" -f $OutputFile) -Level ERR
            throw ("Failed to read output file for comparison: {0}" -f $OutputFile)
        }
        if ([string]::Equals($rendered, $readOut.Content, [System.StringComparison]::Ordinal)) {
            $shouldWrite = $false
            _Write-StandardMessage -Message ("No changes for: {0}" -f $OutputFile) -Level INF
        }
    }

    if ($shouldWrite) {
        try {
            _Write-AllTextWithEncoding -Path $OutputFile -Text $rendered -Encoding $inputEncoding
            if ([System.IO.File]::Exists($OutputFile)) {
                _Write-StandardMessage -Message ("Updated file: {0}" -f $OutputFile) -Level INF
            } else {
                _Write-StandardMessage -Message ("Created file: {0}" -f $OutputFile) -Level INF
            }
        } catch {
            _Write-StandardMessage -Message ("Failed to write output file: {0}" -f $OutputFile) -Level ERR
            throw ("Failed to write output file: {0}" -f $OutputFile)
        }
    }
}

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

function Convert-TemplateFilePlaceholders {
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

Now supports two parameter sets:
1) Input/Output mode (original): -InputFile + -OutputFile + -Replacements
2) Template mode (new): -TemplateFile + -Replacements
   In Template mode the output file path is derived in the same directory by removing a pre-extension token
   of ".template", ".tpl", or ".tlp" (case-insensitive). Examples:
   - "appsettings.template.json" → "appsettings.json"
   - "appsettings.tlp.json"      → "appsettings.json"
   - "appsettings.tpl.json"      → "appsettings.json"

.PARAMETER InputFile
Full path to the template file containing placeholders like {{Name}}. (Input/Output mode)

.PARAMETER OutputFile
Full path for the rendered output file. (Input/Output mode)

.PARAMETER TemplateFile
Full path to the template file. The output file path will be derived automatically as described above. (Template mode)

.PARAMETER Replacements
Hashtable where keys are placeholder names (without braces) and values are replacement strings.

.EXAMPLE
# Original mode (Windows paths)
$map = @{ sourceCodeDirectory = 'C:\Projects\MyApp'; outputDirectory = 'C:\Out' }
Convert-TemplateFilePlaceholders -InputFile 'C:\Tpl\appsettings.template.json' -OutputFile 'C:\Out\appsettings.json' -Replacements $map

.EXAMPLE
# New template mode (.template)
$map = @{ imagePath = '/opt/app/images'; dataRoot = '/var/data/app' }
Convert-TemplateFilePlaceholders -TemplateFile '/srv/tpl/config.template.json' -Replacements $map
# -> writes '/srv/tpl/config.json'

.EXAMPLE
# New template mode (.tlp or .tpl)
$map = @{ Foo = 'X'; Bar = 'Y' }
Convert-TemplateFilePlaceholders -TemplateFile './appsettings.tlp.json' -Replacements $map
# -> writes './appsettings.json'

.NOTES
- Compatibility: Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
- No SupportsShouldProcess, no pipeline binding, StrictMode 3 safe.
- Keys must match: letters, digits, underscore, hyphen, or dot.
#>

    [CmdletBinding(DefaultParameterSetName = 'InOut')]
    param(
        # ------- Original parameter set -------
        [Parameter(Mandatory = $true, ParameterSetName = 'InOut')]
        [ValidateNotNullOrEmpty()]
        [string] $InputFile,

        [Parameter(Mandatory = $true, ParameterSetName = 'InOut')]
        [ValidateNotNullOrEmpty()]
        [string] $OutputFile,

        # ------- New template parameter set -------
        [Parameter(Mandatory = $true, ParameterSetName = 'Tpl')]
        [ValidateNotNullOrEmpty()]
        [string] $TemplateFile,

        # ------- Common -------
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable] $Replacements
    )

    # Inline helpers (local scope, deterministic, no pipeline writes)

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

    function _Derive-OutputPathFromTemplate {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([Parameter(Mandatory=$true)][string] $Path)

        $dir      = [System.IO.Path]::GetDirectoryName($Path)
        $file     = [System.IO.Path]::GetFileName($Path)
        $ext      = [System.IO.Path]::GetExtension($file)
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file)

        if ($baseName.EndsWith('.template', [System.StringComparison]::OrdinalIgnoreCase)) {
            $baseName = $baseName.Substring(0, $baseName.Length - 9)
        } elseif ($baseName.EndsWith('.tpl', [System.StringComparison]::OrdinalIgnoreCase)) {
            $baseName = $baseName.Substring(0, $baseName.Length - 4)
        } elseif ($baseName.EndsWith('.tlp', [System.StringComparison]::OrdinalIgnoreCase)) {
            $baseName = $baseName.Substring(0, $baseName.Length - 4)
        }

        $derivedName = $baseName + $ext
        if ([string]::IsNullOrWhiteSpace($dir)) { return $derivedName }
        return [System.IO.Path]::Combine($dir, $derivedName)
    }

    # ------- Template parameter set handling (derive paths before validation) -------
    if ($PSCmdlet.ParameterSetName -eq 'Tpl') {
        $InputFile  = $TemplateFile
        $OutputFile = _Derive-OutputPathFromTemplate -Path $TemplateFile
        _Write-StandardMessage -Message ("Derived output from template: {0} -> {1}" -f $TemplateFile, $OutputFile) -Level DBG
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

    # Return the effective output file path (even if unchanged)
    Get-Item $OutputFile
}

function Convert-StringToBaseObject {
<#
.SYNOPSIS
Converts string input into the most appropriate strongly-typed object using en-US culture.

.DESCRIPTION
Robust helper for normalizing textual output from tools into useful base types.
First successful match wins; if nothing matches, the original string is returned.

Conversion order:
- Non-strings            : returned unchanged
- Null-like literals     : $null
- Boolean                : true/false
- JSON                   : object/array when clearly JSON-shaped
- Guid
- Int32, Int64, BigInteger
- Special floating       : NaN, +/-Infinity
- Decimal                : simple fixed-point (no exponent)
- Double                 : general floating (incl. exponents)
- Version                : n.n / n.n.n / n.n.n.n   (checked before Date/Time to avoid 1.2.3 -> DateTime)
- TimeSpan               : (en-US)
- DateTime               : en-US, then ISO/Roundtrip

If none match, returns the original string.

.PARAMETER InputObject
Value to convert. Strings are analyzed; non-strings are returned as-is.

.PARAMETER TreatEmptyAsNull
When set, empty/whitespace-only strings are converted to $null.

.EXAMPLE
"true","42","3.14","2024-01-02","{`"a`":1}" |
    ForEach-Object { Convert-StringToBaseObject -InputObject $_ }

.EXAMPLE
$typed = Convert-StringToBaseObject -InputObject "1.2.3"
# returns [version] 1.2.3
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter()]
        [switch]$TreatEmptyAsNull
    )

    # Non-string passthrough
    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -isnot [string]) {
        return $InputObject
    }

    # Constants per invocation (PS5-safe)
    $cultureEnUs   = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
    $integerStyles = [System.Globalization.NumberStyles]::Integer
    $floatStyles   = [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands
    $dateStyles    = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
    $nullLiterals  = @('null','<null>','none','n/a')

    $raw  = $InputObject
    $text = $raw.Trim()

    # Empty handling
    if ($text.Length -eq 0) {
        if ($TreatEmptyAsNull) { return $null }
        return $raw
    }

    $lower = $text.ToLowerInvariant()

    # 1) Null-like
    if ($nullLiterals -contains $lower) {
        return $null
    }

    # 2) Boolean
    $boolResult = $false
    if ([bool]::TryParse($text, [ref]$boolResult)) {
        return $boolResult
    }

    # 3) JSON (only clearly JSON-shaped)
    if (
        ($text.StartsWith('{') -and $text.EndsWith('}')) -or
        ($text.StartsWith('[') -and $text.EndsWith(']'))
    ) {
        try {
            $json = $text | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $json) {
                return $json
            }
        }
        catch {
            # ignore malformed; continue
        }
    }

    # 4) Guid
    $guidResult = [guid]::Empty
    if ([guid]::TryParse($text, [ref]$guidResult)) {
        return $guidResult
    }

    # 5) Int32
    $int32Result = 0
    if ([int]::TryParse($text, $integerStyles, $cultureEnUs, [ref]$int32Result)) {
        return $int32Result
    }

    # 6) Int64
    $int64Result = 0L
    if ([long]::TryParse($text, $integerStyles, $cultureEnUs, [ref]$int64Result)) {
        return $int64Result
    }

    # 7) BigInteger (only pure integer forms)
    if ($text -match '^[\+\-]?\d+$') {
        try {
            $bigInt = [System.Numerics.BigInteger]::Parse($text, $cultureEnUs)
            return $bigInt
        }
        catch {
            # ignore
        }
    }

    # 8) Special floating tokens
    switch ($lower) {
        'nan'       { return [double]::NaN }
        'infinity'  { return [double]::PositiveInfinity }
        '+infinity' { return [double]::PositiveInfinity }
        '-infinity' { return [double]::NegativeInfinity }
    }

    # 9) Decimal (simple fixed-point, no exponent)
    if ($text -match '^[\+\-]?\d+(\.\d+)?$') {
        $decimalResult = [decimal]0
        if ([decimal]::TryParse($text, $floatStyles, $cultureEnUs, [ref]$decimalResult)) {
            return $decimalResult
        }
    }

    # 10) Double (general float)
    $doubleResult = [double]0
    if ([double]::TryParse($text, $floatStyles, $cultureEnUs, [ref]$doubleResult)) {
        return $doubleResult
    }

    # 11) Version (dotted numeric, 2-4 segments) BEFORE Date/Time to avoid 1.2.3 -> DateTime
    if ($text -match '^\d+(\.\d+){1,3}$') {
        try {
            $ver = New-Object System.Version($text)
            return $ver
        }
        catch {
            # ignore
        }
    }

    # 12) TimeSpan (en-US)
    $timeSpanResult = [TimeSpan]::Zero
    if ([TimeSpan]::TryParse($text, $cultureEnUs, [ref]$timeSpanResult)) {
        return $timeSpanResult
    }

    # 13) DateTime (en-US)
    $dateResult = [datetime]::MinValue
    if ([datetime]::TryParse($text, $cultureEnUs, $dateStyles, [ref]$dateResult)) {
        return $dateResult
    }

    # 14) DateTime (ISO / roundtrip, invariant)
    $dateIsoResult = [datetime]::MinValue
    if ([datetime]::TryParse(
            $text,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$dateIsoResult
        )) {
        return $dateIsoResult
    }

    # Fallback: original string
    return $raw
}


function Find-FilesByPattern {
<#
.SYNOPSIS
    Robust, manual (no -Recurse) filename search with Windows wildcards.
.DESCRIPTION
    Traverses the tree with an explicit stack (deep-first), continues on errors,
    and matches file names against one or more wildcard patterns (e.g. *.txt, *.sln).
    Returns an array of FileInfo objects.
.PARAMETER Path
    Root directory where the search should begin.
.PARAMETER Pattern
    Filename wildcard(s). Accepts array or comma/semicolon list (e.g. "*.txt;*.csproj").
.EXAMPLE
    $files = Find-FilesByPattern -Path "C:\MyProjects" -Pattern "*.txt;*.md"
    foreach ($f in $files) { $f.FullName }
#>
    [CmdletBinding()]
    [Alias("ffbp")]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,

        [Parameter(Mandatory=$true)]
        [string[]]$Pattern
    )

    # Validate root
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "The specified path '$Path' does not exist or is not a directory."
    }

    function _Norm-List {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([string[]]$Patterns)
        if (-not $Patterns) { return @() }
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($p in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $p -split '[,;]' | ForEach-Object {
                $t = $_.Trim()
                if ($t) { [void]$list.Add($t) }
            }
        }
        if ($list.Count -eq 0) { return @() }
        $list.ToArray()
    }

    # Normalize patterns (supports array or "a;b,c" lists)
    $pat = _Norm-List $Pattern
    if (-not $pat -or $pat.Count -eq 0) {
        throw "Pattern must not be empty."
    }

    # Prepare traversal
    try { $rootItem = Get-Item -LiteralPath $Path -ErrorAction Stop }
    catch { throw "Path '$Path' is not accessible: $_" }

    $stack   = New-Object System.Collections.Stack
    $stack.Push($rootItem)

    $fmatches = New-Object System.Collections.Generic.List[System.IO.FileInfo]

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()

        # Discover subdirectories
        $subs = @()
        try   { $subs = Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction Stop }
        catch { Write-Warning "Cannot list directories in '$($dir.FullName)': $_" }
        foreach ($sd in $subs) { $stack.Push($sd) }

        # Files in this directory
        $files = @()
        try   { $files = Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction Stop }
        catch { Write-Warning "Cannot list files in '$($dir.FullName)': $_" }

        foreach ($f in $files) {
            foreach ($p in $pat) {
                if ($f.Name -like $p) { [void]$fmatches.Add($f); break }
            }
        }
    }

    return @($fmatches.ToArray())
}

function Find-TreeContent {
<#
.SYNOPSIS
Manual deepest-first file discovery + Windows-style wildcard text search with smart AUTO fallback.

.DESCRIPTION
Two-phase search:
  1) Manual, error-resilient traversal (no -Recurse). Collect candidate files using Windows wildcards (*, ?, [...]).
  2) Scan candidates’ contents with the SAME wildcard rules for -FindText (case-insensitive, classic Windows feel).

Escaping (for BOTH filename and text patterns):
  - Use [*] for literal asterisk, and [?] for literal question mark.
  - Or escape with backslash: \*  \?  \[  \]   or backtick: `*  `?  `[  `]
  - Literal '[' or ']' can also be matched via '[[]' or '[]]'.

Encoding & AUTO mode:
  - Primary pass uses StreamReader with built-in BOM detection; fallback is Encoding.Default (ANSI/UTF-8 depending on OS).
  - If primary pass finds no matches AND no BOM was detected (i.e., Default was used),
    -Auto tries encodings in this order: UTF-8 → UTF-16 LE, and stops on the first that matches.
  - No binary scanning is performed.

Output:
  - Always returns an **array** of result objects with:
      Path, LineNumber, Snippet, Encoding, Newline
  - `Snippet` is trimmed around the match (configurable via -MaxLineChars).

Traversal order:
  - Files are processed from the deepest directory upward.

Robustness:
  - Directory/file enumeration and reads continue on errors (warnings only).
  - Single size guard: -MaxFileSizeBytes (applies to text scanning).

.PARAMETER Path
Root directory to search.

.PARAMETER Include
Filename wildcards (*, ?, [...]). Accepts array or comma/semicolon list. Default: '*'.

.PARAMETER Exclude
Wildcard(s) to skip (matched against FullName). Accepts array or comma/semicolon list.

.PARAMETER FindText
Content pattern using Windows wildcards (*, ?, [...]) with the escaping rules above.

.PARAMETER Auto
When no BOM is detected and the first pass finds no matches, try UTF-8 then UTF-16 LE (stop on first success).

.PARAMETER MaxFileSizeBytes
Max size per file for scanning. Default: 64MB.

.PARAMETER MaxLineChars
Max characters kept in the returned Snippet (centered on match). Default: 256.

.PARAMETER ShowProgress
Write-Host discovery and match feedback.

.EXAMPLE
Find-TreeContent -Path C:\repo -Include "*.cs;*.ps1" -FindText "*TODO?*" -ShowProgress

.EXAMPLE
Find-TreeContent -Path $PWD -Include "*" -Exclude "*\bin\*;*/obj/*" -FindText "[*]CRITICAL[*]" -ShowProgress

.EXAMPLE
Find-TreeContent -Path . -Include "*" -FindText "mani" -Auto | Format-Table
#>
    [CmdletBinding()]
    [Alias('ftc','deepfind')]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,

        [Parameter()]
        [string[]]$Include = @('*'),

        [Parameter()]
        [string[]]$Exclude,

        [Parameter(Mandatory=$true)]
        [string]$FindText,

        [switch]$Auto,

        [ValidateRange(1, 1GB)]
        [int]$MaxFileSizeBytes = 1048576,

        [ValidateRange(32, 4096)]
        [int]$MaxLineChars = 256,

        [switch]$ShowProgress
    )

    # ------------------------ Helpers ------------------------

    function _Norm-List {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([string[]]$Patterns)
        if (-not $Patterns) { return @() }
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($p in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $p -split '[,;]' | ForEach-Object {
                $t = $_.Trim()
                if ($t) { [void]$list.Add($t) }
            }
        }
        if ($list.Count -eq 0) { return @() }
        $list.ToArray()
    }

    function _WildcardToRegex {
        param([Parameter(Mandatory=$true)][string]$Pattern)
        # Convert Windows wildcards to a .NET regex (case-insensitive)
        $sb  = New-Object System.Text.StringBuilder
        $i   = 0
        $len = $Pattern.Length
        while ($i -lt $len) {
            $ch = $Pattern[$i]

            if (($ch -eq '\' -or $ch -eq '`') -and ($i + 1 -lt $len)) {
                $nx = $Pattern[$i+1]
                if ($nx -in @('*','?','[',']','\','`')) {
                    [void]$sb.Append([System.Text.RegularExpressions.Regex]::Escape([string]$nx))
                    $i += 2
                    continue
                }
            }

            if ($ch -eq '*') { [void]$sb.Append('.*'); $i++; continue }
            if ($ch -eq '?') { [void]$sb.Append('.');  $i++; continue }

            if ($ch -eq '[') {
                $j = $i + 1
                while ($j -lt $len -and $Pattern[$j] -ne ']') { $j++ }
                if ($j -lt $len -and $Pattern[$j] -eq ']') {
                    $content = $Pattern.Substring($i+1, $j-$i-1)
                    if ($content.Length -gt 0 -and $content[0] -eq '!') { $content = '^' + $content.Substring(1) }
                    $content = $content -replace '([\\\]\[.{}()+|$])','\\$1'
                    [void]$sb.Append('[' + $content + ']')
                    $i = $j + 1; continue
                }
                [void]$sb.Append('\['); $i++; continue
            }

            if ($ch -eq ']') { [void]$sb.Append('\]'); $i++; continue }
            [void]$sb.Append([System.Text.RegularExpressions.Regex]::Escape([string]$ch)); $i++
        }
        return '(?i:' + $sb.ToString() + ')'
    }

    function _GetEncodingByWebName([string]$name) {
        try { return [System.Text.Encoding]::GetEncoding($name) } catch { return $null }
    }

    function _MakeSnippet([string]$line, [int]$idx, [int]$len, [int]$maxChars) {
        if ($null -eq $line) { return $null }
        if ($line.Length -le $maxChars) { return $line }
        $context = [Math]::Max(0, [Math]::Floor(($maxChars - $len) / 2))
        $start = [Math]::Max(0, $idx - $context)
        if ($start + $maxChars -gt $line.Length) { $start = $line.Length - $maxChars }
        $slice = $line.Substring($start, [Math]::Min($maxChars, $line.Length - $start))
        $prefix = if ($start -gt 0) { '…' } else { '' }
        $suffix = if (($start + $slice.Length) -lt $line.Length) { '…' } else { '' }
        return "$prefix$slice$suffix"
    }

    function _Detect-Newline {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string]$Path,
            [System.Text.Encoding]$Encoding,
            [int]$MaxBytes = 131072
        )
        try {
            $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        } catch { return 'Unknown' }

        $readLen = [Math]::Min($fi.Length, [long]$MaxBytes)
        if ($readLen -le 0) { return 'Unknown' }

        try {
            $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            $buf = New-Object byte[] $readLen
            $null = $fs.Read($buf, 0, $buf.Length)
            $fs.Dispose()
        } catch { return 'Unknown' }

        try { $txt = $Encoding.GetString($buf, 0, $buf.Length) } catch { return 'Unknown' }

        $crlf = ([regex]::Matches($txt, "`r`n")).Count
        $txt2 = $txt -replace "`r`n", ''
        $cr   = ([regex]::Matches($txt2, "`r")).Count
        $lf   = ([regex]::Matches($txt2, "`n")).Count

        if ($crlf -gt 0 -and $cr -eq 0 -and $lf -eq 0) { return 'CRLF' }
        if ($crlf -eq 0 -and $cr -eq 0 -and $lf -gt 0) { return 'LF' }
        if ($crlf -eq 0 -and $cr -gt 0 -and $lf -eq 0) { return 'CR' }
        if ($crlf -eq 0 -and $crlf -eq 0 -and $cr -eq 0 -and $lf -eq 0) { return 'Unknown' }
        return 'Mixed'
    }

    function _Discover-Files {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string]$Root,
            [string[]]$Inc,
            [string[]]$Exc,
            [switch]$Progress
        )
        try { $rootItem = Get-Item -LiteralPath $Root -ErrorAction Stop }
        catch { throw "Path '$Root' is not accessible: $_" }

        $stack = New-Object System.Collections.Stack
        $stack.Push(@{ Item = $rootItem; Depth = 0 })

        $files = New-Object System.Collections.Generic.List[object]
        function _SegCount([string]$p) {
            if (-not $p) { return 0 }
            return ($p.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) -split '[\\/]+').Count
        }
        $rootSegs = _SegCount $rootItem.FullName

        while ($stack.Count -gt 0) {
            $frame = $stack.Pop()
            $dir   = $frame.Item
            $depth = $frame.Depth
            if ($Progress) { Write-Host "[DIR] $($dir.FullName)" -ForegroundColor Cyan }

            $subs = @()
            try   { $subs = Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction Stop }
            catch { Write-Warning "Cannot list directories in '$($dir.FullName)': $_" }

            foreach ($sd in $subs) { $stack.Push(@{ Item = $sd; Depth = $depth + 1 }) }

            $dirFiles = @()
            try   { $dirFiles = Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction Stop }
            catch { Write-Warning "Cannot list files in '$($dir.FullName)': $_" }

            foreach ($f in $dirFiles) {
                $name = $f.Name
                $full = $f.FullName
                $ok = $false
                foreach ($p in $Inc) { if ($name -like $p) { $ok = $true; break } }
                if (-not $ok) { continue }

                if ($Exc -and $Exc.Count -gt 0) {
                    $skip = $false
                    foreach ($e in $Exc) { if ($full -like $e) { $skip = $true; break } }
                    if ($skip) { continue }
                }

                $depthNow = [Math]::Max(0, (_SegCount $f.DirectoryName) - $rootSegs)
                if ($Progress) { Write-Host "  [FILE] $full" -ForegroundColor DarkGray }
                $files.Add([pscustomobject]@{
                    FullName = $full
                    Name     = $name
                    Depth    = [int]$depthNow
                    Length   = $f.Length
                }) | Out-Null
            }
        }

        $files | Sort-Object -Property `
            @{ Expression = 'Depth'; Descending = $true }, `
            @{ Expression = 'Name' ; Descending = $false }
    }

    function _Scan-TextSmart {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [string]$Path,
            [string]$RegexPattern,
            [int]$MaxBytes,
            [int]$MaxChars,
            [switch]$AllowFallback
        )
        $fi = $null
        try { $fi = Get-Item -LiteralPath $Path -ErrorAction Stop }
        catch { Write-Warning "Cannot access '$Path': $_"; return @() }

        if ($fi.Length -gt $MaxBytes) { Write-Verbose "Skip > MaxFileSizeBytes: $Path"; return @() }

        $rx = New-Object System.Text.RegularExpressions.Regex($RegexPattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)

        $results = New-Object System.Collections.Generic.List[object]
        $primaryEnc = $null

        # pass 1: BOM-aware (Default fallback)
        $fs = $null; $sr = $null
        try {
            $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::Default, $true)
            $null = $sr.Peek()
            $primaryEnc = $sr.CurrentEncoding

            $lineNo = 0
            while ($null -ne ($line = $sr.ReadLine())) {
                $lineNo++
                $m = $rx.Match($line)
                if ($m.Success) {
                    $snippet = (_MakeSnippet $line $m.Index $m.Length $MaxChars).Trim()
                    $results.Add([pscustomobject]@{
                        Path       = $Path
                        LineNumber = $lineNo
                        Snippet    = $snippet
                        Encoding   = $sr.CurrentEncoding.WebName
                    }) | Out-Null
                }
            }
        } catch {
            Write-Warning "Text scan failed: '$Path': $_"
        } finally {
            if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() }
        }

        if ($results.Count -gt 0) { return $results.ToArray() }

        # pass 2: AUTO fallback (only if allowed and no BOM recognized -> Default used)
        if ($AllowFallback -and $primaryEnc -and ($primaryEnc.WebName -eq [System.Text.Encoding]::Default.WebName)) {
            foreach ($enc in @([System.Text.Encoding]::UTF8, [System.Text.Encoding]::Unicode)) {
                $fs2 = $null; $sr2 = $null
                try {
                    $fs2 = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
                    $sr2 = New-Object System.IO.StreamReader($fs2, $enc, $false)

                    $lineNo2 = 0
                    while ($null -ne ($line2 = $sr2.ReadLine())) {
                        $lineNo2++
                        $m2 = $rx.Match($line2)
                        if ($m2.Success) {
                            $snippet2 = (_MakeSnippet $line2 $m2.Index $m2.Length $MaxChars).Trim()
                            $results.Add([pscustomobject]@{
                                Path       = $Path
                                LineNumber = $lineNo2
                                Snippet    = $snippet2
                                Encoding   = $enc.WebName
                            }) | Out-Null
                        }
                    }
                } catch {
                    Write-Verbose "Alt-encoding scan failed for '$Path' with $($enc.WebName): $_"
                } finally {
                    if ($sr2) { $sr2.Dispose() } elseif ($fs2) { $fs2.Dispose() }
                }
                if ($results.Count -gt 0) { break } # stop on first successful encoding
            }
        }

        return $results.ToArray()
    }

    # ------------------------ Validate & prepare ------------------------

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Path '$Path' does not exist or is not a directory."
    }

    $inc = _Norm-List $Include
    if (-not $inc -or $inc.Count -eq 0) { $inc = @('*') }
    $exc = _Norm-List $Exclude

    $regexPattern = _WildcardToRegex -Pattern $FindText

    if ($ShowProgress) { Write-Host "[DISCOVERY] Enumerating '$Path'..." -ForegroundColor Yellow }

    # ------------------------ Phase 1: discovery ------------------------
    $candidates = _Discover-Files -Root $Path -Inc $inc -Exc $exc -Progress:$ShowProgress

    if ($ShowProgress) {
        Write-Host "[DISCOVERY] $($candidates.Count) candidate file(s) found." -ForegroundColor Yellow
        Write-Host "[SCAN] Processing deepest files first..." -ForegroundColor Yellow
    }

    # ------------------------ Phase 2: scanning ------------------------
    $allResults = New-Object System.Collections.Generic.List[object]

    foreach ($f in $candidates) {
        $p = $f.FullName
        if ($ShowProgress) { Write-Host "[SCAN] $p" -ForegroundColor DarkCyan }

        $hits = _Scan-TextSmart -Path $p -RegexPattern $regexPattern -MaxBytes $MaxFileSizeBytes -MaxChars $MaxLineChars -AllowFallback:$Auto
        if ($hits -and $hits.Count -gt 0) {
            # Determine newline once for the file, attach to each hit
            $encObj = _GetEncodingByWebName ($hits[0].Encoding)
            $nl = if ($encObj) { _Detect-Newline -Path $p -Encoding $encObj } else { 'Unknown' }

            foreach ($h in $hits) {
                # add Newline & (optional) progress line
                $h | Add-Member -NotePropertyName Newline -NotePropertyValue $nl
                if ($ShowProgress) { Write-Host "  [+] L$($h.LineNumber) ($($h.Encoding), $nl)  $($h.Snippet)" -ForegroundColor Green }
                [void]$allResults.Add($h)
            }
        }
    }

    # Always return an array (even when 0 or 1)
    $out = $allResults.ToArray()
    return @($out)
}

function Find-TreeContentByFile {
<#
.SYNOPSIS
Call Find-TreeContent and group results per file.

.DESCRIPTION
Invokes Find-TreeContent with the same parameters, then returns one object per file:
  - FileName : full path (group key, i.e., $g.Name)
  - Encoding : single encoding for the file (from first match)
  - Newline  : single newline style for the file
  - ITEMS    : array of { LineNumber, Snippet } sorted by line

.PARAMETER Path
Root directory to search (passed through).

.PARAMETER Include
Filename wildcards (passed through).

.PARAMETER Exclude
Wildcard(s) to skip (passed through).

.PARAMETER FindText
Content wildcard (passed through).

.PARAMETER Auto
Enable encoding auto-fallback (passed through).

.PARAMETER MaxFileSizeBytes
Per-file size cap for scanning (passed through).

.PARAMETER MaxLineChars
Snippet width (passed through).

.PARAMETER ShowProgress
Discovery/match feedback (passed through).

.EXAMPLE
Find-TreeContentByFile -Path . -Include "*.cs;*.ps1" -FindText "*TODO?*"

.EXAMPLE
Find-TreeContentByFile -Path C:\repo -FindText "[*]CRITICAL[*]" -Auto | Format-List
#>
    [CmdletBinding()]
    [Alias('ftc-byfile','deepfind-byfile')]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,

        [Parameter()]
        [string[]]$Include = @('*'),

        [Parameter()]
        [string[]]$Exclude,

        [Parameter(Mandatory=$true)]
        [string]$FindText,

        [switch]$Auto,

        [ValidateRange(1, 1GB)]
        [int]$MaxFileSizeBytes = 1048576,

        [ValidateRange(32, 4096)]
        [int]$MaxLineChars = 256,

        [switch]$ShowProgress
    )

    # Call the underlying function exactly with the same parameters
    $results = Find-TreeContent @PSBoundParameters
    if (-not $results) { return @() }

    $groups = $results | Group-Object -Property Path

    $out = foreach ($g in $groups) {
        $first = $g.Group | Select-Object -First 1
        [pscustomobject]@{
            FileName = $g.Name
            Encoding = $first.Encoding
            Newline  = $first.Newline
            Lines    = ($g.Group | Sort-Object LineNumber | Select-Object LineNumber, Snippet)
        }
    }

    return @($out)
}

function Resolve-ModulePath {
<#
.SYNOPSIS
Resolve the on-disk directory (ModuleBase) for a module by name, honoring prerelease rules.

.DESCRIPTION
Prefers the currently loaded module (active in the session), even if it’s prerelease.
If not loaded, searches installed modules on $env:PSModulePath. By default returns the
highest stable version. When -IncludePrerelease is set, prerelease versions are considered;
numeric version wins first, and for equal numeric versions, stable outranks prerelease.
PSModulePath order is used as a final tie-breaker.

.PARAMETER ModuleName
Module name to resolve (e.g., 'Pester').

.PARAMETER IncludePrerelease
Include prerelease module versions when selecting the "latest" installed module.
Note: A loaded module is always accepted regardless of prerelease status.

.PARAMETER All
Return all discovered ModuleBase paths in resolution order.

.PARAMETER ThrowIfNotFound
Throw if no matching module is found (neither loaded nor installed).

.EXAMPLE
Resolve-ModulePath -ModuleName Pester
# Loaded module wins; else highest installed stable by precedence.

.EXAMPLE
Resolve-ModulePath -ModuleName Pester -IncludePrerelease
# Considers prereleases: e.g., 4.0.0-beta outranks 3.9.0 stable; if 4.0.0 stable exists, it outranks 4.0.0-beta.

.EXAMPLE
Resolve-ModulePath -ModuleName Pester -All -IncludePrerelease
# Lists all candidate paths ordered by version (desc), stable before prerelease when equal, then PSModulePath precedence.

.NOTES
- Works on Windows PowerShell 5.1 and PowerShell 7+.
- Detects prerelease via module manifest PrivateData.PSData.Prerelease when available.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Name')]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleName,

        [switch] $IncludePrerelease,
        [switch] $All,
        [switch] $ThrowIfNotFound
    )

    # Helper: PSModulePath precedence index (lower is better).
    function __Get-PrecedenceIndex {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([Parameter(Mandatory)][string]$ModuleBase)
        $roots = ($env:PSModulePath -split [IO.Path]::PathSeparator)
        try { $baseFull = [IO.Path]::GetFullPath($ModuleBase) } catch { $baseFull = $ModuleBase }
        for ($i = 0; $i -lt $roots.Length; $i++) {
            $r = $roots[$i]; if ([string]::IsNullOrWhiteSpace($r)) { continue }
            try { $rFull = [IO.Path]::GetFullPath($r) } catch { $rFull = $r }
            if ($baseFull.StartsWith($rFull.TrimEnd('\','/'), [StringComparison]::InvariantCultureIgnoreCase)) { return $i }
        }
        return [int]::MaxValue
    }

    # Helper: determine prerelease label (if any) for a ModuleInfo.
    function __Get-PrereleaseLabel {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([Parameter(Mandatory)][System.Management.Automation.PSModuleInfo]$Module)
        # Try PrivateData first (present when built from a manifest with PSData.Prerelease).
        $pre = $null
        try {
            $pd = $Module.PrivateData
            if ($pd -and $pd.PSData -and $pd.PSData.Prerelease) { $pre = [string]$pd.PSData.Prerelease }
        } catch { }
        if (-not $pre) {
            # If manifest is available, read it defensively.
            try {
                if ($Module.Path -and $Module.Path.EndsWith('.psd1', [StringComparison]::OrdinalIgnoreCase)) {
                    $mf = Import-PowerShellDataFile -Path $Module.Path -ErrorAction Stop
                    if ($mf.PrivateData -and $mf.PrivateData.PSData -and $mf.PrivateData.PSData.Prerelease) {
                        $pre = [string]$mf.PrivateData.PSData.Prerelease
                    }
                }
            } catch { }
        }
        return $pre
    }

    # 1) Prefer loaded (active) module, regardless of prerelease.
    $loaded = Get-Module -Name $ModuleName -All | Sort-Object Version -Descending
    if ($loaded) {
        if ($All) { return ($loaded | Select-Object -ExpandProperty ModuleBase -Unique) }
        return $loaded[0].ModuleBase
    }

    # 2) Search installed modules.
    $cands = Get-Module -ListAvailable -Name $ModuleName -All
    if (-not $cands) {
        if ($ThrowIfNotFound) { throw "Module '$ModuleName' not found (neither loaded nor installed on PSModulePath)." }
        return
    }

    # Annotate with prerelease metadata for correct ordering/filtering.
    $annotated = foreach ($m in $cands) {
        $pre = __Get-PrereleaseLabel -Module $m
        [pscustomobject]@{
            Module     = $m
            ModuleBase = $m.ModuleBase
            Version    = $m.Version           # [System.Version]
            PreLabel   = $pre                  # string or $null
            IsPre      = -not [string]::IsNullOrWhiteSpace($pre)
            PrecIndex  = __Get-PrecedenceIndex $m.ModuleBase
        }
    }

    if (-not $IncludePrerelease) {
        $annotated = $annotated | Where-Object { -not $_.IsPre }
    }

    if (-not $annotated) {
        if ($ThrowIfNotFound) {
            $scope = $IncludePrerelease ? 'any (incl. prerelease)' : 'stable'
            throw "Module '$ModuleName' not found in $scope installations on PSModulePath."
        }
        return
    }

    # Sort: Version desc; for equal Version => stable before prerelease; then PSModulePath precedence.
    $ordered = $annotated | Sort-Object `
        @{ Expression = { $_.Version }; Descending = $true }, `
        @{ Expression = { $_.IsPre } }, `
        @{ Expression = { $_.PrecIndex } }

    if ($All) {
        return $ordered.ModuleBase | Select-Object -Unique
    }

    return $ordered[0].ModuleBase
}

# Resolve-ModulePath -ModuleName Eigenverft.Manifested.Drydock -IncludePrerelease
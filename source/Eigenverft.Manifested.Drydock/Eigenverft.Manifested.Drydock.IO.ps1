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

function Remove-FilesByPattern {
<#
.SYNOPSIS
    Delete files by filename wildcard(s) using explicit traversal; optionally remove empty subdirectories.

.DESCRIPTION
    Walks the directory tree manually (deep-first) without using -Recurse and matches file names against
    one or more Windows-style wildcard patterns (e.g. *.log, *.tmp). Continues on listing/deletion errors.
    After deletions, it can remove empty subdirectories (deepest-first). Emits only brief summary via Write-Host.

.PARAMETER Path
    Root directory where the deletion should begin.

.PARAMETER Pattern
    Filename wildcard(s). Accepts array or comma/semicolon list (e.g. "*.log;*.tmp,*.bak").

.PARAMETER RemoveEmptyDirs
    Policy to remove empty subdirectories after deleting files.
    Allowed: 'Yes' | 'No'. Default: 'Yes'.

.EXAMPLE
    Remove-FilesByPattern -Path "C:\Temp" -Pattern "*.log"

.EXAMPLE
    Remove-FilesByPattern -Path "/var/tmp" -Pattern "*.log;*.tmp" -RemoveEmptyDirs No

.EXAMPLE
    Remove-FilesByPattern -Path "D:\Build" -Pattern @("*.obj","*.pch","*.ipch")

.NOTES
    Requirements: Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
    Behavior: Idempotent; subsequent runs converge (no output objects, summary only).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,

        [Parameter(Mandatory=$true)]
        [string[]]$Pattern,

        [Parameter()]
        [ValidateSet('Yes','No')]
        [string]$RemoveEmptyDirs = 'Yes'
    )

    # [reviewer] Validate root path early and fail fast with concise message.
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "The specified path '$Path' does not exist or is not a directory."
    }

    # Inline helper: normalize pattern list; local scope; no pipeline output.
    function local:_Norm-List {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([string[]]$Patterns)

        if (-not $Patterns) { return @() }
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($p in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            foreach ($seg in ($p -split '[,;]')) {
                $t = $seg.Trim()
                if ($t.Length -gt 0) { [void]$list.Add($t) }
            }
        }
        if ($list.Count -eq 0) { return @() }
        $list.ToArray()
    }

    # Normalize patterns; keep parity with Find-FilesByPattern behavior.
    $pat = local:_Norm-List $Pattern
    if (-not $pat -or $pat.Count -eq 0) {
        throw "Pattern must not be empty."
    }

    # Prepare traversal using explicit stack; avoid -Recurse.
    $rootItem = $null
    try { $rootItem = Get-Item -LiteralPath $Path -ErrorAction Stop }
    catch { throw "Path '$Path' is not accessible: $_" }

    $stack      = New-Object System.Collections.Stack
    $stack.Push($rootItem)

    $candidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $allDirs    = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    $rootFull   = $rootItem.FullName

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()

        # [reviewer] Track directories for later empty-dir cleanup; skip the root itself.
        if ($dir.FullName -ne $rootFull) { [void]$allDirs.Add($dir) }

        # Discover subdirectories; continue on errors.
        $subs = @()
        try { $subs = Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction Stop }
        catch { Write-Warning "Cannot list directories in '$($dir.FullName)': $_" }
        foreach ($sd in $subs) { $stack.Push($sd) }

        # List files; continue on errors.
        $files = @()
        try { $files = Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction Stop }
        catch { Write-Warning "Cannot list files in '$($dir.FullName)': $_" }

        # Match filenames against wildcard set; first-hit wins.
        foreach ($f in $files) {
            foreach ($p in $pat) {
                if ($f.Name -like $p) { [void]$candidates.Add($f); break }
            }
        }
    }

    # Delete matched files; keep going on individual failures.
    $deleted = 0
    foreach ($fi in $candidates) {
        try {
            if (Test-Path -LiteralPath $fi.FullName -PathType Leaf) {
                Remove-Item -LiteralPath $fi.FullName -Force -ErrorAction Stop
                $deleted += 1
            }
        }
        catch {
            Write-Warning "Failed to delete '$($fi.FullName)': $_"
        }
    }

    # Optionally remove empty subdirectories (deepest-first), never the root.
    $removedDirs = 0
    if ($RemoveEmptyDirs -eq 'Yes') {
        $sorted = $allDirs | Sort-Object {
            ($_.FullName.Split([System.IO.Path]::DirectorySeparatorChar)).Count
        } -Descending

        foreach ($d in $sorted) {
            try {
                $items = Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction Stop
                if (-not $items -or $items.Count -eq 0) {
                    Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop
                    $removedDirs += 1
                }
            }
            catch {
                # [reviewer] Ignore cleanup failures; keep traversal robust/cross-platform.
            }
        }
    }

    # Minimal, consistent logging per policy.
    Write-Host ("Deleted files: {0}" -f $deleted)
    if ($RemoveEmptyDirs -eq 'Yes') {
        Write-Host ("Removed empty directories: {0}" -f $removedDirs)
    }
}

function New-Directory {
<#
.SYNOPSIS
    Combine flexible path inputs and ensure the directory exists.

.DESCRIPTION
    Accepts heterogeneous inputs in -Paths (strings, nested arrays, DirectoryInfo/FileInfo,
    hashtables/objects with Path-like members), flattens them, coerces to strings, and combines
    them into a directory path using .NET APIs. If any later segment is rooted (drive/UNC or / on Unix),
    earlier segments are ignored (same as System.IO.Path.Combine semantics). The function creates
    the directory if missing and returns the absolute directory path. Idempotent and cross-platform.

.PARAMETER Paths
    One or more items representing path segments. Supports:
      - String(s) or nested arrays of strings
      - DirectoryInfo/FileInfo (uses .FullName)
      - PSCustomObject/Hashtable with one of: FullName, DirectoryName, Path (case-insensitive)
      - Mixed/nested structures (e.g., @('out', $obj.Subitem, $arrOfSegments))

.EXAMPLE
    $outDir = New-Directory -Paths @('C:\Logs','App','2025')
    # Ensures C:\Logs\App\2025 exists; returns absolute path.

.EXAMPLE
    $outDir = New-Directory -Paths @('./build','reports')
    # Cross-platform relative segments; returns absolute path.

.EXAMPLE
    $outDir = New-Directory -Paths @('root', $project.Directory, @('bin','release'))
    # Accepts nested arrays and DirectoryInfo-like objects.

.EXAMPLE
    $outDir = New-Directory -Paths @('prefix', @{ Path = '/var/tmp' }, 'child')
    # Because '/var/tmp' is rooted, 'prefix' is ignored (Path.Combine semantics).

.NOTES
    Compatibility: Windows PowerShell 5/5.1 and PowerShell 7+ (Windows/macOS/Linux).
    Logging: Only announces creation via Write-Host when the directory is newly created.
#>
    [CmdletBinding()]
    param(
        # Accept anything so we can robustly flatten/normalize.
        [Parameter(Mandatory=$true)]
        [object[]]$Paths
    )

    # Helper: extract a path-like string from a single input element.
    function local:_Select-PathLikeValue {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([object]$Item)

        if ($null -eq $Item) { return $null }

        # Strings: trim, drop empty.
        if ($Item -is [string]) {
            $t = $Item.Trim()
            if ($t.Length -gt 0) { return $t } else { return $null }
        }

        # DirectoryInfo/FileInfo and other FileSystemInfo derivatives.
        if ($Item -is [System.IO.FileSystemInfo]) {
            return $Item.FullName
        }

        # Hashtable: prefer Path-like keys.
        if ($Item -is [System.Collections.IDictionary]) {
            foreach ($k in @('FullName','DirectoryName','Path')) {
                foreach ($key in $Item.Keys) {
                    if ($key -is [string] -and $key.Equals($k, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $v = $Item[$key]
                        if ($null -ne $v) { return ($v.ToString().Trim()) }
                    }
                }
            }
            # Fallback: if a single non-null value, use it.
            if ($Item.Values -and $Item.Values.Count -eq 1 -and $null -ne $Item.Values[0]) {
                return ($Item.Values[0].ToString().Trim())
            }
            return $null
        }

        # PSCustomObject / other objects: look for common members.
        $type = $Item.GetType()
        $members = @('FullName','DirectoryName','Path')
        foreach ($m in $members) {
            $prop = $type.GetProperty($m)
            if ($null -ne $prop) {
                $val = $prop.GetValue($Item, $null)
                if ($null -ne $val) { return ($val.ToString().Trim()) }
            }
        }

        # Fallback: ToString()
        $s = $Item.ToString()
        if ($null -ne $s) {
            $t = $s.Trim()
            if ($t.Length -gt 0) { return $t }
        }
        return $null
    }

    # Helper: recursively flatten arbitrary/nested inputs into a list of non-empty strings.
    function local:_Flatten-PathInputs {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([object[]]$Items)

        $acc = New-Object System.Collections.Generic.List[string]
        if (-not $Items) { return @() }

        foreach ($it in $Items) {
            if ($null -eq $it) { continue }

            # Do not treat string as IEnumerable of chars.
            if ($it -is [string]) {
                $val = local:_Select-PathLikeValue $it
                if ($val) { [void]$acc.Add($val) }
                continue
            }

            # If IEnumerable (arrays, lists), flatten recursively.
            if ($it -is [System.Collections.IEnumerable]) {
                # Avoid iterating dictionaries as key/value pairs; handle them via selector.
                if ($it -is [System.Collections.IDictionary]) {
                    $val = local:_Select-PathLikeValue $it
                    if ($val) { [void]$acc.Add($val) }
                }
                else {
                    $nested = @()
                    foreach ($n in $it) { $nested += ,$n }
                    $flatNested = local:_Flatten-PathInputs $nested
                    foreach ($s in $flatNested) { [void]$acc.Add($s) }
                }
                continue
            }

            # Single object.
            $v = local:_Select-PathLikeValue $it
            if ($v) { [void]$acc.Add($v) }
        }

        if ($acc.Count -eq 0) { return @() }
        return $acc.ToArray()
    }

    # Normalize all incoming segments.
    $segments = local:_Flatten-PathInputs $Paths
    if (-not $segments -or $segments.Count -eq 0) {
        throw "Paths must contain at least one resolvable segment."
    }

    # Apply explicit rooted-segment policy (documented): last rooted wins.
    # This mirrors System.IO.Path.Combine behavior but we make it clear and predictable.
    $lastRooted = -1
    for ($i = 0; $i -lt $segments.Count; $i++) {
        if ([System.IO.Path]::IsPathRooted($segments[$i])) { $lastRooted = $i }
    }
    if ($lastRooted -ge 0) {
        $segments = $segments[$lastRooted..($segments.Count - 1)]
    }

    # Combine using .NET; then resolve to absolute path for stable return.
    $combined = [System.IO.Path]::Combine($segments)
    if ([string]::IsNullOrWhiteSpace($combined)) {
        throw "The combined path is empty after normalization."
    }

    $fullPath = [System.IO.Path]::GetFullPath($combined)

    # Sanity checks: if a file already exists at that full path, fail with a clear message.
    if ([System.IO.File]::Exists($fullPath)) {
        throw ("A file already exists at '{0}'; cannot create a directory at this path." -f $fullPath)
    }

    # Idempotent creation; announce only on first creation.
    $existed = [System.IO.Directory]::Exists($fullPath)
    try {
        [System.IO.Directory]::CreateDirectory($fullPath) | Out-Null
    }
    catch {
        throw ("Failed to create or access directory '{0}': {1}" -f $fullPath, $_)
    }

    if (-not $existed) {
        Write-Host ("Created directory: {0}" -f $fullPath)
    }

    # Return absolute path as string.
    $fullPath
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
Prefers the currently loaded module (active in the session), regardless of prerelease.
If not loaded, searches installed modules on $env:PSModulePath. By default returns the
highest stable version. When -VersionScope IncludePrerelease is chosen, prerelease versions
are considered; numeric version wins first, and for equal numeric versions, stable outranks
prerelease. PSModulePath order is used as a final tie-breaker.

.PARAMETER ModuleName
Module name to resolve (e.g., 'Pester').

.PARAMETER VersionScope
'Stable' or 'IncludePrerelease'. Default: 'Stable'.
Controls whether installed prerelease versions are considered. A loaded module is always
accepted regardless of prerelease status.

.PARAMETER All
Return all discovered ModuleBase paths in resolution order (loaded first, then installed).

.PARAMETER ThrowIfNotFound
Throw if no matching module is found (neither loaded nor installed).

.EXAMPLE
Resolve-ModulePath -ModuleName Pester
# Loaded module wins; else highest installed stable by precedence.

.EXAMPLE
Resolve-ModulePath -ModuleName Eigenverft.Manifested.Drydock -VersionScope IncludePrerelease
# Considers prereleases: e.g., 4.0.0-beta outranks 3.9.0 stable; if 4.0.0 stable exists, it outranks 4.0.0-beta.

.EXAMPLE
Resolve-ModulePath -ModuleName Pester -All -VersionScope IncludePrerelease
# Lists all candidate paths ordered by version (desc), stable before prerelease when equal, then PSModulePath precedence.

.NOTES
- Compatible with Windows PowerShell 5.1 and PowerShell 7+ on Windows/macOS/Linux.
- Detects prerelease via PrivateData.PSData.Prerelease in the manifest when available.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Name')]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleName,

        [ValidateSet('Stable','IncludePrerelease')]
        [string] $VersionScope = 'Stable',

        [switch] $All,
        [switch] $ThrowIfNotFound
    )

    # Reviewer: Avoid global function leakage; use local scriptblocks for helpers.
    $roots = ($env:PSModulePath -split [IO.Path]::PathSeparator)

    $GetPrecedenceIndex = {
        param([Parameter(Mandatory = $true)][string]$ModuleBase)
        # Reviewer: Normalize inputs; tolerate odd entries and IO exceptions.
        $baseFull = $ModuleBase
        try { $baseFull = [IO.Path]::GetFullPath($ModuleBase) } catch { }
        for ($i = 0; $i -lt $roots.Length; $i++) {
            $r = $roots[$i]
            if ([string]::IsNullOrWhiteSpace($r)) { continue }
            $rFull = $r
            try { $rFull = [IO.Path]::GetFullPath($r) } catch { }
            $trimmed = $rFull.TrimEnd('\','/')
            if ($baseFull.StartsWith($trimmed, [System.StringComparison]::InvariantCultureIgnoreCase)) { return $i }
        }
        return [int]::MaxValue
    }

    $GetPrereleaseLabel = {
        param([Parameter(Mandatory = $true)][System.Management.Automation.PSModuleInfo]$Module)
        # Reviewer: Prefer manifest PrivateData.PSData.Prerelease if exposed, else try read the .psd1.
        $pre = $null
        try {
            if ($Module.PrivateData -and $Module.PrivateData.PSData -and $Module.PrivateData.PSData.Prerelease) {
                $pre = [string]$Module.PrivateData.PSData.Prerelease
            }
        } catch { }
        if (-not $pre) {
            # Try explicit manifest path first if known, else fallback to <Name>.psd1 next to ModuleBase.
            $manifestPath = $null
            try {
                if ($Module.Path -and $Module.Path.EndsWith('.psd1', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $manifestPath = $Module.Path
                } else {
                    $candidate = Join-Path -Path $Module.ModuleBase -ChildPath ($Module.Name + '.psd1')
                    if (Test-Path -LiteralPath $candidate) { $manifestPath = $candidate }
                }
                if ($manifestPath) {
                    $mf = Import-PowerShellDataFile -Path $manifestPath -ErrorAction Stop
                    if ($mf.PrivateData -and $mf.PrivateData.PSData -and $mf.PrivateData.PSData.Prerelease) {
                        $pre = [string]$mf.PrivateData.PSData.Prerelease
                    }
                }
            } catch { }
        }
        return $pre
    }

    $includePre = ($VersionScope -eq 'IncludePrerelease')

    # 1) Prefer loaded (active) modules, regardless of prerelease.
    $loaded = @(Get-Module -Name $ModuleName -All | Sort-Object Version -Descending)

    # 2) Discover installed candidates.
    $installed = @(Get-Module -ListAvailable -Name $ModuleName -All)

    if (-not $loaded -and -not $installed) {
        if ($ThrowIfNotFound) {
            throw "Module '$ModuleName' not found (neither loaded nor installed on PSModulePath)."
        }
        return
    }

    # Build annotated table for installed modules to sort correctly.
    $annotatedInstalled = @()
    foreach ($m in $installed) {
        $pre = & $GetPrereleaseLabel -Module $m
        $isPre = (-not [string]::IsNullOrWhiteSpace($pre))
        if (-not $includePre -and $isPre) { continue } # Reviewer: filter prerelease unless explicitly requested.
        $precIndex = & $GetPrecedenceIndex -ModuleBase $m.ModuleBase
        $annotatedInstalled += [pscustomobject]@{
            Module     = $m
            ModuleBase = $m.ModuleBase
            Version    = $m.Version
            IsPre      = $isPre
            PrecIndex  = $precIndex
        }
    }

    # Sort installed: Version desc; stable before prerelease; PSModulePath precedence asc.
    $orderedInstalled = @()
    if ($annotatedInstalled.Count -gt 0) {
        $orderedInstalled = $annotatedInstalled | Sort-Object `
            @{ Expression = { $_.Version }; Descending = $true }, `
            @{ Expression = { $_.IsPre } }, `
            @{ Expression = { $_.PrecIndex } }
    }

    if ($All) {
        # Reviewer: Return loaded first (in session order by version), then installed (excluding duplicates).
        $result = New-Object System.Collections.Generic.List[string]
        foreach ($lm in $loaded) {
            if ($lm.ModuleBase -and -not $result.Contains($lm.ModuleBase, [System.StringComparer]::OrdinalIgnoreCase)) {
                [void]$result.Add($lm.ModuleBase)
            }
        }
        foreach ($row in $orderedInstalled) {
            $mb = $row.ModuleBase
            if ($mb -and -not $result.Contains($mb, [System.StringComparer]::OrdinalIgnoreCase)) {
                [void]$result.Add($mb)
            }
        }
        if ($result.Count -eq 0) {
            if ($ThrowIfNotFound) {
                throw "Module '$ModuleName' not found in the requested scope."
            }
            return
        }
        # Reviewer: Output in final resolution order, no extra noise.
        return $result.ToArray()
    }

    # Single best resolution: loaded wins, else first installed by ordering.
    if ($loaded.Count -gt 0) {
        return $loaded[0].ModuleBase
    }

    if ($orderedInstalled.Count -gt 0) {
        return $orderedInstalled[0].ModuleBase
    }

    if ($ThrowIfNotFound) {
        $scope = 'stable'
        if ($includePre) {
            $scope = 'any (including prerelease)'
        }
        throw "Module '$ModuleName' not found in $scope installations on PSModulePath."
    }
}



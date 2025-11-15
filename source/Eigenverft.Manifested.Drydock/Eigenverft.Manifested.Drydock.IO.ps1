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

function Get-Path {
<#
.SYNOPSIS
  Combine flexible inputs in -Paths into a single path string (no filesystem I/O).

.DESCRIPTION
  Accepts heterogeneous inputs (strings, nested arrays, DirectoryInfo/FileInfo, and
  hashtables/objects with path-like members). Flattens & validates, applies “last rooted wins”,
  then combines segments iteratively using System.IO.Path. Returns the combined path string
  with OS-appropriate separators. Does not resolve to absolute, does not touch the filesystem.

.PARAMETER Paths
  One or more path-like items:
    - String(s) or nested arrays
    - DirectoryInfo/FileInfo (.FullName)
    - Hashtable/PSCustomObject with FullName / DirectoryName / Path (case-insensitive)

.EXAMPLE
  Get-Path -Paths @("ddd","build")
  # Returns: ddd\build   (on Windows)   or   ddd/build   (on Unix)

.EXAMPLE
  Get-Path -Paths @("C:\repo","artifacts","build\output\file.txt")
  # Returns: C:\repo\artifacts\build\output\file.txt

.EXAMPLE
  # Mixed types are fine:
  $d = [IO.DirectoryInfo]"C:\repo"
  Get-Path -Paths @($d, @{Path='artifacts'}, 'build','output')

.NOTES
  PowerShell 5/5.1 and 7+. To convert the result to an absolute path later (without touching the FS):
    [IO.Path]::GetFullPath( (Get-Path -Paths $Paths) )
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [object[]]$Paths
    )

    # --- Helpers (kept local for portability) ---------------------------------------------------

    function _Select-PathLikeValue {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([object]$Item)

        if ($null -eq $Item) { return $null }

        if ($Item -is [string]) {
            $t = $Item.Trim()
            if ($t.Length -gt 0) { return $t } else { return $null }
        }

        if ($Item -is [System.IO.FileSystemInfo]) {
            return $Item.FullName
        }

        if ($Item -is [System.Collections.IDictionary]) {
            foreach ($k in @('FullName','DirectoryName','Path')) {
                foreach ($key in $Item.Keys) {
                    if ($key -is [string] -and $key.Equals($k,[StringComparison]::OrdinalIgnoreCase)) {
                        $v = $Item[$key]; if ($null -ne $v) { return ($v.ToString().Trim()) }
                    }
                }
            }
            $vals = @($Item.Values)
            if ($vals.Count -eq 1 -and $null -ne $vals[0]) { return ($vals[0].ToString().Trim()) }
            return $null
        }

        $type = $Item.GetType()
        foreach ($m in @('FullName','DirectoryName','Path')) {
            $prop = $type.GetProperty($m)
            if ($null -ne $prop) {
                $val = $prop.GetValue($Item, $null)
                if ($null -ne $val) { return ($val.ToString().Trim()) }
            }
        }

        $s = $Item.ToString()
        if ($null -ne $s) {
            $t = $s.Trim()
            if ($t.Length -gt 0) { return $t }
        }
        return $null
    }

    function _Flatten-PathInputs {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([object[]]$Items)

        $acc = New-Object System.Collections.Generic.List[string]
        if (-not $Items) { return @() }

        foreach ($it in $Items) {
            if ($null -eq $it) { continue }

            if ($it -is [string]) {
                $val = _Select-PathLikeValue $it
                if ($val) { [void]$acc.Add($val) }
                continue
            }

            if ($it -is [System.Collections.IEnumerable]) {
                if ($it -is [System.Collections.IDictionary]) {
                    $val = _Select-PathLikeValue $it
                    if ($val) { [void]$acc.Add($val) }
                }
                else {
                    $nested = @()
                    foreach ($n in $it) { $nested += ,$n }
                    $flatNested = _Flatten-PathInputs $nested
                    foreach ($s in $flatNested) { [void]$acc.Add($s) }
                }
                continue
            }

            $v = _Select-PathLikeValue $it
            if ($v) { [void]$acc.Add($v) }
        }

        if ($acc.Count -eq 0) { return @() }
        return $acc.ToArray()
    }

    function _Validate-Segments {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([string[]]$Segments)

        $bad = [System.IO.Path]::GetInvalidPathChars()
        foreach ($seg in $Segments) {
            if ([string]::IsNullOrWhiteSpace($seg)) { throw "Encountered an empty path segment." }
            foreach ($ch in $bad) {
                if ($seg.IndexOf($ch) -ge 0) {
                    throw ("Invalid character '{0}' found in segment '{1}'." -f $ch, $seg)
                }
            }
        }
    }

    # --- Normalize & Combine --------------------------------------------------------------------

    $segments = _Flatten-PathInputs $Paths
    if (-not $segments -or $segments.Count -eq 0) {
        throw "Paths must contain at least one resolvable segment."
    }

    _Validate-Segments $segments

    # Last rooted wins: if a later segment is rooted, drop everything before it.
    $lastRooted = -1
    for ($i = 0; $i -lt $segments.Count; $i++) {
        if ([System.IO.Path]::IsPathRooted($segments[$i])) { $lastRooted = $i }
    }
    if ($lastRooted -ge 0) {
        $segments = $segments[$lastRooted..($segments.Count - 1)]
    }

    # Iteratively combine (avoids Combine(string[]) quirkiness across runtimes).
    $current = $segments[0]
    for ($i = 1; $i -lt $segments.Count; $i++) {
        $current = [System.IO.Path]::Combine($current, $segments[$i])
    }

    if ([string]::IsNullOrWhiteSpace($current)) {
        throw "The combined path is empty after normalization."
    }

    # Return the combined (possibly relative) path — no resolution to absolute.
    return $current
}

function New-Directory {
<#
.SYNOPSIS
    Combine flexible path inputs and ensure the directory exists.

.DESCRIPTION
    Accepts heterogeneous inputs in -Paths (strings, nested arrays, DirectoryInfo/FileInfo,
    hashtables/objects with path-like members), flattens and sanitizes them, and then
    iteratively combines segments (cross-version safe). Creates the directory if missing
    and returns the absolute directory path. Idempotent and cross-platform.

.PARAMETER Paths
    One or more items representing path segments. Supports:
      - String(s) or nested arrays
      - DirectoryInfo/FileInfo (uses .FullName)
      - PSCustomObject/Hashtable with one of: FullName, DirectoryName, Path

.EXAMPLE
    $ne = New-Directory -Paths @("$gitTopLevelDirectory","$artifactsFolderName",$deploymentInfo.Branch.PathSegmentsSanitized)
    # Produces: <top>/artifacts/feature/stabilize (OS-specific separators), creates if missing.

.NOTES
    Compatibility: Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
    Logging: Only announces creation via Write-Host when newly created.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Paths
    )

    # Helper: extract a path-like string from a single element.
    function _Select-PathLikeValue {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([object] $Item)

        if ($null -eq $Item) { return $null }

        if ($Item -is [string]) {
            $t = $Item.Trim()
            if ($t.Length -gt 0) { return $t } else { return $null }
        }

        if ($Item -is [System.IO.FileSystemInfo]) {
            return $Item.FullName
        }

        if ($Item -is [System.Collections.IDictionary]) {
            foreach ($k in @('FullName','DirectoryName','Path')) {
                foreach ($key in $Item.Keys) {
                    if ($key -is [string] -and $key.Equals($k, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $v = $Item[$key]
                        if ($null -ne $v) { return ($v.ToString().Trim()) }
                    }
                }
            }
            $vals = @($Item.Values)
            if ($vals.Count -eq 1 -and $null -ne $vals[0]) { return ($vals[0].ToString().Trim()) }
            return $null
        }

        $type = $Item.GetType()
        foreach ($m in @('FullName','DirectoryName','Path')) {
            $prop = $type.GetProperty($m)
            if ($null -ne $prop) {
                $val = $prop.GetValue($Item, $null)
                if ($null -ne $val) { return ($val.ToString().Trim()) }
            }
        }

        $s = $Item.ToString()
        if ($null -ne $s) {
            $t = $s.Trim()
            if ($t.Length -gt 0) { return $t }
        }
        return $null
    }

    # Helper: recursively flatten arbitrary/nested inputs into a list of non-empty strings.
    function _Flatten-PathInputs {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([object[]] $Items)

        $acc = New-Object System.Collections.Generic.List[string]
        if (-not $Items) { return @() }

        foreach ($it in $Items) {
            if ($null -eq $it) { continue }

            if ($it -is [string]) {
                $val = _Select-PathLikeValue $it
                if ($val) { [void] $acc.Add($val) }
                continue
            }

            if ($it -is [System.Collections.IEnumerable]) {
                if ($it -is [System.Collections.IDictionary]) {
                    $val = _Select-PathLikeValue $it
                    if ($val) { [void] $acc.Add($val) }
                }
                else {
                    $nested = @()
                    foreach ($n in $it) { $nested += ,$n }
                    $flatNested = _Flatten-PathInputs $nested
                    foreach ($s in $flatNested) { [void] $acc.Add($s) }
                }
                continue
            }

            $v = _Select-PathLikeValue $it
            if ($v) { [void] $acc.Add($v) }
        }

        if ($acc.Count -eq 0) { return @() }
        return $acc.ToArray()
    }

    # Helper: basic segment sanity (invalid path chars).
    function _Validate-Segments {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([string[]] $Segments)

        $bad = [System.IO.Path]::GetInvalidPathChars()
        foreach ($seg in $Segments) {
            if ([string]::IsNullOrWhiteSpace($seg)) { throw "Encountered an empty path segment." }
            foreach ($ch in $bad) {
                if ($seg.IndexOf($ch) -ge 0) {
                    throw ("Invalid character '{0}' found in segment '{1}'." -f $ch, $seg)
                }
            }
        }
    }

    # Normalize and force an array (prevents scalar-string quirks).
    [string[]] $segments = @(_Flatten-PathInputs -Items $Paths)
    if (-not $segments -or $segments.Length -eq 0) {
        throw "Paths must contain at least one resolvable segment."
    }

    _Validate-Segments -Segments $segments

    # Rooted policy: last rooted wins (mirrors typical Combine semantics).
    $lastRooted = -1
    for ($i = 0; $i -lt $segments.Length; $i++) {
        if ([System.IO.Path]::IsPathRooted($segments[$i])) { $lastRooted = $i }
    }
    if ($lastRooted -ge 0) {
        # This slice stays an array; safe for single-element ranges as well.
        $segments = $segments[$lastRooted..($segments.Length - 1)]
    }

    # Cross-version safe: combine without indexing (avoids $segments[0] pitfalls completely).
    $current = $null
    foreach ($seg in $segments) {
        if ($null -eq $current) {
            $current = $seg
            continue
        }
        # External reviewer note: Combine honors rooted child by discarding the left side.
        $current = [System.IO.Path]::Combine($current, $seg)
    }
    $combined = $current

    if ([string]::IsNullOrWhiteSpace($combined)) {
        throw "The combined path is empty after normalization."
    }

    $fullPath = [System.IO.Path]::GetFullPath($combined)

    # Sanity: fail if a file exists at the target.
    if ([System.IO.File]::Exists($fullPath)) {
        throw ("A file already exists at '{0}'; cannot create a directory at this path." -f $fullPath)
    }

    # Idempotent creation; announce only if newly created.
    $existed = [System.IO.Directory]::Exists($fullPath)
    try { [System.IO.Directory]::CreateDirectory($fullPath) | Out-Null }
    catch { throw ("Failed to create or access directory '{0}': {1}" -f $fullPath, $_) }

    if (-not $existed) {
        Write-Host ("Created directory: {0}" -f $fullPath)
    }

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

function Copy-FilesRecursively {
    <#
    .SYNOPSIS
        Recursively copies files from a source directory to a destination directory.

    .DESCRIPTION
        This function copies files from the specified source directory to the destination directory.
        The file filter (default "*") limits the files that are copied. The -CopyEmptyDirs parameter
        controls directory creation:
         - If $true (default), the complete source directory tree is recreated.
         - If $false, only directories that contain at least one file matching the filter (in that
           directory or any subdirectory) will be created.
        The -ForceOverwrite parameter (default $true) determines whether existing files are overwritten.
        The -CleanDestination parameter controls removal of extra items at the destination that do not
        exist in the source.

    .PARAMETER SourceDirectory
        The directory from which files and directories are copied.

    .PARAMETER DestinationDirectory
        The target directory to which files and directories will be copied.

    .PARAMETER Filter
        A wildcard filter that limits which files are copied. Defaults to "*".

    .PARAMETER CopyEmptyDirs
        If $true, the entire directory structure from the source is recreated in the destination.
        If $false, only directories that will contain at least one file matching the filter are created.
        Defaults to $true.

    .PARAMETER ForceOverwrite
        A Boolean value that indicates whether existing files should be overwritten.
        Defaults to $true.

    .PARAMETER CleanDestination
        Controls removal of items that exist in the destination but not in the source. The source
        is never modified; only extra items in the destination are deleted. Items that exist in
        the source are always preserved in the destination.

        Allowed values:
          - "None":
              No cleaning (default). The destination may accumulate extra files or directories
              over time; this function will only add or overwrite files, never remove anything.

          - "RootFiles":
              Removes extra files located directly in the destination root directory. Matching is
              done by file name only and respects -Filter. Subdirectories and any files inside
              them are not touched, even if they do not exist in the source.

          - "FilesRecursive":
              Removes extra files in the destination root and all subdirectories. Matching is
              done by full relative path and respects -Filter. Only files are deleted; directory
              structures are left in place, even if the directory itself does not exist in the
              source.

          - "MirrorTree":
              Mirror-style cleanup. First, removes all files under the destination that do not
              have a corresponding file in the source (ignores -Filter). Then, removes any
              directories under the destination that do not exist in the source (deepest-first),
              effectively pruning entire directory trees that are not present in the source.
              The destination root folder itself is never removed.

        Note:
          - "RootFiles" and "FilesRecursive" only remove files that match -Filter.
          - "MirrorTree" ignores -Filter and can delete entire directory subtrees that are not
            present in the source, making the destination closely mirror the source structure.

    .EXAMPLE
        # Copy all *.txt files, create only directories that hold matching files, and clean extra files in the destination root.
        Copy-FilesRecursively -SourceDirectory "C:\Source" -DestinationDirectory "C:\Dest" -Filter "*.txt" -CopyEmptyDirs $false -ForceOverwrite $true -CleanDestination "RootFiles"

    .EXAMPLE
        # Copy all files and clean extra files across the entire destination tree (files only).
        Copy-FilesRecursively -SourceDirectory "C:\Source" -DestinationDirectory "C:\Dest" -CleanDestination "FilesRecursive"

    .EXAMPLE
        # Mirror-style cleanup: remove all extra files and directories in destination.
        Copy-FilesRecursively -SourceDirectory "C:\Source" -DestinationDirectory "C:\Dest" -CleanDestination "MirrorTree"

    .EXAMPLE
        # Copy all files, recreate the full directory tree without cleaning extra files.
        Copy-FilesRecursively -SourceDirectory "C:\Source" -DestinationDirectory "C:\Dest"
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,

        [Parameter()]
        [string]$Filter = "*",

        [Parameter()]
        [bool]$CopyEmptyDirs = $true,

        [Parameter()]
        [bool]$ForceOverwrite = $true,

        [Parameter()]
        [ValidateSet('None','RootFiles','FilesRecursive','MirrorTree')]
        [string]$CleanDestination = 'None'
    )

    function _Write-StandardMessage {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        [CmdletBinding()]
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

    function _Format-PathForDisplay {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        <#
        .SYNOPSIS
            Formats a path for log output by shortening long segments.

        .DESCRIPTION
            Splits the path into segments and shortens only those segments whose length
            exceeds the specified limit. The following segments are never shortened:
            - The drive segment (e.g. C:)
            - Any segment that contains at least one numeric character (e.g. 1.0.0, v2)

        .PARAMETER Path
            The full path to format for display.

        .PARAMETER MaxSegmentLength
            Maximum length of a non-numeric segment before it is shortened. Default is 24.

        .EXAMPLE
            _Format-PathForDisplay -Path "C:\dev\tools\MyVeryLongFolderName\9.0.11" -MaxSegmentLength 16
            # Returns: C:\dev\tools\MyVeryLongFol...\9.0.11
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Path,
            [int]$MaxSegmentLength = 24
        )

        if ([string]::IsNullOrWhiteSpace($Path)) {
            return $Path
        }

        # Normalize separators for display.
        $normalized = $Path.Replace('/', '\')

        # Split into segments (keep empties so UNC prefixes are preserved).
        $segments = $normalized.Split('\')

        for ($i = 0; $i -lt $segments.Count; $i++) {
            $seg = $segments[$i]

            if ([string]::IsNullOrEmpty($seg)) {
                continue
            }

            # Keep drive segment like "C:" unchanged.
            if ($i -eq 0 -and $seg -match '^[A-Za-z]:$') {
                continue
            }

            # If the segment contains any digit (likely version or numbered dir), do not shorten.
            if ($seg -match '\d') {
                continue
            }

            # Shorten only long, non-numeric segments.
            if ($seg.Length -gt $MaxSegmentLength -and $MaxSegmentLength -gt 3) {
                $segments[$i] = $seg.Substring(0, $MaxSegmentLength - 3) + '...'
            }
        }

        return ($segments -join '\')
    }

    # Title (first log, no tag)
    _Write-StandardMessage -Message "--- Copy-FilesRecursively ---" -Level 'INF'

    # Counters for summary statistics
    [int]$filesCopied  = 0
    [int]$filesSkipped = 0
    [int]$filesRemoved = 0
    [int]$dirsCreated  = 0
    [int]$dirsRemoved  = 0

    # Validate that the source directory exists.
    if (-not (Test-Path -Path $SourceDirectory -PathType Container)) {
        _Write-StandardMessage -Message "[ERROR] Source dir '$SourceDirectory' not found." -Level 'ERR'
        return
    }

    # If CopyEmptyDirs is false, check if there are any files matching the filter.
    if (-not $CopyEmptyDirs) {
        $matchingFiles = Get-ChildItem -Path $SourceDirectory -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue
        if (-not $matchingFiles -or $matchingFiles.Count -eq 0) {
            _Write-StandardMessage -Message "[SKIP] No files match filter; CopyEmptyDirs = false." -Level 'INF'
            return
        }
    }

    # Create the destination directory if it doesn't exist.
    if (-not (Test-Path -Path $DestinationDirectory -PathType Container)) {
        $destDirDisplay = _Format-PathForDisplay -Path $DestinationDirectory -MaxSegmentLength 6
        _Write-StandardMessage -Message "[CREATE] Dest dir '$destDirDisplay' missing; creating." -Level 'INF'
        New-Item -ItemType Directory -Path $DestinationDirectory | Out-Null
        $dirsCreated++
    }

    # Set full paths for easier manipulation.
    $sourceFullPath = (Get-Item $SourceDirectory).FullName.TrimEnd('\')
    $destFullPath   = (Get-Item $DestinationDirectory).FullName.TrimEnd('\')

    # Compact from/to info (INF)
    $srcDisplay = _Format-PathForDisplay -Path $sourceFullPath -MaxSegmentLength 6
    $dstDisplay = _Format-PathForDisplay -Path $destFullPath   -MaxSegmentLength 6

    _Write-StandardMessage -Message "[STATUS] From: $srcDisplay" -Level 'INF'
    _Write-StandardMessage -Message "[STATUS]   To: $dstDisplay" -Level 'INF'

    # Clean destination according to requested scope.
    switch ($CleanDestination) {
        'RootFiles' {
            _Write-StandardMessage -Message "[STATUS] Clean: root files only." -Level 'DBG'
            $destRootFiles = Get-ChildItem -Path $DestinationDirectory -File -Filter $Filter
            foreach ($destFile in $destRootFiles) {
                $sourceFilePath = Join-Path -Path $SourceDirectory -ChildPath $destFile.Name
                if (-not (Test-Path -Path $sourceFilePath -PathType Leaf)) {
                    _Write-StandardMessage -Message "[REMOVE] File: $($destFile.FullName)" -Level 'DBG'
                    Remove-Item -Path $destFile.FullName -Force
                    $filesRemoved++
                }
            }
        }
        'FilesRecursive' {
            _Write-StandardMessage -Message "[STATUS] Clean: files recursive." -Level 'DBG'
            $destFiles = Get-ChildItem -Path $destFullPath -Recurse -File -Filter $Filter
            foreach ($destFile in $destFiles) {
                $relative = $destFile.FullName.Substring($destFullPath.Length).TrimStart('\')
                $sourceFilePath = Join-Path -Path $sourceFullPath -ChildPath $relative
                if (-not (Test-Path -Path $sourceFilePath -PathType Leaf)) {
                    _Write-StandardMessage -Message "[REMOVE] File: $($destFile.FullName)" -Level 'DBG'
                    Remove-Item -Path $destFile.FullName -Force
                    $filesRemoved++
                }
            }
        }
        'MirrorTree' {
            _Write-StandardMessage -Message "[STATUS] Clean: mirror tree (files + dirs)." -Level 'DBG'

            # 1) Remove extra files (entire tree, ignore filter).
            $destFilesAll = Get-ChildItem -Path $destFullPath -Recurse -File
            foreach ($destFile in $destFilesAll) {
                $relative = $destFile.FullName.Substring($destFullPath.Length).TrimStart('\')
                $sourceFilePath = Join-Path -Path $sourceFullPath -ChildPath $relative
                if (-not (Test-Path -Path $sourceFilePath -PathType Leaf)) {
                    _Write-StandardMessage -Message "[REMOVE] File: $($destFile.FullName)" -Level 'DBG'
                    Remove-Item -Path $destFile.FullName -Force
                    $filesRemoved++
                }
            }

            # 2) Remove directories that don't exist in source (deepest-first).
            $destDirs = Get-ChildItem -Path $destFullPath -Recurse -Directory |
                        Sort-Object { $_.FullName.Length } -Descending
            foreach ($destDir in $destDirs) {
                $relativeDir = $destDir.FullName.Substring($destFullPath.Length).TrimStart('\')
                $sourceDirPath = Join-Path -Path $sourceFullPath -ChildPath $relativeDir
                if (-not (Test-Path -Path $sourceDirPath -PathType Container)) {
                    _Write-StandardMessage -Message "[REMOVE] Dir: $($destDir.FullName)" -Level 'DBG'
                    Remove-Item -Path $destDir.FullName -Recurse -Force
                    $dirsRemoved++
                }
            }
        }
        default {
            _Write-StandardMessage -Message "[STATUS] CleanDestination = None." -Level 'DBG'
        }
    }

    if ($CopyEmptyDirs) {
        _Write-StandardMessage -Message "[STATUS] Mode: full dir tree." -Level 'DBG'
        Get-ChildItem -Path $sourceFullPath -Recurse -Directory | ForEach-Object {
            $relativePath = $_.FullName.Substring($sourceFullPath.Length)
            $newDestDir   = Join-Path -Path $destFullPath -ChildPath $relativePath
            if (-not (Test-Path -Path $newDestDir)) {
                _Write-StandardMessage -Message "[CREATE] Dir: $newDestDir" -Level 'DBG'
                New-Item -ItemType Directory -Path $newDestDir | Out-Null
                $dirsCreated++
            }
        }
    }
    else {
        _Write-StandardMessage -Message "[STATUS] Mode: dirs for matching files only." -Level 'DBG'
        foreach ($file in $matchingFiles) {
            $sourceDir   = Split-Path -Path $file.FullName -Parent
            $relativeDir = $sourceDir.Substring($sourceFullPath.Length)
            $newDestDir  = Join-Path -Path $destFullPath -ChildPath $relativeDir
            if (-not (Test-Path -Path $newDestDir)) {
                _Write-StandardMessage -Message "[CREATE] Dir: $newDestDir" -Level 'DBG'
                New-Item -ItemType Directory -Path $newDestDir | Out-Null
                $dirsCreated++
            }
        }
    }

    # Copy files
    if ($CopyEmptyDirs) {
        $filesToCopy = Get-ChildItem -Path $SourceDirectory -Recurse -File -Filter $Filter
    }
    else {
        $filesToCopy = $matchingFiles
    }

    _Write-StandardMessage -Message "[STATUS] Copying files..." -Level 'DBG'

    foreach ($file in $filesToCopy) {
        $relativePath = $file.FullName.Substring($sourceFullPath.Length)
        $destFile     = Join-Path -Path $destFullPath -ChildPath $relativePath

        if (-not $ForceOverwrite -and (Test-Path -Path $destFile)) {
            _Write-StandardMessage -Message "[SKIP] Exists (no overwrite): $destFile" -Level 'DBG'
            $filesSkipped++
            continue
        }

        $destDir = Split-Path -Path $destFile -Parent
        if (-not (Test-Path -Path $destDir)) {
            _Write-StandardMessage -Message "[CREATE] Dir for file: $destDir" -Level 'DBG'
            New-Item -ItemType Directory -Path $destDir | Out-Null
            $dirsCreated++
        }

        _Write-StandardMessage -Message "[STATUS] File: $($file.FullName) -> $destFile" -Level 'DBG'
        if ($ForceOverwrite) {
            Copy-Item -Path $file.FullName -Destination $destFile -Force
        }
        else {
            Copy-Item -Path $file.FullName -Destination $destFile
        }
        $filesCopied++
    }

    # Summary line (compact but readable)
    _Write-StandardMessage -Message (
        "[SUMMARY] Files (copied/skipped/removed): {0}/{1}/{2}; Dirs (created/removed): {3}/{4}." -f $filesCopied, $filesSkipped, $filesRemoved, $dirsCreated, $dirsRemoved
    ) -Level 'INF'
}

function Join-FileText {
<#
.SYNOPSIS
Concatenate text files into a single output file without adding separators by default.

.DESCRIPTION
Reads each input via [System.IO.File]::ReadAllText (auto BOM detection), appends the next file’s
text directly, and finally writes via [System.IO.File]::WriteAllText (framework default encoding).
No line-ending checks are performed; inputs are assumed correct. Optionally add exactly one or two
platform newlines between files via -BetweenFiles, defaulting to none. Idempotent: if the resulting
text equals the current output file’s content, the file is not rewritten.

All parameters require absolute paths. Input files must exist. Output directory must exist.
The output file must not appear among input files.

.PARAMETER InputFiles
Absolute paths of existing input files, concatenated in the given order.

.PARAMETER OutputFile
Absolute path of the output file. Parent directory must already exist.

.PARAMETER BetweenFiles
How many platform newlines to insert between files. Default 'None'.
- 'None' : Insert nothing between files.
- 'One'  : Insert exactly one platform newline between files.
- 'Two'  : Insert exactly two platform newlines between files.

.EXAMPLE
Join-FileText -InputFiles @('C:\Repo\A.md','C:\Repo\B.md') -OutputFile 'C:\Repo\Combined.md'
# Reads A then B and writes A+B as-is (no extra separators).

.EXAMPLE
Join-FileText -InputFiles @('/srv/a.txt','/srv/b.txt','/srv/c.txt') -OutputFile '/srv/all.txt' -BetweenFiles One
# Adds exactly one platform newline between each file’s content, regardless of source endings.

.EXAMPLE
Join-FileText -InputFiles @('/data/p1.csv','/data/p2.csv') -OutputFile '/data/full.csv' -BetweenFiles Two
# Adds exactly two platform newlines between files.

.EXAMPLE
# Idempotent: if Combined.md already matches the concatenation result, no rewrite occurs.
Join-FileText -InputFiles @('C:\Repo\A.md','C:\Repo\B.md') -OutputFile 'C:\Repo\Combined.md'

.NOTES
Compatibility: Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
No pipeline input. No WhatIf/Confirm. ASCII-only implementation.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $InputFiles,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputFile,

        [Parameter(Mandatory=$false)]
        [ValidateSet('None','One','Two')]
        [string] $BetweenFiles = 'None'
    )

    # ---------------- Inline helpers (local scope) ----------------
    function _Write-StandardMessage {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        # This function has exceptions from the rest of any ruleset.
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
        # Resolve MinLevel: explicit > global > default.
        if (-not $PSBoundParameters.ContainsKey('MinLevel')) {
            $gv = Get-Variable -Name 'ConsoleLogMinLevel' -Scope Global -ErrorAction SilentlyContinue
            if ($null -ne $gv -and $null -ne $gv.Value -and -not [string]::IsNullOrEmpty([string]$gv.Value)) {
                $MinLevel = [string]$gv.Value
            } else {
                $MinLevel = 'INF'
            }
        }
        $sevMap = @{ TRC=0; DBG=1; INF=2; WRN=3; ERR=4; FTL=5 }
        $lvl = $Level.ToUpperInvariant() ; $min = $MinLevel.ToUpperInvariant()
        $sev = $sevMap[$lvl] ; $gate = $sevMap[$min]
        # Auto-escalate requested errors to meet strict MinLevel (e.g., MinLevel=FTL)
        if ($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4) { $lvl = $min ; $sev = $gate}
        # Drop below gate
        if ($sev -lt $gate) { return }
        # Timestamp
        $ts = ([DateTime]::UtcNow).ToString('yyyy-MM-dd HH:mm:ss:fff')
        # Resolve caller: prefer "caller of org func" (grandparent of helper)
        $stack      = Get-PSCallStack
        $helperName = $MyInvocation.MyCommand.Name
        $orgFunc    = $null
        $caller     = $null
        if ($stack) {
            $orgIdx = -1
            for ($i = 0; $i -lt $stack.Count; $i++) { if ($stack[$i].FunctionName -ne $helperName) { $orgFunc = $stack[$i]; $orgIdx = $i; break } }
            if ($orgIdx -ge 0) { $callerIdx = $orgIdx + 1; if ($stack.Count -gt $callerIdx) { $caller = $stack[$callerIdx] } else { $caller = $orgFunc } }
        }
        if ($null -eq $caller) { $caller = [pscustomobject]@{ ScriptName = $PSCommandPath; FunctionName = '<scriptblock>' } }
        $file = if ($caller.ScriptName) { Split-Path -Leaf $caller.ScriptName } else { 'console' }
        $func = if ($caller.FunctionName) { $caller.FunctionName } else { '<scriptblock>' }
        # Keep original casing (no .ToLower()) to match definition casing
        $line = "[{0} {1}] [{2}] [{3}] {4}" -f $ts, $lvl, $file, $func, $Message
        # Emit: Output for non-errors; Error for ERR/FTL. Termination via $ErrorActionPreference.
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

    function _Is-Rooted {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([string] $Path)
        if ($null -eq $Path) { return $false }
        try { return [System.IO.Path]::IsPathRooted($Path) } catch { return $false }
    }

    # ---------------- Validation ----------------
    if ($null -eq $InputFiles -or $InputFiles.Count -lt 1) {
        throw "No input files specified. Provide one or more absolute paths via -InputFiles."
    }

    $nonRooted = @()
    $missing   = @()
    foreach ($p in $InputFiles) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (_Is-Rooted -Path $p)) { $nonRooted += $p }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing += $p }
    }
    if ($nonRooted.Count -gt 0) { throw ("InputFiles must be absolute paths:`n - {0}" -f ($nonRooted -join "`n - ")) }
    if ($missing.Count -gt 0)   { throw ("Missing input files:`n - {0}" -f ($missing -join "`n - ")) }

    if (-not (_Is-Rooted -Path $OutputFile)) { throw "OutputFile must be an absolute path." }
    $outParent = Split-Path -Path $OutputFile -Parent
    if ([string]::IsNullOrWhiteSpace($outParent)) { throw "OutputFile must include a parent directory." }
    if (-not (Test-Path -LiteralPath $outParent -PathType Container)) { throw ("Output directory does not exist: {0}" -f $outParent) }

    foreach ($p in $InputFiles) {
        if ($p -eq $OutputFile) { throw "OutputFile must not be included in InputFiles. Choose a different output destination." }
    }

    # ---------------- Concatenate (no line-ending checks) ----------------
    # Reviewer: Keep it simple — read, append, optional fixed separators, write if changed.
    $combined = ''
    $sep = ''
    if ($BetweenFiles -eq 'One') {
        $sep = [Environment]::NewLine
    } elseif ($BetweenFiles -eq 'Two') {
        $sep = [Environment]::NewLine + [Environment]::NewLine
    }

    for ($i = 0; $i -lt $InputFiles.Count; $i++) {
        $text = $null
        try { $text = [System.IO.File]::ReadAllText($InputFiles[$i]) } catch { throw ("Failed to read input file '{0}': {1}" -f $InputFiles[$i], $_.Exception.Message) }
        if ($null -eq $text) { $text = '' }
        if ($i -gt 0 -and $sep -ne '') {
            $combined = $combined + $sep
        }
        $combined = $combined + $text
    }

    # ---------------- Idempotent write ----------------
    $needsWrite = $true
    if (Test-Path -LiteralPath $OutputFile -PathType Leaf) {
        $current = $null
        try { $current = [System.IO.File]::ReadAllText($OutputFile) } catch { throw ("Failed to read existing output file '{0}': {1}" -f $OutputFile, $_.Exception.Message) }
        if ($null -eq $current) {
            if ('' -eq $combined) { $needsWrite = $false }
        } else {
            if ($current -eq $combined) { $needsWrite = $false }
        }
    }

    if ($needsWrite) {
        try { [System.IO.File]::WriteAllText($OutputFile, $combined) } catch { throw ("Failed to write output file '{0}': {1}" -f $OutputFile, $_.Exception.Message) }
        _Write-StandardMessage -Message ("Created/Updated: {0}" -f $OutputFile) -Level 'INF'
    } else {
        _Write-StandardMessage -Message ("No changes: '{0}' is already up to date." -f $OutputFile) -Level 'INF'
    }
}


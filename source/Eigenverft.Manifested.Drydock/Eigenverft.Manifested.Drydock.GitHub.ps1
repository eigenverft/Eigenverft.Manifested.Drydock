function Get-GitHubLatestRelease {
<#
.SYNOPSIS
Gets latest GitHub release assets (Name, Version, DownloadUrl, Path) and downloads them into structured subfolders, with optional extraction for ZIP files.

.DESCRIPTION
Parses the provided GitHub repository URL (https://github.com/owner/repo), queries the GitHub API for the latest release, filters assets by allowlist (Whitelist, all patterns must match) and denylist (BlackList, any substring match), and downloads results into a target folder layout:

- By default, downloads to the user's Downloads folder.
- Per-asset subfolders are used by default; use -NoSubfolder to place the file directly under the chosen folder (or version folder).
- Use -IncludeVersionFolder to insert a version folder (release tag) beneath the DownloadFolder.
- With -Extract, .zip assets are downloaded to a temp location, extracted (overwrite on) into the target directory, and temp data is cleaned up. Non-zip assets are merely downloaded.

Notes:
- Uses WebClient for compatibility with Windows PowerShell 5/5.1. On PowerShell 7+, WebClient is also available.
- Sets TLS 1.2 on older stacks when possible.
- Minimal console logging via _Write-StandardMessage (INF/WRN/ERR/FTL gating).
- Idempotent: re-running converges to the same on-disk state (files are overwritten, extracts overwrite).

.PARAMETER RepoUrl
Full URL to a GitHub repository, for example: https://github.com/owner/repo

.PARAMETER Whitelist
Wildcard patterns; only assets whose names match every provided pattern are included. If omitted, all assets are considered before BlackList filtering.

.PARAMETER BlackList
Substring patterns; assets whose names contain any provided substring (case-insensitive) are excluded.

.PARAMETER DownloadFolder
Root folder where assets will be placed. Defaults to the current user's Downloads folder if omitted.

.PARAMETER NoSubfolder
When present, disables the default per-asset subfolder creation.

.PARAMETER IncludeVersionFolder
When present, prepends the release tag as a version folder under DownloadFolder.

.PARAMETER Extract
When present, ZIP assets are extracted (overwrite) into the target directory after download; non-zip assets are downloaded as files.

.OUTPUTS
System.Object
Each asset is emitted as a PSCustomObject with properties:
- Name
- Version
- DownloadUrl
- Path   # file path for non-extracted items; target directory when extracted

.EXAMPLE
# Download all latest assets into per-asset folders under a version folder
Get-GitHubLatestRelease -RepoUrl 'https://github.com/ggml-org/llama.cpp' -IncludeVersionFolder

.EXAMPLE
# Allowlist AVX2 builds only, exclude debug artifacts, extract ZIPs, do not create per-asset subfolders
Get-GitHubLatestRelease -RepoUrl 'https://github.com/ggml-org/llama.cpp' -Whitelist '*avx2*' -BlackList 'debug' -NoSubfolder -Extract

.EXAMPLE
# Only x64 artifacts, exclude any 'beta' labeled assets, default layout (per-asset subfolders)
Get-GitHubLatestRelease -RepoUrl 'https://github.com/owner/repo' -Whitelist '*x64*' -BlackList 'beta'

.NOTES
Requires internet access. Uses GitHub's public API and a default User-Agent. Handles TLS 1.2 enablement when possible. No external executables required.
#>
    [CmdletBinding()]
    [Alias('gglr')]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoUrl,

        [Parameter()]
        [string[]]$Whitelist,

        [Parameter()]
        [string[]]$BlackList,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$DownloadFolder,

        [Parameter()]
        [switch]$NoSubfolder,

        [Parameter()]
        [switch]$IncludeVersionFolder,

        [Parameter()]
        [switch]$Extract
    )

    # ---- Inline helpers (local scope only) ---------------------------------

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
        if (-not $PSBoundParameters.ContainsKey('MinLevel')) { $MinLevel = if ($Global:ConsoleLogMinLevel) { $Global:ConsoleLogMinLevel } else { 'INF' } }
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
            for ($i = 0; $i -lt $stack.Count; $i++) { if ($stack[$i].FunctionName -ne $helperName) { $orgFunc = $stack[$i]; $orgIdx = $i; break } }
            if ($orgIdx -ge 0) { $callerIdx = $orgIdx + 1; if ($stack.Count -gt $callerIdx) { $caller = $stack[$callerIdx] } else { $caller = $orgFunc } }
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

    function _Download-File {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory=$true)][string]$Uri,
            [Parameter(Mandatory=$true)][string]$Destination
        )
        # Ensure TLS 1.2 on older stacks (best-effort).
        try {
            $spm = [type]::GetType('System.Net.ServicePointManager')
            if ($spm) {
                $protoProp = $spm.GetProperty('SecurityProtocol')
                if ($protoProp) {
                    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                }
            }
        } catch { }

        # Use WebClient for PS5 compatibility and cross-platform Core availability.
        $wc = New-Object System.Net.WebClient
        try {
            $wc.Headers['User-Agent'] = 'PowerShell-GetGitHubLatestRelease/1.0'
            $wc.Headers['Accept']     = 'application/octet-stream'
            $dir = Split-Path -Parent $Destination
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            $wc.DownloadFile($Uri, $Destination)
        } finally {
            $wc.Dispose()
        }
    }

    function _AllPatternsMatch {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory=$true)][string]$Name,
            [Parameter()][string[]]$Patterns
        )
        if ($null -eq $Patterns -or $Patterns.Count -eq 0) { return $true }
        for ($i = 0; $i -lt $Patterns.Count; $i++) {
            $p = $Patterns[$i]
            if ($null -eq $p -or $p.Length -eq 0) { return $false }
            if (-not ($Name -like $p)) { return $false }
        }
        return $true
    }

    function _ContainsAnySubstringCI {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory=$true)][string]$Name,
            [Parameter()][string[]]$Needles
        )
        if ($null -eq $Needles -or $Needles.Count -eq 0) { return $false }
        for ($i = 0; $i -lt $Needles.Count; $i++) {
            $n = $Needles[$i]
            if ($null -ne $n -and $n.Length -gt 0) {
                if ($Name.IndexOf($n, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
            }
        }
        return $false
    }

    # ---- Resolve DownloadFolder default ------------------------------------
    if (-not $PSBoundParameters.ContainsKey('DownloadFolder')) {
        $userHome = [Environment]::GetFolderPath('UserProfile')
        if ($null -eq $userHome -or $userHome.Length -eq 0) {
            # Fallback to env var if needed
            $userHome = $env:USERPROFILE
        }
        if ($null -eq $userHome -or $userHome.Length -eq 0) {
            _Write-StandardMessage -Message "Cannot determine home directory to compute default Downloads path." -Level ERR
            return
        }
        $DownloadFolder = Join-Path -Path $userHome -ChildPath 'Downloads'
    }

    # ---- Parse GitHub URL ---------------------------------------------------
    $owner = $null
    $repo  = $null
    try {
        $u = [Uri]$RepoUrl
        $path = $u.AbsolutePath.Trim('/')
        # Remove trailing ".git" if present.
        if ($path.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
            $path = $path.Substring(0, $path.Length - 4)
        }
        $parts = $path.Split('/')
        if ($parts.Length -lt 2) { throw [System.ArgumentException]::new('Expected URL like https://github.com/owner/repo') }
        $owner = $parts[0]
        $repo  = $parts[1]
    } catch {
        _Write-StandardMessage -Message ("RepoUrl parse failed: {0}" -f $_.Exception.Message) -Level ERR
        return
    }

    # ---- Query GitHub API ---------------------------------------------------
    $release = $null
    try {
        $apiUri  = 'https://api.github.com/repos/{0}/{1}/releases/latest' -f $owner, $repo
        $headers = @{
            'User-Agent' = 'PowerShell-GetGitHubLatestRelease/1.0'
            'Accept'     = 'application/vnd.github+json'
        }
        # Best-effort TLS12 for older PS5; harmless on PS7.
        try {
            $spm = [type]::GetType('System.Net.ServicePointManager')
            if ($spm) {
                $protoProp = $spm.GetProperty('SecurityProtocol')
                if ($protoProp) {
                    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                }
            }
        } catch { }
        $release = Invoke-RestMethod -Uri $apiUri -Headers $headers -Method Get
    } catch {
        _Write-StandardMessage -Message ("GitHub API call failed for {0}/{1}: {2}" -f $owner, $repo, $_.Exception.Message) -Level ERR
        return
    }

    if ($null -eq $release) {
        _Write-StandardMessage -Message "GitHub API returned no data." -Level ERR
        return
    }

    $tag = $null
    if ($null -ne $release.tag_name -and $release.tag_name.ToString().Length -gt 0) {
        $tag = $release.tag_name.ToString()
    } elseif ($null -ne $release.name -and $release.name.ToString().Length -gt 0) {
        $tag = $release.name.ToString()
    } else {
        $tag = 'unknown'
    }

    $assets = @()
    if ($null -ne $release.assets) {
        # Copy to a PowerShell array to avoid relying on pipeline variables.
        for ($i = 0; $i -lt $release.assets.Count; $i++) { $assets += ,$release.assets[$i] }
    }

    if ($assets.Count -eq 0) {
        _Write-StandardMessage -Message ("No assets found for latest release {0}/{1} tag {2}." -f $owner, $repo, $tag) -Level WRN
        return @()
    }

    # ---- Filter by Whitelist/BlackList -------------------------------------
    $selected = @()
    for ($i = 0; $i -lt $assets.Count; $i++) {
        $a = $assets[$i]
        $n = [string]$a.name
        if (-not (_AllPatternsMatch -Name $n -Patterns $Whitelist)) { continue }
        if (_ContainsAnySubstringCI -Name $n -Needles $BlackList) { continue }
        $selected += ,$a
    }

    if ($selected.Count -eq 0) {
        _Write-StandardMessage -Message "No assets matched allow/deny filters." -Level WRN
        return @()
    }

    # ---- Prepare extraction support if needed -------------------------------
    $zipTypeReady = $false
    if ($Extract.IsPresent) {
        try {
            $null = [System.IO.Compression.ZipFile]
            $zipTypeReady = $true
        } catch {
            try {
                [void][System.Reflection.Assembly]::Load('System.IO.Compression.FileSystem')
                $null = [System.IO.Compression.ZipFile]
                $zipTypeReady = $true
            } catch {
                _Write-StandardMessage -Message "ZIP extraction requires System.IO.Compression.ZipFile which is unavailable." -Level ERR
                return
            }
        }
    }

    # ---- Ensure base folders exist -----------------------------------------
    if (-not (Test-Path -LiteralPath $DownloadFolder)) {
        New-Item -ItemType Directory -Path $DownloadFolder -Force | Out-Null
        _Write-StandardMessage -Message ("Created directory: {0}" -f $DownloadFolder)
    }

    $rootTarget = $DownloadFolder
    if ($IncludeVersionFolder.IsPresent) {
        $rootTarget = Join-Path -Path $rootTarget -ChildPath $tag
        if (-not (Test-Path -LiteralPath $rootTarget)) {
            New-Item -ItemType Directory -Path $rootTarget -Force | Out-Null
            _Write-StandardMessage -Message ("Created version directory: {0}" -f $rootTarget)
        }
    }

    # One temp root for this command invocation (used only if Extract).
    $tempRoot = $null
    if ($Extract.IsPresent) {
        $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ([Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    }

    # ---- Process assets -----------------------------------------------------
    $results = @()
    for ($i = 0; $i -lt $selected.Count; $i++) {
        $asset = $selected[$i]
        $name  = [string]$asset.name
        $url   = [string]$asset.browser_download_url

        $targetDir = $rootTarget
        if (-not $NoSubfolder.IsPresent) {
            $base = [IO.Path]::GetFileNameWithoutExtension($name)
            if ($base.Length -eq 0) { $base = 'artifact' }
            $targetDir = Join-Path -Path $targetDir -ChildPath $base
        }

        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            _Write-StandardMessage -Message ("Created directory: {0}" -f $targetDir)
        }

        $pathOut = $null
        $ext = [IO.Path]::GetExtension($name)
        if ($Extract.IsPresent -and $zipTypeReady -and ($null -ne $ext) -and ($ext.Equals('.zip', [System.StringComparison]::OrdinalIgnoreCase))) {
            # Download ZIP to temp file, then extract overwrite.
            $tempZip = Join-Path -Path $tempRoot -ChildPath $name
            _Download-File -Uri $url -Destination $tempZip
            _Write-StandardMessage -Message ("Downloaded: {0}" -f $name)
            try {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
                try {
                    for ($e = 0; $e -lt $zip.Entries.Count; $e++) {
                        $entry = $zip.Entries[$e]
                        if ($null -eq $entry.Name -or $entry.Name.Length -eq 0) {
                            # Directory entry in archive; ensure directory exists.
                            $dirPath = Join-Path -Path $targetDir -ChildPath $entry.FullName
                            if (-not (Test-Path -LiteralPath $dirPath)) {
                                New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
                            }
                            continue
                        }
                        $destPath = Join-Path -Path $targetDir -ChildPath $entry.FullName
                        $destDir  = Split-Path -Parent $destPath
                        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
                            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                        }
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
                    }
                } finally {
                    $zip.Dispose()
                }
            } catch {
                _Write-StandardMessage -Message ("Extraction failed for {0}: {1}" -f $name, $_.Exception.Message) -Level ERR
                return
            } finally {
                if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force }
            }
            _Write-StandardMessage -Message ("Extracted: {0} -> {1}" -f $name, $targetDir)
            $pathOut = $targetDir
        } else {
            $destFile = Join-Path -Path $targetDir -ChildPath $name
            _Download-File -Uri $url -Destination $destFile
            _Write-StandardMessage -Message ("Downloaded: {0} -> {1}" -f $name, $destFile)
            $pathOut = $destFile
        }

        $results += [PSCustomObject]@{
            Name        = $name
            Version     = $tag
            DownloadUrl = $url
            Path        = $pathOut
        }
    }

    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force } catch { }
    }

    return $results
}
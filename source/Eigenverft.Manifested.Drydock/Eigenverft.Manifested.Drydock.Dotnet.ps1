function Enable-TempDotnetTools {
<#
.SYNOPSIS
Install local-tools from a manifest into an ephemeral cache and expose them for THIS session.

.DESCRIPTION
- Reads a standard dotnet local tools manifest (dotnet-tools.json) with exact versions.
- Ensures each tool exists in a --tool-path cache (sticky or fresh).
- Puts that folder at the front of PATH for the current session only.
- Returns a single object: @{ ToolPath = "..."; Tools = [ @{Id,Version,Status[,Command]}, ... ] }.

.PARAMETER ManifestFile
Path to the dotnet local tools manifest (dotnet-tools.json).

.PARAMETER ToolPath
Optional explicit --tool-path. If omitted, a stable cache path is derived from the manifest hash.

.PARAMETER Fresh
If set, uses a brand-new GUID cache folder (cold start each time).

.PARAMETER NoCache
If set, passes --no-cache to dotnet (disables NuGet HTTP cache; slower).

.PARAMETER NoReturn
If set, the function does not return the object to the pipeline (console stays clean).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestFile,
        [string]$ToolPath,
        [switch]$Fresh,
        [switch]$NoCache,
        [switch]$NoReturn
    )

    # -----------------------
    # Local helper functions
    # -----------------------

    function _GetToolsInPath {
        param([Parameter(Mandatory)][string]$Path)

        # Prefer --detail for stable parsing; fall back to table format but skip header.
        $map = @{}

        $detail = & dotnet tool list --tool-path $Path --detail 2>$null
        if ($LASTEXITCODE -eq 0 -and $detail -and ($detail -match 'Package Id\s*:')) {
            $block = @()
            foreach ($line in ($detail -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    if ($block.Count) {
                        $id=$null; $ver=$null
                        foreach ($l in $block) {
                            if ($l -match '^\s*Package Id\s*:\s*(.+)$') { $id = $matches[1].Trim() }
                            elseif ($l -match '^\s*Version\s*:\s*(.+)$')   { $ver = $matches[1].Trim() }
                        }
                        if ($id) { $map[$id] = $ver }
                        $block = @()
                    }
                } else { $block += $line }
            }
            if ($block.Count) {
                $id=$null; $ver=$null
                foreach ($l in $block) {
                    if     ($l -match '^\s*Package Id\s*:\s*(.+)$') { $id = $matches[1].Trim() }
                    elseif ($l -match '^\s*Version\s*:\s*(.+)$')     { $ver = $matches[1].Trim() }
                }
                if ($id) { $map[$id] = $ver }
            }
            return $map
        }

        $table = & dotnet tool list --tool-path $Path 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $table) { return @{} }
        foreach ($l in ($table -split "`r?`n")) {
            if ($l -match '^\s*(\S+)\s+(\S+)\s+') {
                $id = $matches[1]; $ver = $matches[2]
                if ($id -eq 'Package' -and $ver -eq 'Id') { continue } # skip header
                $map[$id] = $ver
            }
        }
        return $map
    }

    function _GetToolCommandsInPath {
        param([Parameter(Mandatory)][string]$Path)
        # Parse commands from --detail; returns @{ <id> = @('cmd1','cmd2') }
        $cmds = @{}
        $detail = & dotnet tool list --tool-path $Path --detail 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $detail) { return $cmds }

        $block = @()
        foreach ($line in ($detail -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                if ($block.Count) {
                    $id=$null; $names=$null
                    foreach ($l in $block) {
                        if ($l -match '^\s*Package Id\s*:\s*(.+)$')        { $id    = $matches[1].Trim() }
                        elseif ($l -match '^\s*Tool command name\s*:\s*(.+)$') { $names = $matches[1].Trim() }
                    }
                    if ($id -and $names) {
                        $arr = @()
                        foreach ($n in ($names -split ',')) { $arr += $n.Trim() }
                        $cmds[$id] = $arr
                    }
                    $block = @()
                }
            } else { $block += $line }
        }
        if ($block.Count) {
            $id=$null; $names=$null
            foreach ($l in $block) {
                if     ($l -match '^\s*Package Id\s*:\s*(.+)$')           { $id    = $matches[1].Trim() }
                elseif ($l -match '^\s*Tool command name\s*:\s*(.+)$')    { $names = $matches[1].Trim() }
            }
            if ($id -and $names) {
                $arr = @()
                foreach ($n in ($names -split ',')) { $arr += $n.Trim() }
                $cmds[$id] = $arr
            }
        }
        return $cmds
    }

    function _EnsureExactTool {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$Version,
            [switch]$NoCache,
            [switch]$TryUpdateFirst
        )
        # Order: update -> install (when present) or install -> update (when missing)
        if ($TryUpdateFirst) {
            $cliArgs = @("tool","update","--tool-path",$Path,"--version",$Version,$Id)
            if ($NoCache) { $cliArgs += "--no-cache" }
            & dotnet @cliArgs 2>$null
            if ($LASTEXITCODE -eq 0) { return $true }
            $cliArgs = @("tool","install","--tool-path",$Path,"--version",$Version,$Id)
            if ($NoCache) { $cliArgs += "--no-cache" }
            & dotnet @cliArgs
            return ($LASTEXITCODE -eq 0)
        }
        else {
            $cliArgs = @("tool","install","--tool-path",$Path,"--version",$Version,$Id)
            if ($NoCache) { $cliArgs += "--no-cache" }
            & dotnet @cliArgs 2>$null
            if ($LASTEXITCODE -eq 0) { return $true }
            $cliArgs = @("tool","update","--tool-path",$Path,"--version",$Version,$Id)
            if ($NoCache) { $cliArgs += "--no-cache" }
            & dotnet @cliArgs
            return ($LASTEXITCODE -eq 0)
        }
    }

    function _PrependPathIfMissing {
        param([Parameter(Mandatory)][string]$Path)
        $sep = [IO.Path]::PathSeparator
        $parts = $env:PATH -split [regex]::Escape($sep)
        foreach ($p in $parts) { if ($p -eq $Path) { return } }
        $env:PATH = ($Path + $sep + $env:PATH)
    }

    # -----------------------
    # 1) Resolve inputs
    # -----------------------

    $mf = Resolve-Path -LiteralPath $ManifestFile -ErrorAction Stop
    Write-Host ("[dotnet-tools] Manifest:        {0}" -f $mf.Path) -ForegroundColor DarkGray

    $manifest = Get-Content -Raw -LiteralPath $mf | ConvertFrom-Json
    if (-not $manifest.tools) { throw "Manifest has no 'tools' entries: $mf" }

    # Derive tool-path: fresh GUID or sticky cache (hash of manifest) or explicit path
    if ($Fresh) {
        $ToolPath = Join-Path $env:TEMP ("dotnet-tools\" + [guid]::NewGuid().ToString("n"))
    }
    elseif (-not $ToolPath) {
        $hash = (Get-FileHash -LiteralPath $mf -Algorithm SHA256).Hash.Substring(0,16)
        $base = [Environment]::GetFolderPath('LocalApplicationData')
        if (-not $base) { $base = $env:TEMP }
        $ToolPath = Join-Path $base ("dotnet-tools-cache\" + $hash)
    }
    New-Item -ItemType Directory -Force -Path $ToolPath | Out-Null
    Write-Host ("[dotnet-tools] Cache (toolpath): {0}" -f $ToolPath) -ForegroundColor DarkGray

    # -----------------------
    # 2) Snapshot BEFORE
    # -----------------------
    $before = _GetToolsInPath -Path $ToolPath
    if ($before.Count -gt 0) {
        Write-Host ("[dotnet-tools] Cache existing:  {0}" -f $before.Count) -ForegroundColor DarkGray
        foreach ($k in ($before.Keys | Sort-Object)) {
            Write-Host ("  - {0} {1}" -f $k, $before[$k]) -ForegroundColor DarkGray
        }
    } else {
        Write-Host "[dotnet-tools] Cache existing:  none" -ForegroundColor DarkGray
    }

    # -----------------------
    # 3) Ensure each tool (sorted for readability)
    # -----------------------
    $toolsResult = @()
    $toolProps = $manifest.tools.PSObject.Properties | Sort-Object Name
    foreach ($prop in $toolProps) {
        $id = [string]$prop.Name
        $ver = [string]$prop.Value.version
        if (-not $ver) { throw "Tool '$id' in manifest lacks a 'version'." }

        $present   = $before.ContainsKey($id)
        $unchanged = $present -and ($before[$id] -eq $ver)

        $status = "AlreadyPresent"
        if (-not $unchanged) {
            Write-Host ("[dotnet-tools] Ensuring:       {0}@{1}" -f $id, $ver) -ForegroundColor DarkGray
            $ok = _EnsureExactTool -Path $ToolPath -Id $id -Version $ver -NoCache:$NoCache -TryUpdateFirst:$present
            if (-not $ok) { throw "Failed to ensure $id@$ver in $ToolPath." }
            if ($present) {
                $status = "Updated"
            } else {
                $status = "Installed"
            }
        }

        # Per-tool status line with color
        switch ($status) {
            "Installed" { $fc = "Green" }
            "Updated"   { $fc = "Yellow" }
            default     { $fc = "Cyan" } # AlreadyPresent
        }
        Write-Host ("[{0,-10}] {1}@{2}" -f $status, $id, $ver) -ForegroundColor $fc

        $toolsResult += [pscustomobject]@{ Id = $id; Version = $ver; Status = $status }
    }

    # -----------------------
    # 4) PATH (session only)
    # -----------------------
    _PrependPathIfMissing -Path $ToolPath
    Write-Host ("[dotnet-tools] PATH updated:    {0}" -f $ToolPath) -ForegroundColor DarkGray


    # -----------------------
    # 5) Snapshot AFTER (normalize versions actually resolved by dotnet) + commands (from manifest)
    # -----------------------
    $after = _GetToolsInPath -Path $ToolPath

    # Build command map from the manifest (tools.<id>.commands)
    $cmdInfo = @{}
    $manifestToolsProps = $manifest.tools.PSObject.Properties | Sort-Object Name
    foreach ($p in $manifestToolsProps) {
        $id = [string]$p.Name
        $cmds = @()
        if ($p.Value.PSObject.Properties.Name -contains 'commands') {
            foreach ($n in @($p.Value.commands)) {
                if ($n) { $cmds += [string]$n }
            }
        }
        if ($cmds.Count -gt 0) { $cmdInfo[$id] = $cmds }
    }

    for ($i = 0; $i -lt $toolsResult.Count; $i++) {
        $rid = $toolsResult[$i].Id
        if ($after.ContainsKey($rid)) {
            if ($toolsResult[$i].Version -ne $after[$rid]) {
                Write-Host ("[dotnet-tools] Resolved:       {0} -> {1}" -f $toolsResult[$i].Version, $after[$rid]) -ForegroundColor DarkGray
            }
            $toolsResult[$i].Version = $after[$rid]
        }

        if ($cmdInfo.ContainsKey($rid)) {
            $cmdsText = ($cmdInfo[$rid] -join ", ")
            # Attach Command property always, so the printout is consistent.
            Add-Member -InputObject $toolsResult[$i] -NotePropertyName Command -NotePropertyValue $cmdsText -Force
        }
    }

    # -----------------------
    # Pretty print manifest-sourced command names (ASCII only, PS5-safe)
    # -----------------------
    $rows = @()
    foreach ($p in $manifestToolsProps) {
        $id = [string]$p.Name
        $hasCmd = $false
        $joined = "(none)"
        if ($cmdInfo.ContainsKey($id) -and $cmdInfo[$id].Count -gt 0) {
            $joined = ($cmdInfo[$id] -join ", ")
            $hasCmd = $true
        }
        $rows += New-Object psobject -Property @{ Id = $id; Cmds = $joined; Has = $hasCmd }
    }

    # Determine column width for PACKAGE column (min width 8)
    $idWidth = 8
    foreach ($r in $rows) { if ($r.Id.Length -gt $idWidth) { $idWidth = $r.Id.Length } }

    $headerLeft  = "PACKAGE".PadRight($idWidth)
    $headerRight = "TOOLCOMMANDNAMES"
    $sepLeft  = ("-" * $idWidth)
    $sepRight = ("-" * $headerRight.Length)

    Write-Host ("[dotnet-tools] Commands (manifest): {0} tool(s)" -f $rows.Count) -ForegroundColor Cyan
    Write-Host ("  {0}   {1}" -f $headerLeft, $headerRight) -ForegroundColor DarkGray
    Write-Host ("  {0}   {1}" -f $sepLeft,     $sepRight)   -ForegroundColor DarkGray

    foreach ($r in $rows) {
        # ASCII status symbol and simple colors (no Unicode)
        $symbol   = "-"
        $symColor = "DarkGray"
        if ($r.Has) { $symbol = "+"; $symColor = "Green" }

        $cmdColor = "DarkGray"
        if ($r.Has) { $cmdColor = "White" }

        Write-Host "  " -NoNewline
        Write-Host $symbol -ForegroundColor $symColor -NoNewline
        Write-Host (" {0} " -f $r.Id.PadRight($idWidth)) -ForegroundColor Gray -NoNewline
        Write-Host " ... " -ForegroundColor DarkGray -NoNewline
        Write-Host $r.Cmds -ForegroundColor $cmdColor
    }


    # -----------------------
    # 6) Return single object (unless -NoReturn)
    # -----------------------
    if (-not $NoReturn) {
        return [pscustomobject]@{
            ToolPath = $ToolPath
            Tools    = $toolsResult
        }
    }
}

function Disable-TempDotnetTools {
<#
.SYNOPSIS
Remove the ephemeral tool cache from PATH and optionally delete it.

.DESCRIPTION
- Accepts either a direct --tool-path or a manifest file.
- When given -ManifestFile, computes the same sticky cache path used by Enable-TempDotnetTools:
  %LOCALAPPDATA%\dotnet-tools-cache\<SHA256(manifest CONTENT) first 16 chars>
- Removes that folder from the current session PATH.
- Optionally deletes the folder (cold start next time).

.PARAMETER ToolPath
The folder previously used with --tool-path.

.PARAMETER ManifestFile
Path to dotnet-tools.json; used to derive the sticky cache path.

.PARAMETER Delete
Also delete the cache folder on disk.

.EXAMPLE
Disable-TempDotnetTools -ManifestFile "$PSScriptRoot\.config\dotnet-tools.json" -Delete
#>
    [CmdletBinding(SupportsShouldProcess=$true, DefaultParameterSetName='ByToolPath')]
    param(
        [Parameter(Mandatory=$true, ParameterSetName='ByToolPath')]
        [string]$ToolPath,

        [Parameter(Mandatory=$true, ParameterSetName='ByManifestFile')]
        [string]$ManifestFile,

        [switch]$Delete
    )

    # Resolve tool path from manifest if requested (uses CONTENT hash to match Enable-TempDotnetTools)
    if ($PSCmdlet.ParameterSetName -eq 'ByManifestFile') {
        $mf = Resolve-Path -LiteralPath $ManifestFile -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $mf -Algorithm SHA256).Hash.Substring(0,16)
        $base = [Environment]::GetFolderPath('LocalApplicationData')
        if (-not $base) { $base = $env:TEMP }
        $ToolPath = Join-Path $base ("dotnet-tools-cache\" + $hash)
    }

    # Remove from PATH (session only)
    $sep   = [IO.Path]::PathSeparator
    $parts = $env:PATH -split [regex]::Escape($sep)
    $env:PATH = ($parts | Where-Object { $_ -and ($_ -ne $ToolPath) }) -join $sep

    # Optionally delete on disk
    if ($Delete -and (Test-Path -LiteralPath $ToolPath)) {
        if ($PSCmdlet.ShouldProcess($ToolPath, "Remove-Item -Recurse -Force")) {
            Remove-Item -LiteralPath $ToolPath -Recurse -Force
        }
    }
}

function Register-LocalNuGetDotNetPackageSource {
<#
.SYNOPSIS
    Registers a NuGet source using the dotnet CLI and returns its effective name.

.DESCRIPTION
    Ensures the given Location (URL or local path) is present in dotnet nuget sources
    under the chosen name and state (Enabled/Disabled). If -SourceName is omitted,
    the function reuses an existing name for the same Location or generates a temporary one.
    Returns the effective SourceName as a string.

.PARAMETER SourceLocation
    Source location. HTTP(S) URL or local/UNC path. Local paths will be created if missing.
    Default: "$HOME/source/LocalNuGet".

.PARAMETER SourceName
    Optional name. If omitted, reuse by Location or generate TempNuGetSrc-xxxxxxxx.
    Must start/end with a letter or digit; dot, hyphen, underscore allowed inside.

.PARAMETER SourceState
    Enabled or Disabled. Default: Enabled. If a source exists with a different state,
    it will be toggled accordingly.

.EXAMPLE
    $n = Register-LocalNuGetDotNetPackageSource -SourceLocation "C:\nuget-local"

.EXAMPLE
    $n = Register-LocalNuGetDotNetPackageSource -SourceLocation "https://api.nuget.org/v3/index.json" -SourceName "nuget.org" -SourceState Enabled
#>
    [CmdletBinding()]
    [Alias("rldnps")]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceLocation = "$HOME/source/LocalNuGet",

        [Parameter(Mandatory = $false)]
        [string]$SourceName,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Enabled','Disabled')]
        [string]$SourceState = 'Enabled'
    )

    function Invoke-DotNetNuGet([string[]]$CmdArgs) {
        $out = & dotnet @CmdArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "dotnet nuget failed ($LASTEXITCODE): $out" }
        return $out
    }

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw "dotnet CLI not found on PATH."
    }

    # Detect URL vs local path; normalize and ensure local dir when needed.
    $isUrl = $false
    try {
        $u = [Uri]$SourceLocation
        if ($u.IsAbsoluteUri -and ($u.Scheme -eq 'http' -or $u.Scheme -eq 'https')) { $isUrl = $true }
    } catch { $isUrl = $false }

    if ($isUrl) {
        Write-Host "Using URL source location: $SourceLocation" -ForegroundColor Cyan
    } else {
        try {
            $SourceLocation = [IO.Path]::GetFullPath((Join-Path -Path $SourceLocation -ChildPath '.'))
        } catch {
            throw "Invalid source path '$SourceLocation': $($_.Exception.Message)"
        }
        if (-not (Test-Path -Path $SourceLocation -PathType Container)) {
            try {
                New-Item -ItemType Directory -Path $SourceLocation -Force -ErrorAction Stop | Out-Null
                Write-Host "Created local source directory: $SourceLocation" -ForegroundColor Green
            } catch {
                throw "Failed to create source directory '$SourceLocation': $($_.Exception.Message)"
            }
        } else {
            Write-Host "Using local source directory: $SourceLocation" -ForegroundColor Cyan
        }
    }

    # List and parse existing sources.
    $lines = (Invoke-DotNetNuGet @('nuget','list','source')) -split '\r?\n'
    $entries = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\d+\.\s*(?<Name>\S+)\s*\[(?<Status>Enabled|Disabled)\]\s*$') {
            $nm = $Matches['Name']; $st = $Matches['Status']
            $loc = $null
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                $t = $lines[$j].Trim()
                if ($t) { $loc = $t; break }
            }
            if ($loc) { $entries.Add([PSCustomObject]@{ Name=$nm; Location=$loc; Status=$st }) }
        }
    }

    # Determine or validate name.
    $namePattern = '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$'
    if ([string]::IsNullOrWhiteSpace($SourceName)) {
        $byLoc = $entries | Where-Object { $_.Location -eq $SourceLocation } | Select-Object -First 1
        if ($byLoc) {
            $SourceName = $byLoc.Name
            Write-Host "Reusing existing source name '$SourceName' for location '$SourceLocation'." -ForegroundColor Yellow
        }
        else {
            $SourceName = 'TempNuGetSrc-' + ([Guid]::NewGuid().ToString('N').Substring(8))
            Write-Host "Generated temporary source name: $SourceName" -ForegroundColor Yellow
        }
    } elseif ($SourceName -notmatch $namePattern) {
        throw "SourceName '$SourceName' is invalid. Allowed: letters/digits; dot, hyphen, underscore allowed inside."
    }

    $byName = $entries | Where-Object { $_.Name -eq $SourceName } | Select-Object -First 1
    $byLoc2 = $entries | Where-Object { $_.Location -eq $SourceLocation } | Select-Object -First 1

    # Reconcile location/name clashes.
    if ($byLoc2 -and -not $byName) {
        if ($PSBoundParameters.ContainsKey('SourceName')) {
            Write-Host "Removing conflicting existing source '$($byLoc2.Name)' for location '$SourceLocation'." -ForegroundColor Yellow
            Invoke-DotNetNuGet @('nuget','remove','source',$byLoc2.Name) | Out-Null
        } else {
            $SourceName = $byLoc2.Name
            $byName = $byLoc2
            Write-Host "Reusing existing source '$SourceName' bound to location '$SourceLocation'." -ForegroundColor Yellow
        }
    }

    if ($byName) {
        if ($byName.Location -ne $SourceLocation) {
            Write-Host "Updating source '$SourceName' location from '$($byName.Location)' to '$SourceLocation'." -ForegroundColor Cyan
            Invoke-DotNetNuGet @('nuget','remove','source',$SourceName) | Out-Null
            Invoke-DotNetNuGet @('nuget','add','source',$SourceLocation,'--name',$SourceName) | Out-Null
            $byName = [PSCustomObject]@{ Name=$SourceName; Location=$SourceLocation; Status='Enabled' }
            Write-Host "Source '$SourceName' added at '$SourceLocation' (Enabled)." -ForegroundColor Green
        }
        if ($SourceState -eq 'Enabled' -and $byName.Status -eq 'Disabled') {
            Write-Host "Enabling source '$SourceName'." -ForegroundColor Cyan
            Invoke-DotNetNuGet @('nuget','enable','source',$SourceName) | Out-Null
            Write-Host "Source '$SourceName' is now Enabled." -ForegroundColor Green
        } elseif ($SourceState -eq 'Disabled' -and $byName.Status -eq 'Enabled') {
            Write-Host "Disabling source '$SourceName'." -ForegroundColor Cyan
            Invoke-DotNetNuGet @('nuget','disable','source',$SourceName) | Out-Null
            Write-Host "Source '$SourceName' is now Disabled." -ForegroundColor Green
        } else {
            Write-Host "No state change needed for '$SourceName' (already $($byName.Status))." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Adding source '$SourceName' at '$SourceLocation'." -ForegroundColor Cyan
        Invoke-DotNetNuGet @('nuget','add','source',$SourceLocation,'--name',$SourceName) | Out-Null
        if ($SourceState -eq 'Disabled') {
            Write-Host "Disabling source '$SourceName' after add." -ForegroundColor Cyan
            Invoke-DotNetNuGet @('nuget','disable','source',$SourceName) | Out-Null
            Write-Host "Source '$SourceName' is now Disabled." -ForegroundColor Green
        } else {
            Write-Host "Source '$SourceName' added and Enabled." -ForegroundColor Green
        }
    }

    return $SourceName
}

function Unregister-LocalNuGetDotNetPackageSource {
<#
.SYNOPSIS
    Unregisters a NuGet source by name using the dotnet CLI.

.DESCRIPTION
    Removes the specified source if present. Safe to call repeatedly; no error if already absent.

.PARAMETER SourceName
    Source name to remove. Must start/end with a letter or digit; dot, hyphen, underscore allowed inside.

.EXAMPLE
    $n = Register-LocalNuGetDotNetPackageSource -SourceLocation "C:\nuget-local"
    Unregister-LocalNuGetDotNetPackageSource -SourceName $n
#>
    [CmdletBinding()]
    [Alias("uldnps")]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])$')]
        [string]$SourceName
    )

    function Invoke-DotNetNuGet([string[]]$CmdArgs) {
        $out = & dotnet @CmdArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "dotnet nuget failed ($LASTEXITCODE): $out" }
        return $out
    }

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw "dotnet CLI not found on PATH."
    }

    $lines = (Invoke-DotNetNuGet @('nuget','list','source')) -split '\r?\n'
    $exists = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\d+\.\s*' + [regex]::Escape($SourceName) + '\s*\[(Enabled|Disabled)\]\s*$') {
            $exists = $true
            break
        }
    }

    if ($exists) {
        Write-Host "Removing NuGet source '$SourceName'." -ForegroundColor Cyan
        Invoke-DotNetNuGet @('nuget','remove','source',$SourceName) | Out-Null
        Write-Host "NuGet source '$SourceName' removed." -ForegroundColor Green
    } else {
        Write-Host "NuGet source '$SourceName' not found; nothing to do." -ForegroundColor Yellow
    }
}

function New-DotnetVulnerabilitiesReport {
<#
.SYNOPSIS
Generate a vulnerabilities report from one or more 'dotnet list ... package --vulnerable --format json' documents.

.DESCRIPTION
StrictMode-safe parser that accepts:
- a complete JSON string,
- an array of lines forming one JSON document,
- an already-parsed PSCustomObject/hashtable,
- or a mixture.

Traverses projects -> frameworks -> packages (top-level and optionally transitive) -> vulnerabilities.
Aggregates results (by Project, Package, ResolvedVersion, and optionally PackageType) when requested.
Supports whitelist/blacklist filtering and emits text or markdown with an optional title.
If -ExitOnVulnerability is set and any vulnerability is found, the function throws (no 'exit').

.PARAMETER jsonInput
Object array where each element is either:
- a full JSON string,
- lines forming one JSON,
- an already-parsed PSCustomObject/hashtable,
- or a mixture.

.PARAMETER OutputFile
Optional file path; UTF-8 content is written if provided.

.PARAMETER OutputFormat
'text' or 'markdown'. Default 'text'.

.PARAMETER ExitOnVulnerability
If $true and any vulnerability is found, throws a terminating error after producing the output.

.PARAMETER Aggregate
If $true, aggregate by Project, Package, ResolvedVersion (and optionally PackageType).

.PARAMETER IgnoreTransitivePackages
If $true, ignore transitive packages. Default $true.

.PARAMETER IncludePackageType
If $true and Aggregate is $true, include PackageType column.

.PARAMETER GenerateTitle
If $true, prepend a professional title. (No underline to avoid string length ops.)

.PARAMETER SetMarkDownTitle
Custom markdown H2 when OutputFormat is markdown.

.PARAMETER ProjectWhitelist
Project names (file name without extension) to always include.

.PARAMETER ProjectBlacklist
Project names to exclude unless whitelisted.

.EXAMPLE
# Single full JSON string
New-DotnetVulnerabilitiesReport -jsonInput $json -OutputFormat markdown

.EXAMPLE
# Lines captured from CLI output (joined and parsed)
$lines = dotnet list . package --vulnerable --format json 2>$null | Out-String -Stream
New-DotnetVulnerabilitiesReport -jsonInput $lines -IgnoreTransitivePackages:$false -ExitOnVulnerability:$true

.EXAMPLE
# Write to file
New-DotnetVulnerabilitiesReport -jsonInput $json -OutputFile 'reports/vuln.md' -OutputFormat markdown

.NOTES
- Compatible with Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
- No ShouldProcess; no pipeline-bound params; minimal Write-Host; ASCII-only; no ternary; idempotent.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $jsonInput,

        [string] $OutputFile,
        [ValidateSet("text","markdown")]
        [string] $OutputFormat = "text",

        [bool] $ExitOnVulnerability = $false,
        [bool] $Aggregate = $true,
        [bool] $IgnoreTransitivePackages = $true,
        [bool] $IncludePackageType = $false,
        [bool] $GenerateTitle = $true,
        [string] $SetMarkDownTitle,
        [string[]] $ProjectWhitelist,
        [string[]] $ProjectBlacklist
    )

    # ---------------- helpers (local scope; no pipeline writes) ----------------
    function _ToArray { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([object] $v)
        if ($null -eq $v) { return @() }
        if ($v -is [System.Array]) { return $v }
        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
            $tmp = New-Object 'System.Collections.Generic.List[object]'
            foreach ($e in $v) { [void]$tmp.Add($e) }
            return $tmp.ToArray()
        }
        return ,$v
    }
    function _StripBom { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $t)
        if ([string]::IsNullOrEmpty($t)) { return "" }
        if ($t[0] -eq [char]0xFEFF) { return $t.Substring(1) }
        return $t
    }
    function _UnwrapQuotes { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $t)
        if ([string]::IsNullOrEmpty($t)) { return "" }
        $s = $t.Trim()
        if ($s.StartsWith('"') -and $s.EndsWith('"')) { return $s.Substring(1, $s.Length-2) }
        return $s
    }
    function _TryFromJson { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $text)
        try { return (ConvertFrom-Json -InputObject $text) } catch { return $null }
    }
    function _CoerceDocs { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([object[]] $items)
        $docs = New-Object 'System.Collections.Generic.List[object]'
        $arr  = _ToArray $items

        # Single-element fast path
        $hasOne = $false; $e = $null
        foreach ($x in $arr) { $e = $x; $hasOne = $true; break }
        if ($hasOne) {
            if ($e -is [string]) {
                $s = _UnwrapQuotes (_StripBom ([string]$e))
                $p = _TryFromJson $s
                if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
                $p = _TryFromJson (($s -split "(`r`n|`n|`r)") -join "`n")
                if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
                throw "Failed to parse JSON input. Provide a complete JSON document."
            } elseif ($e -is [System.Collections.IDictionary] -or $null -ne $e.PSObject) {
                [void]$docs.Add($e); return $docs.ToArray()
            }
        }

        # All strings -> join once
        $allStr = $true
        foreach ($x in $arr) { if (-not ($x -is [string])) { $allStr = $false; break } }
        if ($allStr) {
            $joined = _UnwrapQuotes (_StripBom ([string]::Join("`n", (_ToArray $arr))))
            $p = _TryFromJson $joined
            if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
            # Fallback: per-line parse
            $any = $false
            foreach ($ln in (_ToArray $arr)) {
                $q = _TryFromJson (_UnwrapQuotes (_StripBom ([string]$ln)))
                if ($null -ne $q) { [void]$docs.Add($q); $any = $true }
            }
            if ($any) { return $docs.ToArray() }
            throw "Failed to parse JSON from lines; ensure they form one complete document."
        }

        # Mixed: accept already-parsed and self-parsing strings
        foreach ($x in $arr) {
            if ($x -is [string]) {
                $p = _TryFromJson (_UnwrapQuotes (_StripBom ([string]$x)))
                if ($null -ne $p) { [void]$docs.Add($p) }
            } elseif ($x -is [System.Collections.IDictionary] -or $null -ne $x.PSObject) {
                [void]$docs.Add($x)
            }
        }
        if ((_ToArray $docs).Length -gt 0) { return $docs.ToArray() }
        throw "Failed to coerce input into JSON documents."
    }

    # ---------------- parse input ----------------
    $docs = _CoerceDocs -items $jsonInput

    # ---------------- traverse & collect ----------------
    $rowsList    = New-Object 'System.Collections.Generic.List[psobject]'
    $allProjects = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($doc in $docs) {
        foreach ($proj in @($doc.projects)) {
            if ($null -eq $proj) { continue }
            $projPath = [string]$proj.path
            if (-not [string]::IsNullOrEmpty($projPath)) {
                [void]$allProjects.Add([System.IO.Path]::GetFileNameWithoutExtension($projPath))
            }

            foreach ($fw in @($proj.frameworks)) {
                if ($null -eq $fw) { continue }
                $fwName = $fw.framework

                # Top-level packages
                foreach ($pkg in @($fw.topLevelPackages)) {
                    if ($null -eq $pkg) { continue }
                    $vulns = @($pkg.vulnerabilities)
                    $hasV = $false
                    foreach ($v in $vulns) { $hasV = $true; break }
                    if ($hasV) {
                        foreach ($v in $vulns) {
                            # AdvisoryUrl appears as 'advisoryurl' in some outputs; support both
                            $adv = $v.advisoryUrl
                            if ([string]::IsNullOrEmpty($adv)) { $adv = $v.advisoryurl }
                            [void]$rowsList.Add([PSCustomObject]@{
                                Project         = [System.IO.Path]::GetFileNameWithoutExtension($projPath)
                                Framework       = $fwName
                                Package         = $pkg.id
                                ResolvedVersion = $pkg.resolvedVersion
                                Severity        = $v.severity
                                AdvisoryUrl     = $adv
                                PackageType     = 'TopLevel'
                            })
                        }
                    }
                }

                # Transitive packages (optional)
                if (-not $IgnoreTransitivePackages) {
                    foreach ($pkg in @($fw.transitivePackages)) {
                        if ($null -eq $pkg) { continue }
                        $vulns = @($pkg.vulnerabilities)
                        $hasV = $false
                        foreach ($v in $vulns) { $hasV = $true; break }
                        if ($hasV) {
                            foreach ($v in $vulns) {
                                $adv = $v.advisoryUrl
                                if ([string]::IsNullOrEmpty($adv)) { $adv = $v.advisoryurl }
                                [void]$rowsList.Add([PSCustomObject]@{
                                    Project         = [System.IO.Path]::GetFileNameWithoutExtension($projPath)
                                    Framework       = $fwName
                                    Package         = $pkg.id
                                    ResolvedVersion = $pkg.resolvedVersion
                                    Severity        = $v.severity
                                    AdvisoryUrl     = $adv
                                    PackageType     = 'Transitive'
                                })
                            }
                        }
                    }
                }
            }
        }
    }

    # Materialize
    $rows = @($rowsList)

    # ---------------- whitelist/blacklist ----------------
    if (($null -ne $ProjectWhitelist) -or ($null -ne $ProjectBlacklist)) {
        $tmp = New-Object 'System.Collections.Generic.List[psobject]'
        foreach ($r in $rows) {
            $incl = $true
            if (($null -ne $ProjectWhitelist) -and ($ProjectWhitelist -contains $r.Project)) { $incl = $true }
            elseif (($null -ne $ProjectBlacklist) -and ($ProjectBlacklist -contains $r.Project)) { $incl = $false }
            else { $incl = $true }
            if ($incl) { [void]$tmp.Add($r) }
        }
        $rows = @($tmp)
    }

    # ---------------- aggregate ----------------
    if ($Aggregate) {
        $map = @{}
        if ($IncludePackageType) {
            foreach ($r in $rows) {
                $k = ('{0}||{1}||{2}||{3}' -f $r.Project, $r.Package, $r.ResolvedVersion, $r.PackageType)
                if (-not $map.ContainsKey($k)) {
                    $map[$k] = [PSCustomObject]@{
                        Project         = $r.Project
                        Package         = $r.Package
                        ResolvedVersion = $r.ResolvedVersion
                        PackageType     = $r.PackageType
                        Severity        = $r.Severity
                        AdvisoryUrl     = $r.AdvisoryUrl
                    }
                }
            }
        } else {
            foreach ($r in $rows) {
                $k = ('{0}||{1}||{2}' -f $r.Project, $r.Package, $r.ResolvedVersion)
                if (-not $map.ContainsKey($k)) {
                    $map[$k] = [PSCustomObject]@{
                        Project         = $r.Project
                        Package         = $r.Package
                        ResolvedVersion = $r.ResolvedVersion
                        Severity        = $r.Severity
                        AdvisoryUrl     = $r.AdvisoryUrl
                    }
                }
            }
        }
        $vals = New-Object 'System.Collections.Generic.List[psobject]'
        foreach ($v in $map.Values) { [void]$vals.Add($v) }
        $rows = @($vals)
    }

    # ---------------- body ----------------
    $hasRows = $false; foreach ($x in $rows) { $hasRows = $true; break }
    $body = ""
    if ($OutputFormat -eq "text") {
        if ($hasRows) {
            if ($Aggregate) {
                if ($IncludePackageType) {
                    $body = ($rows | Format-Table Project, Package, ResolvedVersion, PackageType, Severity, AdvisoryUrl -AutoSize | Out-String)
                } else {
                    $body = ($rows | Format-Table Project, Package, ResolvedVersion, Severity, AdvisoryUrl -AutoSize | Out-String)
                }
            } else {
                $body = ($rows | Format-Table Project, Framework, Package, ResolvedVersion, PackageType, Severity, AdvisoryUrl -AutoSize | Out-String)
            }
        } else {
            $body = "No vulnerabilities found."
        }
    } else {
        if ($hasRows) {
            $md = New-Object 'System.Collections.Generic.List[string]'
            if ($Aggregate) {
                if ($IncludePackageType) {
                    [void]$md.Add("| Project | Package | ResolvedVersion | PackageType | Severity | AdvisoryUrl |")
                    [void]$md.Add("|---------|---------|-----------------|-------------|----------|-------------|")
                    foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f $it.Project,$it.Package,$it.ResolvedVersion,$it.PackageType,$it.Severity,$it.AdvisoryUrl)) }
                } else {
                    [void]$md.Add("| Project | Package | ResolvedVersion | Severity | AdvisoryUrl |")
                    [void]$md.Add("|---------|---------|-----------------|----------|-------------|")
                    foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} |" -f $it.Project,$it.Package,$it.ResolvedVersion,$it.Severity,$it.AdvisoryUrl)) }
                }
            } else {
                [void]$md.Add("| Project | Framework | Package | ResolvedVersion | PackageType | Severity | AdvisoryUrl |")
                [void]$md.Add("|---------|-----------|---------|-----------------|-------------|----------|-------------|")
                foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f $it.Project,$it.Framework,$it.Package,$it.ResolvedVersion,$it.PackageType,$it.Severity,$it.AdvisoryUrl)) }
            }
            $body = [string]::Join("`n", $md.ToArray())
        } else {
            $body = "No vulnerabilities found."
        }
    }

    # ---------------- title ----------------
    $projectsForTitle = New-Object 'System.Collections.Generic.List[string]'
    if ($hasRows) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in $rows) { if ($seen.Add($r.Project)) { [void]$projectsForTitle.Add($r.Project) } }
        $projectsForTitle.Sort()
    } else {
        $nameList = New-Object 'System.Collections.Generic.List[string]'
        foreach ($n in $allProjects) { if (-not [string]::IsNullOrEmpty($n)) { [void]$nameList.Add([string]$n) } }
        $nameList.Sort()
        $names = $nameList.ToArray()
        foreach ($name in $names) {
            $incl = $true
            if (($null -ne $ProjectWhitelist) -and ($ProjectWhitelist -contains $name)) { $incl = $true }
            elseif (($null -ne $ProjectBlacklist) -and ($ProjectBlacklist -contains $name)) { $incl = $false }
            else { $incl = $true }
            if ($incl) { [void]$projectsForTitle.Add($name) }
        }
    }

    $projectsStr = "None"; $anyProj = $false; foreach ($p in $projectsForTitle) { $anyProj = $true; break }
    if ($anyProj) { $projectsStr = ($projectsForTitle -join ", ") }
    $defaultTitle = ("Vulnerabilities Report for Projects: {0}" -f $projectsStr)

    $prefix = ""
    if ($GenerateTitle) {
        if ($OutputFormat -eq "markdown") {
            if ([string]::IsNullOrEmpty($SetMarkDownTitle)) { $prefix = "## $defaultTitle`n`n" } else { $prefix = "## $SetMarkDownTitle`n`n" }
        } else {
            $prefix = "$defaultTitle`n`n"
        }
    }

    $final = $prefix + $body

    # ---------------- write or return ----------------
    if (-not [string]::IsNullOrEmpty($OutputFile)) {
        $normalized = $OutputFile -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
        $dir = Split-Path -Path $normalized -Parent
        if (-not [string]::IsNullOrEmpty($dir)) {
            if (-not (Test-Path -Path $dir)) {
                [void][System.IO.Directory]::CreateDirectory($dir)
                Write-Host ("Created directory: {0}" -f $dir)
            }
        }
        [System.IO.File]::WriteAllText($normalized, $final, [System.Text.Encoding]::UTF8)
        Write-Host ("Output written to {0}" -f $normalized)
    } else {
        return $final
    }

    if ($hasRows -and $ExitOnVulnerability) {
        Write-Host "Vulnerabilities detected. Throwing as configured."
        throw "Vulnerabilities detected."
    } elseif ($hasRows) {
        Write-Host "Vulnerabilities detected, but not failing due to configuration."
    }
}

function New-DotnetDeprecatedReport {
<#
.SYNOPSIS
Generate a deprecation report from one or more 'dotnet ... --deprecated --format json' documents (StrictMode-safe).

.DESCRIPTION
Accepts input as a complete JSON string, an array of lines (auto-joined), an already-parsed PSCustomObject/hashtable,
or a mixture. Safely handles missing 'frameworks' or package arrays. Aggregates deprecated packages, supports whitelist/blacklist,
and emits text or markdown. No reliance on .Count/.Length for unknown types; everything is enumerated defensively.

.PARAMETER jsonInput
Array whose elements can be:
- a complete JSON string,
- lines that together form one JSON document,
- an already-parsed object,
- or a mixture of the above.

.PARAMETER OutputFile
Optional file path to save UTF-8 output.

.PARAMETER OutputFormat
'text' or 'markdown'. Default 'text'.

.PARAMETER ExitOnDeprecated
If $true and any deprecated package is found, throws.

.PARAMETER Aggregate
If $true, aggregate by Project, Package, ResolvedVersion (and optionally PackageType).

.PARAMETER IgnoreTransitivePackages
If $true, ignore transitive packages. Default $true.

.PARAMETER IncludePackageType
If $true and Aggregate is $true, include PackageType column.

.PARAMETER GenerateTitle
If $true, prepend a professional title.

.PARAMETER SetMarkDownTitle
Optional custom markdown title (only when OutputFormat is markdown).

.PARAMETER ProjectWhitelist
Project names (file name without extension) to always include.

.PARAMETER ProjectBlacklist
Project names to exclude unless whitelisted.

.NOTES
PS5/5.1 and PS7+ on Windows/macOS/Linux. No ShouldProcess; no pipeline-bound params.
No Write-Output/Write-Error/Write-Verbose/Write-Information. Minimal Write-Host only for key actions.
ASCII-only. Idempotent. No ternary. No automatic/reserved vars used.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [object[]] $jsonInput,

        [string] $OutputFile,
        [ValidateSet("text","markdown")]
        [string] $OutputFormat = "text",
        [bool] $ExitOnDeprecated = $false,
        [bool] $Aggregate = $true,
        [bool] $IgnoreTransitivePackages = $true,
        [bool] $IncludePackageType = $false,
        [bool] $GenerateTitle = $true,
        [string] $SetMarkDownTitle,
        [string[]] $ProjectWhitelist,
        [string[]] $ProjectBlacklist
    )

    # ----------------- helpers (local scope; no pipeline writes) -----------------
    function _ToArray { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([object] $v)
        if ($null -eq $v) { return @() }
        if ($v -is [System.Array]) { return $v }
        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
            $tmp = New-Object 'System.Collections.Generic.List[object]'
            foreach ($e in $v) { [void]$tmp.Add($e) }
            return $tmp.ToArray()
        }
        return ,$v
    }
    function _StripBom { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $t)
        if ([string]::IsNullOrEmpty($t)) { return "" }
        if ($t[0] -eq [char]0xFEFF) { return $t.Substring(1) }
        return $t
    }
    function _UnwrapQuotes { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $t)
        if ([string]::IsNullOrEmpty($t)) { return "" }
        $s = $t.Trim()
        if ($s.StartsWith('"') -and $s.EndsWith('"')) { return $s.Substring(1, $s.Length-2) }
        return $s
    }
    function _TryFromJson { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $text)
        try { return (ConvertFrom-Json -InputObject $text) } catch { return $null }
    }
    function _CoerceDocs { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([object[]] $items)
        $docs = New-Object 'System.Collections.Generic.List[object]'
        $arr  = _ToArray $items
        # single element fast path
        $one = $false; $elem = $null
        foreach ($x in $arr) { $elem = $x; $one = $true; break }
        if ($one) {
            if ($elem -is [string]) {
                $s = _UnwrapQuotes (_StripBom ([string]$elem))
                $p = _TryFromJson $s
                if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
                $p = _TryFromJson (($s -split "(`r`n|`n|`r)") -join "`n")
                if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
                throw "Failed to parse JSON input. Provide a complete JSON document."
            } elseif ($elem -is [System.Collections.IDictionary] -or $null -ne $elem.PSObject) {
                [void]$docs.Add($elem); return $docs.ToArray()
            }
        }
        # all strings -> join as one
        $allStr = $true
        foreach ($x in $arr) { if (-not ($x -is [string])) { $allStr = $false; break } }
        if ($allStr) {
            $joined = _UnwrapQuotes (_StripBom ([string]::Join("`n", (_ToArray $arr))))
            $p = _TryFromJson $joined
            if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
            $any = $false
            foreach ($ln in (_ToArray $arr)) {
                $q = _TryFromJson (_UnwrapQuotes (_StripBom ([string]$ln)))
                if ($null -ne $q) { [void]$docs.Add($q); $any = $true }
            }
            if ($any) { return $docs.ToArray() }
            throw "Failed to parse JSON from lines; ensure they form one complete document."
        }
        # mixed: accept already-parsed and parsable strings
        foreach ($x in $arr) {
            if ($x -is [string]) {
                $p = _TryFromJson (_UnwrapQuotes (_StripBom ([string]$x)))
                if ($null -ne $p) { [void]$docs.Add($p) }
            } elseif ($x -is [System.Collections.IDictionary] -or $null -ne $x.PSObject) {
                [void]$docs.Add($x)
            }
        }
        if ((_ToArray $docs).GetType().IsArray -or (_ToArray $docs).Length -gt 0) { return $docs.ToArray() }
        throw "Failed to coerce input into JSON documents."
    }

    # ----------------- parse input -----------------
    $docs = _CoerceDocs -items $jsonInput

    # ----------------- traverse and collect rows -----------------
    $rowsList    = New-Object 'System.Collections.Generic.List[psobject]'
    $allProjects = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($doc in $docs) {
        $projects = @($doc.projects)
        foreach ($proj in $projects) {
            if ($null -eq $proj) { continue }
            $projPath = [string]$proj.path
            if (-not [string]::IsNullOrEmpty($projPath)) {
                [void]$allProjects.Add([System.IO.Path]::GetFileNameWithoutExtension($projPath))
            }

            foreach ($fw in @($proj.frameworks)) {
                if ($null -eq $fw) { continue }
                $fwName = $fw.framework

                # top-level
                foreach ($pkg in @($fw.topLevelPackages)) {
                    if ($null -eq $pkg) { continue }
                    $hasReasons = $false
                    foreach ($r in @($pkg.deprecationReasons)) { $hasReasons = $true; break }
                    if ($hasReasons) {
                        [void]$rowsList.Add([PSCustomObject]@{
                            Project            = [System.IO.Path]::GetFileNameWithoutExtension($projPath)
                            Framework          = $fwName
                            Package            = $pkg.id
                            ResolvedVersion    = $pkg.resolvedVersion
                            DeprecationReasons = ([string]::Join(", ", @($pkg.deprecationReasons)))
                            PackageType        = 'TopLevel'
                        })
                    }
                }

                # transitive (optional)
                if (-not $IgnoreTransitivePackages) {
                    foreach ($pkg in @($fw.transitivePackages)) {
                        if ($null -eq $pkg) { continue }
                        $hasReasons = $false
                        foreach ($r in @($pkg.deprecationReasons)) { $hasReasons = $true; break }
                        if ($hasReasons) {
                            [void]$rowsList.Add([PSCustomObject]@{
                                Project            = [System.IO.Path]::GetFileNameWithoutExtension($projPath)
                                Framework          = $fwName
                                Package            = $pkg.id
                                ResolvedVersion    = $pkg.resolvedVersion
                                DeprecationReasons = ([string]::Join(", ", @($pkg.deprecationReasons)))
                                PackageType        = 'Transitive'
                            })
                        }
                    }
                }
            }
        }
    }

    # materialize
    $rows = @($rowsList)

    # ----------------- whitelist/blacklist -----------------
    if (($null -ne $ProjectWhitelist) -or ($null -ne $ProjectBlacklist)) {
        $tmp = New-Object 'System.Collections.Generic.List[psobject]'
        foreach ($r in $rows) {
            $incl = $true
            if (($null -ne $ProjectWhitelist) -and ($ProjectWhitelist -contains $r.Project)) { $incl = $true }
            elseif (($null -ne $ProjectBlacklist) -and ($ProjectBlacklist -contains $r.Project)) { $incl = $false }
            else { $incl = $true }
            if ($incl) { [void]$tmp.Add($r) }
        }
        $rows = @($tmp)
    }

    # ----------------- aggregate -----------------
    if ($Aggregate) {
        $map = @{}
        if ($IncludePackageType) {
            foreach ($r in $rows) {
                $k = ('{0}||{1}||{2}||{3}' -f $r.Project, $r.Package, $r.ResolvedVersion, $r.PackageType)
                if (-not $map.ContainsKey($k)) {
                    $map[$k] = [PSCustomObject]@{
                        Project            = $r.Project
                        Package            = $r.Package
                        ResolvedVersion    = $r.ResolvedVersion
                        PackageType        = $r.PackageType
                        DeprecationReasons = $r.DeprecationReasons
                    }
                }
            }
        } else {
            foreach ($r in $rows) {
                $k = ('{0}||{1}||{2}' -f $r.Project, $r.Package, $r.ResolvedVersion)
                if (-not $map.ContainsKey($k)) {
                    $map[$k] = [PSCustomObject]@{
                        Project            = $r.Project
                        Package            = $r.Package
                        ResolvedVersion    = $r.ResolvedVersion
                        DeprecationReasons = $r.DeprecationReasons
                    }
                }
            }
        }
        $agg = New-Object 'System.Collections.Generic.List[psobject]'
        foreach ($v in $map.Values) { [void]$agg.Add($v) }
        $rows = @($agg)
    }

    # ----------------- body -----------------
    $hasRows = $false; foreach ($x in $rows) { $hasRows = $true; break }
    $body = ""
    if ($OutputFormat -eq "text") {
        if ($hasRows) {
            if ($Aggregate) {
                if ($IncludePackageType) {
                    $body = ($rows | Format-Table Project, Package, ResolvedVersion, PackageType, DeprecationReasons -AutoSize | Out-String)
                } else {
                    $body = ($rows | Format-Table Project, Package, ResolvedVersion, DeprecationReasons -AutoSize | Out-String)
                }
            } else {
                $body = ($rows | Format-Table Project, Framework, Package, ResolvedVersion, PackageType, DeprecationReasons -AutoSize | Out-String)
            }
        } else {
            $body = "No deprecated packages found."
        }
    } else {
        if ($hasRows) {
            $md = New-Object 'System.Collections.Generic.List[string]'
            if ($Aggregate) {
                if ($IncludePackageType) {
                    [void]$md.Add("| Project | Package | ResolvedVersion | PackageType | DeprecationReasons |")
                    [void]$md.Add("|---------|---------|-----------------|-------------|--------------------|")
                    foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} |" -f $it.Project,$it.Package,$it.ResolvedVersion,$it.PackageType,$it.DeprecationReasons)) }
                } else {
                    [void]$md.Add("| Project | Package | ResolvedVersion | DeprecationReasons |")
                    [void]$md.Add("|---------|---------|-----------------|--------------------|")
                    foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} |" -f $it.Project,$it.Package,$it.ResolvedVersion,$it.DeprecationReasons)) }
                }
            } else {
                [void]$md.Add("| Project | Framework | Package | ResolvedVersion | PackageType | DeprecationReasons |")
                [void]$md.Add("|---------|-----------|---------|-----------------|-------------|--------------------|")
                foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f $it.Project,$it.Framework,$it.Package,$it.ResolvedVersion,$it.PackageType,$it.DeprecationReasons)) }
            }
            $body = [string]::Join("`n", $md.ToArray())
        } else {
            $body = "No deprecated packages found."
        }
    }

    # ----------------- title -----------------
    $projectsForTitle = New-Object 'System.Collections.Generic.List[string]'
    if ($hasRows) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in $rows) { if ($seen.Add($r.Project)) { [void]$projectsForTitle.Add($r.Project) } }
        $projectsForTitle.Sort()
    } else {
        # copy + sort HashSet safely on PS5
        $nameList = New-Object 'System.Collections.Generic.List[string]'
        foreach ($n in $allProjects) { if (-not [string]::IsNullOrEmpty($n)) { [void]$nameList.Add([string]$n) } }
        $nameList.Sort()
        $names = $nameList.ToArray()
        foreach ($name in $names) {
            $incl = $true
            if (($null -ne $ProjectWhitelist) -and ($ProjectWhitelist -contains $name)) { $incl = $true }
            elseif (($null -ne $ProjectBlacklist) -and ($ProjectBlacklist -contains $name)) { $incl = $false }
            else { $incl = $true }
            if ($incl) { [void]$projectsForTitle.Add($name) }
        }
    }

    $projectsStr = "None"; $anyProj = $false; foreach ($p in $projectsForTitle) { $anyProj = $true; break }
    if ($anyProj) { $projectsStr = ($projectsForTitle -join ", ") }
    $defaultTitle = ("Deprecated Packages Report for Projects: {0}" -f $projectsStr)

    $prefix = ""
    if ($GenerateTitle) {
        if ($OutputFormat -eq "markdown") {
            if ([string]::IsNullOrEmpty($SetMarkDownTitle)) { $prefix = "## $defaultTitle`n`n" } else { $prefix = "## $SetMarkDownTitle`n`n" }
        } else {
            $prefix = "$defaultTitle`n`n"  # avoid underline (length ops)
        }
    }

    $final = $prefix + $body

    # ----------------- write or return -----------------
    if (-not [string]::IsNullOrEmpty($OutputFile)) {
        $normalized = $OutputFile -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
        $dir = Split-Path -Path $normalized -Parent
        if (-not [string]::IsNullOrEmpty($dir)) {
            if (-not (Test-Path -Path $dir)) {
                [void][System.IO.Directory]::CreateDirectory($dir)
                Write-Host ("Created directory: {0}" -f $dir)
            }
        }
        [System.IO.File]::WriteAllText($normalized, $final, [System.Text.Encoding]::UTF8)
        Write-Host ("Output written to {0}" -f $normalized)
    } else {
        return $final
    }

    if ($hasRows -and $ExitOnDeprecated) {
        Write-Host "Deprecated packages detected. Throwing as configured."
        throw "Deprecated packages detected."
    } elseif ($hasRows) {
        Write-Host "Deprecated packages detected, but not failing due to configuration."
    }
}

function New-DotnetOutdatedReport {
<#
.SYNOPSIS
Generate an outdated packages report from one or more 'dotnet list ... package --outdated --format json' documents.

.DESCRIPTION
StrictMode-safe parser that accepts:
- a complete JSON string,
- an array of lines forming one JSON document,
- an already-parsed PSCustomObject/hashtable,
- or a mixture.

Traverses projects -> frameworks -> packages (top-level and optionally transitive) and flags items where
resolvedVersion != latestVersion. Aggregates results (by Project, Package, ResolvedVersion, LatestVersion, and
optionally PackageType) when requested. Supports whitelist/blacklist filtering and emits text or markdown with
an optional title. If -ExitOnOutdated is set and any outdated package is found, the function throws (no 'exit').

.PARAMETER jsonInput
Object array where each element is either:
- a full JSON string,
- lines forming one JSON,
- an already-parsed PSCustomObject/hashtable,
- or a mixture.

.PARAMETER OutputFile
Optional file path; UTF-8 content is written if provided.

.PARAMETER OutputFormat
'text' or 'markdown'. Default 'text'.

.PARAMETER ExitOnOutdated
If $true and any outdated package is found, throws a terminating error after producing the output.

.PARAMETER Aggregate
If $true, aggregate by Project, Package, ResolvedVersion, LatestVersion (and optionally PackageType).

.PARAMETER IgnoreTransitivePackages
If $true, ignore transitive packages. Default $true.

.PARAMETER IncludePackageType
If $true and Aggregate is $true, include PackageType column.

.PARAMETER GenerateTitle
If $true, prepend a professional title. (No underline to avoid length ops.)

.PARAMETER SetMarkDownTitle
Custom markdown H2 when OutputFormat is markdown.

.PARAMETER ProjectWhitelist
Project names (file name without extension) to always include.

.PARAMETER ProjectBlacklist
Project names to exclude unless whitelisted.

.EXAMPLE
# Single full JSON string
New-DotnetOutdatedReport -jsonInput $json -OutputFormat markdown

.EXAMPLE
# Lines captured from CLI output (joined and parsed)
$lines = dotnet list . package --outdated --format json 2>$null | Out-String -Stream
New-DotnetOutdatedReport -jsonInput $lines -IgnoreTransitivePackages:$false -ExitOnOutdated:$true

.EXAMPLE
# Write to file
New-DotnetOutdatedReport -jsonInput $json -OutputFile 'reports/outdated.md' -OutputFormat markdown

.NOTES
- Compatible with Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
- No ShouldProcess; no pipeline-bound params; minimal Write-Host; ASCII-only; no ternary; idempotent.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $jsonInput,

        [string] $OutputFile,
        [ValidateSet("text","markdown")]
        [string] $OutputFormat = "text",

        [bool] $ExitOnOutdated = $false,
        [bool] $Aggregate = $true,
        [bool] $IgnoreTransitivePackages = $true,
        [bool] $IncludePackageType = $false,
        [bool] $GenerateTitle = $true,
        [string] $SetMarkDownTitle,
        [string[]] $ProjectWhitelist,
        [string[]] $ProjectBlacklist
    )

    # ---------------- helpers (local scope; no pipeline writes) ----------------
    function _ToArray { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([object] $v)
        if ($null -eq $v) { return @() }
        if ($v -is [System.Array]) { return $v }
        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
            $tmp = New-Object 'System.Collections.Generic.List[object]'
            foreach ($e in $v) { [void]$tmp.Add($e) }
            return $tmp.ToArray()
        }
        return ,$v
    }
    function _StripBom { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $t)
        if ([string]::IsNullOrEmpty($t)) { return "" }
        if ($t[0] -eq [char]0xFEFF) { return $t.Substring(1) }
        return $t
    }
    function _UnwrapQuotes { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $t)
        if ([string]::IsNullOrEmpty($t)) { return "" }
        $s = $t.Trim()
        if ($s.StartsWith('"') -and $s.EndsWith('"')) { return $s.Substring(1, $s.Length-2) }
        return $s
    }
    function _TryFromJson { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $text)
        try { return (ConvertFrom-Json -InputObject $text) } catch { return $null }
    }
    function _CoerceDocs { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([object[]] $items)
        $docs = New-Object 'System.Collections.Generic.List[object]'
        $arr  = _ToArray $items

        # Single-element fast path
        $hasOne = $false; $e = $null
        foreach ($x in $arr) { $e = $x; $hasOne = $true; break }
        if ($hasOne) {
            if ($e -is [string]) {
                $s = _UnwrapQuotes (_StripBom ([string]$e))
                $p = _TryFromJson $s
                if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
                $p = _TryFromJson (($s -split "(`r`n|`n|`r)") -join "`n")
                if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
                throw "Failed to parse JSON input. Provide a complete JSON document."
            } elseif ($e -is [System.Collections.IDictionary] -or $null -ne $e.PSObject) {
                [void]$docs.Add($e); return $docs.ToArray()
            }
        }

        # All strings -> join once
        $allStr = $true
        foreach ($x in $arr) { if (-not ($x -is [string])) { $allStr = $false; break } }
        if ($allStr) {
            $joined = _UnwrapQuotes (_StripBom ([string]::Join("`n", (_ToArray $arr))))
            $p = _TryFromJson $joined
            if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
            # Fallback: per-line parse
            $any = $false
            foreach ($ln in (_ToArray $arr)) {
                $q = _TryFromJson (_UnwrapQuotes (_StripBom ([string]$ln)))
                if ($null -ne $q) { [void]$docs.Add($q); $any = $true }
            }
            if ($any) { return $docs.ToArray() }
            throw "Failed to parse JSON from lines; ensure they form one complete document."
        }

        # Mixed: accept already-parsed and self-parsing strings
        foreach ($x in $arr) {
            if ($x -is [string]) {
                $p = _TryFromJson (_UnwrapQuotes (_StripBom ([string]$x)))
                if ($null -ne $p) { [void]$docs.Add($p) }
            } elseif ($x -is [System.Collections.IDictionary] -or $null -ne $x.PSObject) {
                [void]$docs.Add($x)
            }
        }
        if ((_ToArray $docs).Length -gt 0) { return $docs.ToArray() }
        throw "Failed to coerce input into JSON documents."
    }

    # ---------------- parse input ----------------
    $docs = _CoerceDocs -items $jsonInput

    # ---------------- traverse & collect ----------------
    $rowsList    = New-Object 'System.Collections.Generic.List[psobject]'
    $allProjects = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($doc in $docs) {
        foreach ($proj in @($doc.projects)) {
            if ($null -eq $proj) { continue }
            $projPath = [string]$proj.path
            if (-not [string]::IsNullOrEmpty($projPath)) {
                [void]$allProjects.Add([System.IO.Path]::GetFileNameWithoutExtension($projPath))
            }

            foreach ($fw in @($proj.frameworks)) {
                if ($null -eq $fw) { continue }
                $fwName = $fw.framework

                # Top-level packages
                foreach ($pkg in @($fw.topLevelPackages)) {
                    if ($null -eq $pkg) { continue }
                    $latest   = [string]$pkg.latestVersion
                    $resolved = [string]$pkg.resolvedVersion
                    $hasDelta = (-not [string]::IsNullOrEmpty($latest)) -and ($resolved -ne $latest)
                    if ($hasDelta) {
                        [void]$rowsList.Add([PSCustomObject]@{
                            Project         = [System.IO.Path]::GetFileNameWithoutExtension($projPath)
                            Framework       = $fwName
                            Package         = $pkg.id
                            ResolvedVersion = $resolved
                            LatestVersion   = $latest
                            PackageType     = 'TopLevel'
                        })
                    }
                }

                # Transitive packages (optional)
                if (-not $IgnoreTransitivePackages) {
                    foreach ($pkg in @($fw.transitivePackages)) {
                        if ($null -eq $pkg) { continue }
                        $latest   = [string]$pkg.latestVersion
                        $resolved = [string]$pkg.resolvedVersion
                        $hasDelta = (-not [string]::IsNullOrEmpty($latest)) -and ($resolved -ne $latest)
                        if ($hasDelta) {
                            [void]$rowsList.Add([PSCustomObject]@{
                                Project         = [System.IO.Path]::GetFileNameWithoutExtension($projPath)
                                Framework       = $fwName
                                Package         = $pkg.id
                                ResolvedVersion = $resolved
                                LatestVersion   = $latest
                                PackageType     = 'Transitive'
                            })
                        }
                    }
                }
            }
        }
    }

    # Materialize
    $rows = @($rowsList)

    # ---------------- whitelist/blacklist ----------------
    if (($null -ne $ProjectWhitelist) -or ($null -ne $ProjectBlacklist)) {
        $tmp = New-Object 'System.Collections.Generic.List[psobject]'
        foreach ($r in $rows) {
            $incl = $true
            if (($null -ne $ProjectWhitelist) -and ($ProjectWhitelist -contains $r.Project)) { $incl = $true }
            elseif (($null -ne $ProjectBlacklist) -and ($ProjectBlacklist -contains $r.Project)) { $incl = $false }
            else { $incl = $true }
            if ($incl) { [void]$tmp.Add($r) }
        }
        $rows = @($tmp)
    }

    # ---------------- aggregate ----------------
    if ($Aggregate) {
        $map = @{}
        if ($IncludePackageType) {
            foreach ($r in $rows) {
                $k = ('{0}||{1}||{2}||{3}||{4}' -f $r.Project, $r.Package, $r.ResolvedVersion, $r.LatestVersion, $r.PackageType)
                if (-not $map.ContainsKey($k)) {
                    $map[$k] = [PSCustomObject]@{
                        Project         = $r.Project
                        Package         = $r.Package
                        ResolvedVersion = $r.ResolvedVersion
                        LatestVersion   = $r.LatestVersion
                        PackageType     = $r.PackageType
                    }
                }
            }
        } else {
            foreach ($r in $rows) {
                $k = ('{0}||{1}||{2}||{3}' -f $r.Project, $r.Package, $r.ResolvedVersion, $r.LatestVersion)
                if (-not $map.ContainsKey($k)) {
                    $map[$k] = [PSCustomObject]@{
                        Project         = $r.Project
                        Package         = $r.Package
                        ResolvedVersion = $r.ResolvedVersion
                        LatestVersion   = $r.LatestVersion
                    }
                }
            }
        }
        $vals = New-Object 'System.Collections.Generic.List[psobject]'
        foreach ($v in $map.Values) { [void]$vals.Add($v) }
        $rows = @($vals)
    }

    # ---------------- body ----------------
    $hasRows = $false; foreach ($x in $rows) { $hasRows = $true; break }
    $body = ""
    if ($OutputFormat -eq "text") {
        if ($hasRows) {
            if ($Aggregate) {
                if ($IncludePackageType) {
                    $body = ($rows | Format-Table Project, Package, ResolvedVersion, LatestVersion, PackageType -AutoSize | Out-String)
                } else {
                    $body = ($rows | Format-Table Project, Package, ResolvedVersion, LatestVersion -AutoSize | Out-String)
                }
            } else {
                $body = ($rows | Format-Table Project, Framework, Package, ResolvedVersion, LatestVersion, PackageType -AutoSize | Out-String)
            }
        } else {
            $body = "No outdated packages found."
        }
    } else {
        if ($hasRows) {
            $md = New-Object 'System.Collections.Generic.List[string]'
            if ($Aggregate) {
                if ($IncludePackageType) {
                    [void]$md.Add("| Project | Package | ResolvedVersion | LatestVersion | PackageType |")
                    [void]$md.Add("|---------|---------|-----------------|---------------|-------------|")
                    foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} |" -f $it.Project,$it.Package,$it.ResolvedVersion,$it.LatestVersion,$it.PackageType)) }
                } else {
                    [void]$md.Add("| Project | Package | ResolvedVersion | LatestVersion |")
                    [void]$md.Add("|---------|---------|-----------------|---------------|")
                    foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} |" -f $it.Project,$it.Package,$it.ResolvedVersion,$it.LatestVersion)) }
                }
            } else {
                [void]$md.Add("| Project | Framework | Package | ResolvedVersion | LatestVersion | PackageType |")
                [void]$md.Add("|---------|-----------|---------|-----------------|---------------|-------------|")
                foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f $it.Project,$it.Framework,$it.Package,$it.ResolvedVersion,$it.LatestVersion,$it.PackageType)) }
            }
            $body = [string]::Join("`n", $md.ToArray())
        } else {
            $body = "No outdated packages found."
        }
    }

    # ---------------- title ----------------
    $projectsForTitle = New-Object 'System.Collections.Generic.List[string]'
    if ($hasRows) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in $rows) { if ($seen.Add($r.Project)) { [void]$projectsForTitle.Add($r.Project) } }
        $projectsForTitle.Sort()
    } else {
        # copy + sort HashSet safely on PS5
        $nameList = New-Object 'System.Collections.Generic.List[string]'
        foreach ($n in $allProjects) { if (-not [string]::IsNullOrEmpty($n)) { [void]$nameList.Add([string]$n) } }
        $nameList.Sort()
        $names = $nameList.ToArray()
        foreach ($name in $names) {
            $incl = $true
            if (($null -ne $ProjectWhitelist) -and ($ProjectWhitelist -contains $name)) { $incl = $true }
            elseif (($null -ne $ProjectBlacklist) -and ($ProjectBlacklist -contains $name)) { $incl = $false }
            else { $incl = $true }
            if ($incl) { [void]$projectsForTitle.Add($name) }
        }
    }

    $projectsStr = "None"; $anyProj = $false; foreach ($p in $projectsForTitle) { $anyProj = $true; break }
    if ($anyProj) { $projectsStr = ($projectsForTitle -join ", ") }
    $defaultTitle = ("Outdated Packages Report for Projects: {0}" -f $projectsStr)

    $prefix = ""
    if ($GenerateTitle) {
        if ($OutputFormat -eq "markdown") {
            if ([string]::IsNullOrEmpty($SetMarkDownTitle)) { $prefix = "## $defaultTitle`n`n" } else { $prefix = "## $SetMarkDownTitle`n`n" }
        } else {
            $prefix = "$defaultTitle`n`n"
        }
    }

    $final = $prefix + $body

    # ---------------- write or return ----------------
    if (-not [string]::IsNullOrEmpty($OutputFile)) {
        $normalized = $OutputFile -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
        $dir = Split-Path -Path $normalized -Parent
        if (-not [string]::IsNullOrEmpty($dir)) {
            if (-not (Test-Path -Path $dir)) {
                [void][System.IO.Directory]::CreateDirectory($dir)
                Write-Host ("Created directory: {0}" -f $dir)
            }
        }
        [System.IO.File]::WriteAllText($normalized, $final, [System.Text.Encoding]::UTF8)
        Write-Host ("Output written to {0}" -f $normalized)
    } else {
        return $final
    }

    if ($hasRows -and $ExitOnOutdated) {
        Write-Host "Outdated packages detected. Throwing as configured."
        throw "Outdated packages detected."
    } elseif ($hasRows) {
        Write-Host "Outdated packages detected, but not failing due to configuration."
    }
}

function New-DotnetBillOfMaterialsReport {
<#
.SYNOPSIS
Generate a Bill of Materials (BOM) from one or more 'dotnet list ... --format json' documents.

.DESCRIPTION
StrictMode-safe parser that accepts:
- a complete JSON string,
- an array of lines forming one JSON document,
- an already-parsed PSCustomObject/hashtable,
- or a mixture.

Traverses projects -> frameworks -> packages (top-level and optionally transitive).
Supports whitelist/blacklist, optional aggregation (by ProjectName, Package, ResolvedVersion, and optionally PackageType),
and outputs as text or markdown with an optional title. Idempotent, PS5/PS7-compatible, no pipeline-bound params, no ShouldProcess,
no reliance on .Count/.Length for unknown types, and minimal Write-Host.

.PARAMETER jsonInput
Object array where each element is either:
- a full JSON string,
- lines forming one JSON,
- an already-parsed PSCustomObject/hashtable,
- or a mixture.

.PARAMETER OutputFile
Optional file path; UTF-8 content is written if provided.

.PARAMETER OutputFormat
'text' or 'markdown'. Default 'text'.

.PARAMETER IgnoreTransitivePackages
If $true, exclude transitive packages. Default $true.

.PARAMETER Aggregate
If $true, aggregate by ProjectName, Package, ResolvedVersion (and optionally PackageType). Default $true.

.PARAMETER IncludePackageType
If $true and Aggregate is $true, include PackageType column. Default $false.

.PARAMETER GenerateTitle
If $true, prepend a professional title (no underline to avoid length ops). Default $true.

.PARAMETER SetMarkDownTitle
Custom markdown H2 when OutputFormat is markdown.

.PARAMETER ProjectWhitelist
Project names (file name without extension) to always include.

.PARAMETER ProjectBlacklist
Project names to exclude unless whitelisted.

.EXAMPLE
# Single full JSON string
New-DotnetBillOfMaterialsReport -jsonInput $json -OutputFormat markdown

.EXAMPLE
# Lines captured from CLI output (joined and parsed)
$lines = dotnet list . package --format json 2>$null | Out-String -Stream
New-DotnetBillOfMaterialsReport -jsonInput $lines -IgnoreTransitivePackages:$false

.EXAMPLE
# Write to file
New-DotnetBillOfMaterialsReport -jsonInput $json -OutputFile 'reports/bom.md' -OutputFormat markdown

.NOTES
- Compatible with Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
- No ShouldProcess; no pipeline-bound params; ASCII-only; no ternary; idempotent.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [object[]] $jsonInput,

        [string] $OutputFile,
        [ValidateSet("text","markdown")]
        [string] $OutputFormat = "text",

        [bool] $IgnoreTransitivePackages = $true,
        [bool] $Aggregate = $true,
        [bool] $IncludePackageType = $false,
        [bool] $GenerateTitle = $true,
        [string] $SetMarkDownTitle,
        [string[]] $ProjectWhitelist,
        [string[]] $ProjectBlacklist
    )

    # ---------------- helpers (local scope; no pipeline writes) ----------------
    function _ToArray { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([object] $v)
        if ($null -eq $v) { return @() }
        if ($v -is [System.Array]) { return $v }
        if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
            $tmp = New-Object 'System.Collections.Generic.List[object]'
            foreach ($e in $v) { [void]$tmp.Add($e) }
            return $tmp.ToArray()
        }
        return ,$v
    }
    function _StripBom { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $t)
        if ([string]::IsNullOrEmpty($t)) { return "" }
        if ($t[0] -eq [char]0xFEFF) { return $t.Substring(1) }
        return $t
    }
    function _UnwrapQuotes { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $t)
        if ([string]::IsNullOrEmpty($t)) { return "" }
        $s = $t.Trim()
        if ($s.StartsWith('"') -and $s.EndsWith('"')) { return $s.Substring(1, $s.Length-2) }
        return $s
    }
    function _TryFromJson { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([string] $text)
        try { return (ConvertFrom-Json -InputObject $text) } catch { return $null }
    }
    function _CoerceDocs { [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")] param([object[]] $items)
        $docs = New-Object 'System.Collections.Generic.List[object]'
        $arr  = _ToArray $items

        # Single-element fast path
        $hasOne = $false; $e = $null
        foreach ($x in $arr) { $e = $x; $hasOne = $true; break }
        if ($hasOne) {
            if ($e -is [string]) {
                $s = _UnwrapQuotes (_StripBom ([string]$e))
                $p = _TryFromJson $s
                if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
                $p = _TryFromJson (($s -split "(`r`n|`n|`r)") -join "`n")
                if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
                throw "Failed to parse JSON input. Provide a complete JSON document."
            } elseif ($e -is [System.Collections.IDictionary] -or $null -ne $e.PSObject) {
                [void]$docs.Add($e); return $docs.ToArray()
            }
        }

        # All strings -> join once
        $allStr = $true
        foreach ($x in $arr) { if (-not ($x -is [string])) { $allStr = $false; break } }
        if ($allStr) {
            $joined = _UnwrapQuotes (_StripBom ([string]::Join("`n", (_ToArray $arr))))
            $p = _TryFromJson $joined
            if ($null -ne $p) { [void]$docs.Add($p); return $docs.ToArray() }
            # Fallback: per-line parse
            $any = $false
            foreach ($ln in (_ToArray $arr)) {
                $q = _TryFromJson (_UnwrapQuotes (_StripBom ([string]$ln)))
                if ($null -ne $q) { [void]$docs.Add($q); $any = $true }
            }
            if ($any) { return $docs.ToArray() }
            throw "Failed to parse JSON from lines; ensure they form one complete document."
        }

        # Mixed: accept already-parsed and self-parsing strings
        foreach ($x in $arr) {
            if ($x -is [string]) {
                $p = _TryFromJson (_UnwrapQuotes (_StripBom ([string]$x)))
                if ($null -ne $p) { [void]$docs.Add($p) }
            } elseif ($x -is [System.Collections.IDictionary] -or $null -ne $x.PSObject) {
                [void]$docs.Add($x)
            }
        }
        if ((_ToArray $docs).Length -gt 0) { return $docs.ToArray() }
        throw "Failed to coerce input into JSON documents."
    }

    # ---------------- parse input ----------------
    $docs = _CoerceDocs -items $jsonInput

    # ---------------- traverse & collect ----------------
    $rowsList    = New-Object 'System.Collections.Generic.List[psobject]'
    $allProjects = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($doc in $docs) {
        foreach ($proj in @($doc.projects)) {
            if ($null -eq $proj) { continue }
            $projPath = [string]$proj.path
            if (-not [string]::IsNullOrEmpty($projPath)) {
                [void]$allProjects.Add([System.IO.Path]::GetFileNameWithoutExtension($projPath))
            }

            foreach ($fw in @($proj.frameworks)) {
                if ($null -eq $fw) { continue }
                $fwName = $fw.framework

                # Top-level packages
                foreach ($pkg in @($fw.topLevelPackages)) {
                    if ($null -eq $pkg) { continue }
                    [void]$rowsList.Add([PSCustomObject]@{
                        ProjectName     = [System.IO.Path]::GetFileNameWithoutExtension($projPath)
                        Framework       = $fwName
                        Package         = $pkg.id
                        ResolvedVersion = $pkg.resolvedVersion
                        PackageType     = 'TopLevel'
                    })
                }

                # Transitive packages (optional)
                if (-not $IgnoreTransitivePackages) {
                    foreach ($pkg in @($fw.transitivePackages)) {
                        if ($null -eq $pkg) { continue }
                        [void]$rowsList.Add([PSCustomObject]@{
                            ProjectName     = [System.IO.Path]::GetFileNameWithoutExtension($projPath)
                            Framework       = $fwName
                            Package         = $pkg.id
                            ResolvedVersion = $pkg.resolvedVersion
                            PackageType     = 'Transitive'
                        })
                    }
                }
            }
        }
    }

    # Materialize
    $rows = @($rowsList)

    # ---------------- whitelist/blacklist ----------------
    if (($null -ne $ProjectWhitelist) -or ($null -ne $ProjectBlacklist)) {
        $tmp = New-Object 'System.Collections.Generic.List[psobject]'
        foreach ($r in $rows) {
            $incl = $true
            if (($null -ne $ProjectWhitelist) -and ($ProjectWhitelist -contains $r.ProjectName)) { $incl = $true }
            elseif (($null -ne $ProjectBlacklist) -and ($ProjectBlacklist -contains $r.ProjectName)) { $incl = $false }
            else { $incl = $true }
            if ($incl) { [void]$tmp.Add($r) }
        }
        $rows = @($tmp)
    }

    # ---------------- aggregate ----------------
    if ($Aggregate) {
        $map = @{}
        if ($IncludePackageType) {
            foreach ($r in $rows) {
                $k = ('{0}||{1}||{2}||{3}' -f $r.ProjectName, $r.Package, $r.ResolvedVersion, $r.PackageType)
                if (-not $map.ContainsKey($k)) {
                    $map[$k] = [PSCustomObject]@{
                        ProjectName     = $r.ProjectName
                        Package         = $r.Package
                        ResolvedVersion = $r.ResolvedVersion
                        PackageType     = $r.PackageType
                    }
                }
            }
        } else {
            foreach ($r in $rows) {
                $k = ('{0}||{1}||{2}' -f $r.ProjectName, $r.Package, $r.ResolvedVersion)
                if (-not $map.ContainsKey($k)) {
                    $map[$k] = [PSCustomObject]@{
                        ProjectName     = $r.ProjectName
                        Package         = $r.Package
                        ResolvedVersion = $r.ResolvedVersion
                    }
                }
            }
        }
        $vals = New-Object 'System.Collections.Generic.List[psobject]'
        foreach ($v in $map.Values) { [void]$vals.Add($v) }
        $rows = @($vals)
    }

    # ---------------- body ----------------
    $hasRows = $false; foreach ($x in $rows) { $hasRows = $true; break }
    $body = ""
    if ($OutputFormat -eq "text") {
        if ($hasRows) {
            if ($Aggregate) {
                if ($IncludePackageType) {
                    $body = ($rows | Format-Table ProjectName, Package, ResolvedVersion, PackageType -AutoSize | Out-String)
                } else {
                    $body = ($rows | Format-Table ProjectName, Package, ResolvedVersion -AutoSize | Out-String)
                }
            } else {
                $body = ($rows | Format-Table ProjectName, Framework, Package, ResolvedVersion, PackageType -AutoSize | Out-String)
            }
        } else {
            $body = "No BOM entries found."
        }
    } else {
        if ($hasRows) {
            $md = New-Object 'System.Collections.Generic.List[string]'
            if ($Aggregate) {
                if ($IncludePackageType) {
                    [void]$md.Add("| ProjectName | Package | ResolvedVersion | PackageType |")
                    [void]$md.Add("|-------------|---------|-----------------|-------------|")
                    foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} |" -f $it.ProjectName,$it.Package,$it.ResolvedVersion,$it.PackageType)) }
                } else {
                    [void]$md.Add("| ProjectName | Package | ResolvedVersion |")
                    [void]$md.Add("|-------------|---------|-----------------|")
                    foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} |" -f $it.ProjectName,$it.Package,$it.ResolvedVersion)) }
                }
            } else {
                [void]$md.Add("| ProjectName | Framework | Package | ResolvedVersion | PackageType |")
                [void]$md.Add("|-------------|-----------|---------|-----------------|-------------|")
                foreach ($it in $rows) { [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} |" -f $it.ProjectName,$it.Framework,$it.Package,$it.ResolvedVersion,$it.PackageType)) }
            }
            $body = [string]::Join("`n", $md.ToArray())
        } else {
            $body = "No BOM entries found."
        }
    }

    # ---------------- title ----------------
    $projectsForTitle = New-Object 'System.Collections.Generic.List[string]'
    if ($hasRows) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in $rows) { if ($seen.Add($r.ProjectName)) { [void]$projectsForTitle.Add($r.ProjectName) } }
        $projectsForTitle.Sort()
    } else {
        # copy + sort HashSet safely on PS5
        $nameList = New-Object 'System.Collections.Generic.List[string]'
        foreach ($n in $allProjects) { if (-not [string]::IsNullOrEmpty($n)) { [void]$nameList.Add([string]$n) } }
        $nameList.Sort()
        $names = $nameList.ToArray()
        foreach ($name in $names) {
            $incl = $true
            if (($null -ne $ProjectWhitelist) -and ($ProjectWhitelist -contains $name)) { $incl = $true }
            elseif (($null -ne $ProjectBlacklist) -and ($ProjectBlacklist -contains $name)) { $incl = $false }
            else { $incl = $true }
            if ($incl) { [void]$projectsForTitle.Add($name) }
        }
    }

    $projectsStr = "None"; $anyProj = $false; foreach ($p in $projectsForTitle) { $anyProj = $true; break }
    if ($anyProj) { $projectsStr = ($projectsForTitle -join ", ") }
    $defaultTitle = ("Bill of Materials Report for Projects: {0}" -f $projectsStr)

    $prefix = ""
    if ($GenerateTitle) {
        if ($OutputFormat -eq "markdown") {
            if ([string]::IsNullOrEmpty($SetMarkDownTitle)) { $prefix = "## $defaultTitle`n`n" } else { $prefix = "## $SetMarkDownTitle`n`n" }
        } else {
            $prefix = "$defaultTitle`n`n"
        }
    }

    $final = $prefix + $body

    # ---------------- write or return ----------------
    if (-not [string]::IsNullOrEmpty($OutputFile)) {
        $normalized = $OutputFile -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
        $dir = Split-Path -Path $normalized -Parent
        if (-not [string]::IsNullOrEmpty($dir)) {
            if (-not (Test-Path -Path $dir)) {
                [void][System.IO.Directory]::CreateDirectory($dir)
                Write-Host ("Created directory: {0}" -f $dir)
            }
        }
        [System.IO.File]::WriteAllText($normalized, $final, [System.Text.Encoding]::UTF8)
        Write-Host ("Output written to {0}" -f $normalized)
    } else {
        return $final
    }
}


function New-ThirdPartyNotice {
<#
.SYNOPSIS
Creates or updates a THIRD-PARTY-NOTICES.txt from a NuGet license JSON.

.DESCRIPTION
Reads a JSON file produced by a license tool (e.g., 'dotnet nuget-license') and writes a
structured THIRD-PARTY-NOTICES.txt. The function is idempotent: if the target content would
be identical, it does not rewrite the file. If any package contains ValidationErrors, the
function throws with a concise, actionable message.

.PARAMETER LicenseJsonPath
Path to the input JSON file containing NuGet license information.

.PARAMETER OutputPath
Path to the THIRD-PARTY-NOTICES.txt to create or update.

.PARAMETER Name
Optional project or product name to display in the header title after "THIRD-PARTY LICENSE NOTICES".

.EXAMPLE
New-ThirdPartyNotice -LicenseJsonPath 'licenses.json' -OutputPath 'THIRD-PARTY-NOTICES.txt'
Creates or updates the notice file based on licenses.json.

.EXAMPLE
New-ThirdPartyNotice -LicenseJsonPath '.\artifacts\licenses.json' -OutputPath '.\THIRD-PARTY-NOTICES.txt'
Uses custom input and output paths.

.EXAMPLE
New-ThirdPartyNotice -Name 'Contoso App'
Adds a name into the header title.

.EXAMPLE
# Idempotent run. When there is no content change, nothing is rewritten.
New-ThirdPartyNotice
# Logs: [YYYY-MM-DD HH:MM:SS:fff INF] [New-ThirdPartyNotice.ps1] [New-ThirdPartyNotice] No changes: 'THIRD-PARTY-NOTICES.txt' is already up to date.

.NOTES
- Compatible with Windows PowerShell 5/5.1 and PowerShell 7+ on Windows/macOS/Linux.
- Logging uses the inline exception helper _Write-StandardMessage (TRC/DBG/INF/WRN/ERR/FTL).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $LicenseJsonPath = 'licenses.json',

        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath = 'THIRD-PARTY-NOTICES.txt',

        # Optional; allow empty to keep behavior unchanged when omitted.
        [Parameter(Mandatory=$false)]
        [string] $Name = ''
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
        if (-not $PSBoundParameters.ContainsKey('MinLevel')) { $MinLevel = if ($Global:ConsoleLogMinLevel) { $Global:ConsoleLogMinLevel } else { 'INF' } }
        $sevMap = @{ TRC=0; DBG=1; INF=2; WRN=3; ERR=4; FTL=5 }
        $lvl = $Level.ToUpperInvariant() ; $min = $MinLevel.ToUpperInvariant() ; $sev = $sevMap[$lvl] ; $gate= $sevMap[$min]
        if ($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4) { $lvl = $min ; $sev = $gate}
        if ($sev -lt $gate) { return }
        $ts = ([DateTime]::UtcNow).ToString('yyyy-MM-dd HH:mm:ss:fff')
        $stack      = Get-PSCallStack
        $helperName = $MyInvocation.MyCommand.Name
        $orgFunc    = $null
        $caller     = $null
        if ($stack) {
            $orgIdx = -1;
            for ($i = 0; $i -lt $stack.Count; $i++) { if ($stack[$i].FunctionName -ne $helperName) { $orgFunc = $stack[$i]; $orgIdx = $i; break; }}
            if ($orgIdx -ge 0) { $callerIdx = $orgIdx + 1; if ($stack.Count -gt $callerIdx) { $caller = $stack[$callerIdx]; } else { $caller = $orgFunc; } }
        }
        if (-not $caller) { $caller = [pscustomobject]@{ ScriptName = $PSCommandPath; FunctionName = '<scriptblock>' }; }
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

    function _Has-Prop {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [object] $Obj,
            [string] $Name
        )
        if ($null -eq $Obj) { return $false }
        $props = $Obj.PSObject.Properties
        if ($null -eq $props) { return $false }
        return ($props.Name -contains $Name)
    }

    function _Get-Prop {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [object] $Obj,
            [string] $Name,
            [string] $Default = ''
        )
        if ($null -eq $Obj) { return $Default }
        $props = $Obj.PSObject.Properties
        if ($null -eq $props) { return $Default }
        if ($props.Name -contains $Name) {
            $value = $Obj.$Name
            if ($null -ne $value) { return $value }
        }
        return $Default
    }

    function _Normalize-NewLines {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([string] $Text)
        if ($null -eq $Text) { return '' }
        $n = $Text -replace "`r`n", "`n"
        $n = $n -replace "`r", "`n"
        return $n
    }

    # ---------------- Main logic (StrictMode-safe) ----------------

    if (-not (Test-Path -LiteralPath $LicenseJsonPath -PathType Leaf)) {
        throw "License JSON file not found at '$LicenseJsonPath'. Generate it first (e.g., with 'dotnet nuget-license') and try again."
    }

    $rawJson = Get-Content -LiteralPath $LicenseJsonPath -Raw
    try {
        $licenses = ConvertFrom-Json -InputObject $rawJson
    } catch {
        throw "Invalid JSON in '$LicenseJsonPath'. Ensure it contains valid license data."
    }

    # Accept either array root or object.Packages.
    $packages = @()
    if (_Has-Prop -Obj $licenses -Name 'Packages') {
        $packages = @($licenses.Packages)
    } else {
        $packages = @($licenses)
    }

    # Deterministic ordering ensures idempotent output.
    $packages = $packages | Sort-Object -Property PackageId, PackageVersion

    # Header (ASCII).
    $lines = @()
    $lines += '==================================================================='
    $headerTitle = 'THIRD-PARTY LICENSE NOTICES'
    if ($Name) { $headerTitle = "$headerTitle - $Name" }
    $lines += $headerTitle
    $lines += '==================================================================='
    $lines += ''
    if ($packages.Count -eq 0) {
        # Show explicit information when no third-party licenses/packages are present.
        $lines += 'No third-party licenses used.'
    } else {
        $lines += 'This project includes third-party libraries under open-source licenses.'
    }
    $lines += ''

    # Collect validation errors then fail once.
    $errorsFound = @()

    foreach ($pkg in $packages) {
        $validationList = @()
        if (_Has-Prop -Obj $pkg -Name 'ValidationErrors') {
            $ve = $pkg.ValidationErrors
            if ($null -ne $ve) { $validationList = @($ve) }
        }

        if ($validationList.Count -gt 0) {
            $pkgId  = _Get-Prop -Obj $pkg -Name 'PackageId' -Default '<unknown>'
            $pkgVer = _Get-Prop -Obj $pkg -Name 'PackageVersion' -Default '<unknown>'
            foreach ($msg in $validationList) {
                $errorsFound += ('[{0} {1}] {2}' -f $pkgId, $pkgVer, $msg)
            }
            continue
        }

        # Extract fields safely.
        $name    = _Get-Prop -Obj $pkg -Name 'PackageId' -Default ''
        $version = _Get-Prop -Obj $pkg -Name 'PackageVersion' -Default ''
        $license = _Get-Prop -Obj $pkg -Name 'License' -Default ''
        $url     = _Get-Prop -Obj $pkg -Name 'LicenseUrl' -Default ''
        $authors = _Get-Prop -Obj $pkg -Name 'Authors' -Default ''
        $projUrl = _Get-Prop -Obj $pkg -Name 'PackageProjectUrl' -Default ''

        # Section (ASCII-only).
        $lines += '--------------------------------------------'
        if ($name -ne '') {
            if ($version -ne '') {
                $lines += ('Package: {0} (v{1})' -f $name, $version)
            } else {
                $lines += ('Package: {0}' -f $name)
            }
        }
        if ($license -ne '') { $lines += ('License: {0}' -f $license) }
        if ($url -ne '')     { $lines += ('License URL: {0}' -f $url) }
        if ($authors -ne '') { $lines += ('Authors: {0}' -f $authors) }
        if ($projUrl -ne '') { $lines += ('Project: {0}' -f $projUrl) }
        $lines += '--------------------------------------------'
        $lines += ''
    }

    if ($errorsFound.Count -gt 0) {
        $msg = 'License validation errors were detected:' + [Environment]::NewLine + ($errorsFound -join [Environment]::NewLine)
        throw $msg
    }

    # Idempotent write (compare normalized text only).
    $newContent = ($lines -join [Environment]::NewLine)

    $existed = Test-Path -LiteralPath $OutputPath -PathType Leaf
    $needsWrite = $true
    if ($existed) {
        $existing = Get-Content -LiteralPath $OutputPath -Raw
        if (_Normalize-NewLines -Text $existing -eq (_Normalize-NewLines -Text $newContent)) {
            $needsWrite = $false
        }
    }

    if ($needsWrite) {
        $parent = Split-Path -Path $OutputPath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }

        Set-Content -LiteralPath $OutputPath -Value $newContent -Encoding utf8
        if ($existed) {
            _Write-StandardMessage -Message ("Updated: {0}" -f $OutputPath) -Level 'INF'
        } else {
            _Write-StandardMessage -Message ("Created: {0}" -f $OutputPath) -Level 'INF'
        }
    } else {
        _Write-StandardMessage -Message ("No changes: '{0}' is already up to date." -f $OutputPath) -Level 'INF'
    }
}

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

function New-DotnetBillOfMaterialsReport {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Array of JSON strings output from dotnet list command.")]
        [string[]]$jsonInput,

        [Parameter(Mandatory = $false, HelpMessage = "Optional file path to save the output.")]
        [string]$OutputFile,

        [Parameter(Mandatory = $false, HelpMessage = "Output format: 'text' or 'markdown'. Defaults to 'text'.")]
        [ValidateSet("text", "markdown")]
        [string]$OutputFormat = "text",

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, transitive packages are ignored. Defaults to true.")]
        [bool]$IgnoreTransitivePackages = $true,

        [Parameter(Mandatory = $false, HelpMessage = "Aggregates the output by grouping on ProjectName, Package, and ResolvedVersion, and optionally PackageType. Defaults to true.")]
        [bool]$Aggregate = $true,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, the aggregated output includes PackageType. Defaults to false.")]
        [bool]$IncludePackageType = $false,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, a professional title is generated and prepended to the output. Defaults to true.")]
        [bool]$GenerateTitle = $true,

        [Parameter(Mandatory = $false, HelpMessage = "Overrides the generated markdown title with a custom title. Only applied when OutputFormat is markdown.")]
        [string]$SetMarkDownTitle,

        [Parameter(Mandatory = $false, HelpMessage = "Array of ProjectNames to always include in the output.")]
        [string[]]$ProjectWhitelist,

        [Parameter(Mandatory = $false, HelpMessage = "Array of ProjectNames to exclude from the output unless they are also in the whitelist.")]
        [string[]]$ProjectBlacklist
    )

    <#
    .SYNOPSIS
    Generates a professional Bill of Materials (BOM) report from dotnet list JSON output.

    .DESCRIPTION
    Processes JSON input from the dotnet list command to extract project, framework, and package information.
    Each package entry is tagged as "TopLevel" or "Transitive". Optionally, transitive packages can be ignored.
    The function supports aggregation, which groups entries by ProjectName, Package, and ResolvedVersion (and optionally PackageType).
    Additionally, a professional title is generated (if enabled via -GenerateTitle) that lists the projects included in the report.
    When OutputFormat is markdown, the title is rendered as an H2 header, or can be overridden via -SetMarkDownTitle.
    BOM entries can also be filtered using project whitelist and blacklist parameters.

    .PARAMETER jsonInput
    Array of JSON strings output from the dotnet list command.

    .PARAMETER OutputFile
    Optional file path to save the output.

    .PARAMETER OutputFormat
    Specifies the output format: 'text' or 'markdown'. Defaults to 'text'.

    .PARAMETER IgnoreTransitivePackages
    When set to $true, transitive packages are ignored. Defaults to $true.

    .PARAMETER Aggregate
    When set to $true, aggregates the output by grouping on ProjectName, Package, and ResolvedVersion,
    and optionally PackageType (based on IncludePackageType). Defaults to $true.

    .PARAMETER IncludePackageType
    When set to $true, the aggregated output includes PackageType. Defaults to $false.

    .PARAMETER GenerateTitle
    When set to $true, a professional title including project names is generated and prepended to the output.
    Defaults to $true.

    .PARAMETER SetMarkDownTitle
    Overrides the generated markdown title with a custom title. Only applied when OutputFormat is markdown.

    .PARAMETER ProjectWhitelist
    Array of ProjectNames to always include in the output.

    .PARAMETER ProjectBlacklist
    Array of ProjectNames to exclude from the output unless they are also in the whitelist.

    .EXAMPLE
    New-DotnetBillOfMaterialsReport -jsonInput $jsonData -OutputFormat markdown -IgnoreTransitivePackages $false

    .EXAMPLE
    New-DotnetBillOfMaterialsReport -jsonInput $jsonData -Aggregate $false -OutputFile "bom.txt"

    .EXAMPLE
    New-DotnetBillOfMaterialsReport -jsonInput $jsonData -ProjectWhitelist "ProjectA","ProjectB" -ProjectBlacklist "ProjectC"

    .EXAMPLE
    New-DotnetBillOfMaterialsReport -jsonInput $jsonData -SetMarkDownTitle "Custom BOM Title"
    #>

    try {
        $result = $jsonInput | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse JSON input from dotnet list command."
        exit 1
    }

    $bomEntries = @()

    # Build BOM entries from projects and their frameworks.
    foreach ($project in $result.projects) {
        if ($project.frameworks) {
            foreach ($framework in $project.frameworks) {
                # Process top-level packages.
                if ($framework.topLevelPackages) {
                    foreach ($package in $framework.topLevelPackages) {
                        $bomEntries += [PSCustomObject]@{
                            ProjectName     = [System.IO.Path]::GetFileNameWithoutExtension($project.path)
                            Framework       = $framework.framework
                            Package         = $package.id
                            ResolvedVersion = $package.resolvedVersion
                            PackageType     = "TopLevel"
                        }
                    }
                }

                # Process transitive packages only if not ignored.
                if (-not $IgnoreTransitivePackages -and $framework.transitivePackages) {
                    foreach ($package in $framework.transitivePackages) {
                        $bomEntries += [PSCustomObject]@{
                            ProjectName     = [System.IO.Path]::GetFileNameWithoutExtension($project.path)
                            Framework       = $framework.framework
                            Package         = $package.id
                            ResolvedVersion = $package.resolvedVersion
                            PackageType     = "Transitive"
                        }
                    }
                }
            }
        }
    }

    # Filter BOM entries by project whitelist and blacklist.
    if ($ProjectWhitelist -or $ProjectBlacklist) {
        $bomEntries = $bomEntries | Where-Object {
            if ($ProjectWhitelist -and ($ProjectWhitelist -contains $_.ProjectName)) {
                # Always include if in whitelist.
                $true
            }
            elseif ($ProjectBlacklist -and ($ProjectBlacklist -contains $_.ProjectName)) {
                # Exclude if in blacklist and not whitelisted.
                $false
            }
            else {
                $true
            }
        }
    }

    # If aggregation is enabled, group entries accordingly.
    if ($Aggregate) {
        if ($IncludePackageType) {
            $bomEntries = $bomEntries | Group-Object -Property ProjectName, Package, ResolvedVersion, PackageType | ForEach-Object {
                [PSCustomObject]@{
                    ProjectName     = $_.Group[0].ProjectName
                    Package         = $_.Group[0].Package
                    ResolvedVersion = $_.Group[0].ResolvedVersion
                    PackageType     = $_.Group[0].PackageType
                }
            }
        }
        else {
            $bomEntries = $bomEntries | Group-Object -Property ProjectName, Package, ResolvedVersion | ForEach-Object {
                [PSCustomObject]@{
                    ProjectName     = $_.Group[0].ProjectName
                    Package         = $_.Group[0].Package
                    ResolvedVersion = $_.Group[0].ResolvedVersion
                }
            }
        }
    }

    # Generate output based on the specified format.
    switch ($OutputFormat) {
        "text" {
            $output = $bomEntries | Format-Table -AutoSize | Out-String
        }
        "markdown" {
            if ($Aggregate) {
                if ($IncludePackageType) {
                    $mdTable = @()
                    $mdTable += "| ProjectName | Package | ResolvedVersion | PackageType |"
                    $mdTable += "|-------------|---------|-----------------|-------------|"
                    foreach ($item in $bomEntries) {
                        $mdTable += "| $($item.ProjectName) | $($item.Package) | $($item.ResolvedVersion) | $($item.PackageType) |"
                    }
                }
                else {
                    $mdTable = @()
                    $mdTable += "| ProjectName | Package | ResolvedVersion |"
                    $mdTable += "|-------------|---------|-----------------|"
                    foreach ($item in $bomEntries) {
                        $mdTable += "| $($item.ProjectName) | $($item.Package) | $($item.ResolvedVersion) |"
                    }
                }
                $output = $mdTable -join "`n"
            }
            else {
                $mdTable = @()
                $mdTable += "| ProjectName | Framework | Package | ResolvedVersion | PackageType |"
                $mdTable += "|-------------|-----------|---------|-----------------|-------------|"
                foreach ($item in $bomEntries) {
                    $mdTable += "| $($item.ProjectName) | $($item.Framework) | $($item.Package) | $($item.ResolvedVersion) | $($item.PackageType) |"
                }
                $output = $mdTable -join "`n"
            }
        }
    }

    # Generate and prepend a professional title if enabled.
    if ($GenerateTitle) {
        $distinctProjects = $bomEntries | Select-Object -ExpandProperty ProjectName -Unique | Sort-Object
        $projectsStr = $distinctProjects -join ", "
        $defaultTitle = "Bill of Materials Report for Projects: $projectsStr"

        if ($OutputFormat -eq "markdown") {
            if ([string]::IsNullOrEmpty($SetMarkDownTitle)) {
                $titleText = "## $defaultTitle`n`n"
            }
            else {
                $titleText = "## $SetMarkDownTitle`n`n"
            }
        }
        else {
            $underline = "-" * $defaultTitle.Length
            $titleText = "$defaultTitle`n$underline`n`n"
        }
        $output = $titleText + $output
    }

    # Write output to file if specified; otherwise, output to the pipeline.
    if ($OutputFile) {
        $OutputFile = $OutputFile -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
        try {
            # Extract the directory from the output file path.
            $outputDir = Split-Path -Path $OutputFile -Parent
            
            # If the directory does not exist, create it.
            if (-not (Test-Path -Path $outputDir)) {
                New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
                Write-Verbose "Created directory: $outputDir"
            }
            
            # Write the output content to the file.
            Set-Content -Path $OutputFile -Value $output -Force
            Write-Verbose "Output written to $OutputFile"
        }
        catch {
            Write-Error "Failed to write output to file: $_"
        }
    }
    else {
        Write-Output $output
    }
}

function New-DotnetVulnerabilitiesReport {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Array of JSON strings output from dotnet list command with the '--vulnerable' flag.")]
        [string[]]$jsonInput,

        [Parameter(Mandatory = $false, HelpMessage = "Optional file path to save the output.")]
        [string]$OutputFile,

        [Parameter(Mandatory = $false, HelpMessage = "Output format: 'text' or 'markdown'. Defaults to 'text'.")]
        [ValidateSet("text", "markdown")]
        [string]$OutputFormat = "text",

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, the function exits with error code 1 if any vulnerability is found. Defaults to false.")]
        [bool]$ExitOnVulnerability = $false,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, aggregates the output by grouping on Project, Package, and ResolvedVersion, and optionally PackageType. Defaults to true.")]
        [bool]$Aggregate = $true,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, transitive packages are ignored. Defaults to true.")]
        [bool]$IgnoreTransitivePackages = $true,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, the aggregated output includes PackageType. Defaults to false.")]
        [bool]$IncludePackageType = $false,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, a professional title is generated and prepended to the output. Defaults to true.")]
        [bool]$GenerateTitle = $true,

        [Parameter(Mandatory = $false, HelpMessage = "Overrides the generated markdown title with a custom title. Only applied when OutputFormat is markdown.")]
        [string]$SetMarkDownTitle,

        [Parameter(Mandatory = $false, HelpMessage = "Array of ProjectNames to always include in the output.")]
        [string[]]$ProjectWhitelist,

        [Parameter(Mandatory = $false, HelpMessage = "Array of ProjectNames to exclude from the output unless they are also in the whitelist.")]
        [string[]]$ProjectBlacklist
    )

    <#
    .SYNOPSIS
    Generates a professional vulnerabilities report from JSON input output by the dotnet list command with the '--vulnerable' flag.

    .DESCRIPTION
    Processes JSON input from the dotnet list command to gather vulnerability details for each project's frameworks and packages.
    Only the resolved version is reported. Top-level packages are always processed, while transitive packages are processed only when
    -IgnoreTransitivePackages is set to false. The report can be aggregated (grouping by Project, Package, ResolvedVersion, and optionally PackageType),
    and filtered by project whitelist/blacklist. The output is generated in text or markdown format, with a professional title prepended.
    Optionally, if ExitOnVulnerability is enabled and any vulnerability is found, the function exits with error code 1.

    .PARAMETER jsonInput
    Array of JSON strings output from the dotnet list command with the '--vulnerable' flag.

    .PARAMETER OutputFile
    Optional file path to save the output.

    .PARAMETER OutputFormat
    Specifies the output format: 'text' or 'markdown'. Defaults to 'text'.

    .PARAMETER ExitOnVulnerability
    When set to true, the function exits with error code 1 if any vulnerability is found. Defaults to false.

    .PARAMETER Aggregate
    When set to true, aggregates the output by grouping on Project, Package, and ResolvedVersion (and optionally PackageType). Defaults to true.

    .PARAMETER IgnoreTransitivePackages
    When set to true, transitive packages are ignored. Defaults to true.

    .PARAMETER IncludePackageType
    When set to true, the aggregated output includes PackageType. Defaults to false.

    .PARAMETER GenerateTitle
    When set to true, a professional title including project names is generated and prepended to the output. Defaults to true.

    .PARAMETER SetMarkDownTitle
    Overrides the generated markdown title with a custom title. Only applied when OutputFormat is markdown.

    .PARAMETER ProjectWhitelist
    Array of ProjectNames to always include in the output.

    .PARAMETER ProjectBlacklist
    Array of ProjectNames to exclude from the output unless they are also in the whitelist.

    .EXAMPLE
    New-DotnetVulnerabilitiesReport -jsonInput $jsonData -OutputFormat markdown -ExitOnVulnerability $true

    .EXAMPLE
    New-DotnetVulnerabilitiesReport -jsonInput $jsonData -OutputFile "vuln_report.txt"

    .EXAMPLE
    New-DotnetVulnerabilitiesReport -jsonInput $jsonData -SetMarkDownTitle "Custom Vulnerability Report"
    #>

    try {
        $result = $jsonInput | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse JSON input from dotnet list command."
        exit 1
    }

    $vulnerabilitiesFound = @()

    # Process each project and its frameworks.
    foreach ($project in $result.projects) {
        if ($project.frameworks) {
            foreach ($framework in $project.frameworks) {
                # Process top-level packages.
                if ($framework.topLevelPackages) {
                    foreach ($package in $framework.topLevelPackages) {
                        if ($package.vulnerabilities) {
                            foreach ($vuln in $package.vulnerabilities) {
                                $vulnerabilitiesFound += [PSCustomObject]@{
                                    Project         = [System.IO.Path]::GetFileNameWithoutExtension($project.path)
                                    Framework       = $framework.framework
                                    Package         = $package.id
                                    ResolvedVersion = $package.resolvedVersion
                                    Severity        = $vuln.severity
                                    AdvisoryUrl     = $vuln.advisoryurl
                                    PackageType     = "TopLevel"
                                }
                            }
                        }
                    }
                }
                # Process transitive packages if not ignored.
                if (-not $IgnoreTransitivePackages -and $framework.transitivePackages) {
                    foreach ($package in $framework.transitivePackages) {
                        if ($package.vulnerabilities) {
                            foreach ($vuln in $package.vulnerabilities) {
                                $vulnerabilitiesFound += [PSCustomObject]@{
                                    Project         = [System.IO.Path]::GetFileNameWithoutExtension($project.path)
                                    Framework       = $framework.framework
                                    Package         = $package.id
                                    ResolvedVersion = $package.resolvedVersion
                                    Severity        = $vuln.severity
                                    AdvisoryUrl     = $vuln.advisoryurl
                                    PackageType     = "Transitive"
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    # Filter vulnerabilities by project whitelist and blacklist.
    if ($ProjectWhitelist -or $ProjectBlacklist) {
        $vulnerabilitiesFound = $vulnerabilitiesFound | Where-Object {
            if ($ProjectWhitelist -and ($ProjectWhitelist -contains $_.Project)) {
                $true
            }
            elseif ($ProjectBlacklist -and ($ProjectBlacklist -contains $_.Project)) {
                $false
            }
            else {
                $true
            }
        }
    }

    # Aggregate vulnerabilities if enabled.
    if ($Aggregate) {
        if ($IncludePackageType) {
            $vulnerabilitiesFound = $vulnerabilitiesFound | Group-Object -Property Project, Package, ResolvedVersion, PackageType | ForEach-Object {
                [PSCustomObject]@{
                    Project         = $_.Group[0].Project
                    Package         = $_.Group[0].Package
                    ResolvedVersion = $_.Group[0].ResolvedVersion
                    PackageType     = $_.Group[0].PackageType
                    Severity        = $_.Group[0].Severity
                    AdvisoryUrl     = $_.Group[0].AdvisoryUrl
                }
            }
        }
        else {
            $vulnerabilitiesFound = $vulnerabilitiesFound | Group-Object -Property Project, Package, ResolvedVersion | ForEach-Object {
                [PSCustomObject]@{
                    Project         = $_.Group[0].Project
                    Package         = $_.Group[0].Package
                    ResolvedVersion = $_.Group[0].ResolvedVersion
                    Severity        = $_.Group[0].Severity
                    AdvisoryUrl     = $_.Group[0].AdvisoryUrl
                }
            }
        }
    }

    # Generate report output based on the specified format.
    if ($OutputFormat -eq "text") {
        if ($vulnerabilitiesFound.Count -gt 0) {
            $output = $vulnerabilitiesFound | Format-Table -AutoSize | Out-String
        }
        else {
            $output = "No vulnerabilities found."
        }
    }
    elseif ($OutputFormat -eq "markdown") {
        if ($vulnerabilitiesFound.Count -gt 0) {
            if ($Aggregate) {
                if ($IncludePackageType) {
                    $mdTable = @()
                    $mdTable += "| Project | Package | ResolvedVersion | PackageType | Severity | AdvisoryUrl |"
                    $mdTable += "|---------|---------|-----------------|-------------|----------|-------------|"
                    foreach ($item in $vulnerabilitiesFound) {
                        $mdTable += "| $($item.Project) | $($item.Package) | $($item.ResolvedVersion) | $($item.PackageType) | $($item.Severity) | $($item.AdvisoryUrl) |"
                    }
                }
                else {
                    $mdTable = @()
                    $mdTable += "| Project | Package | ResolvedVersion | Severity | AdvisoryUrl |"
                    $mdTable += "|---------|---------|-----------------|----------|-------------|"
                    foreach ($item in $vulnerabilitiesFound) {
                        $mdTable += "| $($item.Project) | $($item.Package) | $($item.ResolvedVersion) | $($item.Severity) | $($item.AdvisoryUrl) |"
                    }
                }
            }
            else {
                $mdTable = @()
                $mdTable += "| Project | Framework | Package | ResolvedVersion | PackageType | Severity | AdvisoryUrl |"
                $mdTable += "|---------|-----------|---------|-----------------|-------------|----------|-------------|"
                foreach ($item in $vulnerabilitiesFound) {
                    $mdTable += "| $($item.Project) | $($item.Framework) | $($item.Package) | $($item.ResolvedVersion) | $($item.PackageType) | $($item.Severity) | $($item.AdvisoryUrl) |"
                }
            }
            $output = $mdTable -join "`n"
        }
        else {
            $output = "No vulnerabilities found."
        }
    }

    # Generate and prepend a professional title if enabled.
    if ($GenerateTitle) {
        if ($vulnerabilitiesFound.Count -eq 0) {
            # If no vulnerabilities, compute project list from the JSON input.
            $allProjects = $result.projects | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.path) } | Sort-Object -Unique
            if ($ProjectWhitelist -or $ProjectBlacklist) {
                $filteredProjects = $allProjects | Where-Object {
                    if ($ProjectWhitelist -and ($ProjectWhitelist -contains $_)) {
                        $true
                    }
                    elseif ($ProjectBlacklist -and ($ProjectBlacklist -contains $_)) {
                        $false
                    }
                    else {
                        $true
                    }
                }
            }
            else {
                $filteredProjects = $allProjects
            }
            $projectsForTitle = $filteredProjects
        }
        else {
            $projectsForTitle = $vulnerabilitiesFound | Select-Object -ExpandProperty Project -Unique | Sort-Object
        }
        if ($projectsForTitle.Count -eq 0) {
            $projectsStr = "None"
        }
        else {
            $projectsStr = $projectsForTitle -join ", "
        }
        $defaultTitle = "Vulnerabilities Report for Projects: $projectsStr"
        
        if ($OutputFormat -eq "markdown") {
            if ([string]::IsNullOrEmpty($SetMarkDownTitle)) {
                $titleText = "## $defaultTitle`n`n"
            }
            else {
                $titleText = "## $SetMarkDownTitle`n`n"
            }
        }
        else {
            $underline = "-" * $defaultTitle.Length
            $titleText = "$defaultTitle`n$underline`n`n"
        }
        $output = $titleText + $output
    }

    # Write output to file if specified; otherwise, output to the pipeline.
    if ($OutputFile) {
        $OutputFile = $OutputFile -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
        try {
            # Extract the directory from the output file path.
            $outputDir = Split-Path -Path $OutputFile -Parent
            
            # If the directory does not exist, create it.
            if (-not (Test-Path -Path $outputDir)) {
                New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
                Write-Verbose "Created directory: $outputDir"
            }
            
            # Write the output content to the file.
            Set-Content -Path $OutputFile -Value $output -Force
            Write-Verbose "Output written to $OutputFile"
        }
        catch {
            Write-Error "Failed to write output to file: $_"
        }
    }
    else {
        Write-Output $output
    }

    # Exit behavior: if vulnerabilities are found and ExitOnVulnerability is enabled, exit with error code 1.
    if ($vulnerabilitiesFound.Count -gt 0 -and $ExitOnVulnerability) {
        Write-Host "Vulnerabilities detected. Exiting with error code 1." -ForegroundColor Red
        exit 1
    }
    elseif ($vulnerabilitiesFound.Count -gt 0) {
        Write-Host "Vulnerabilities detected, but not exiting due to configuration." -ForegroundColor Yellow
    }
}

function New-DotnetDeprecatedReport {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Array of JSON strings output from dotnet list command with the '--deprecated' flag.")]
        [string[]]$jsonInput,

        [Parameter(Mandatory = $false, HelpMessage = "Optional file path to save the output.")]
        [string]$OutputFile,

        [Parameter(Mandatory = $false, HelpMessage = "Output format: 'text' or 'markdown'. Defaults to 'text'.")]
        [ValidateSet("text", "markdown")]
        [string]$OutputFormat = "text",

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, the function exits with error code 1 if any deprecated package is found. Defaults to false.")]
        [bool]$ExitOnDeprecated = $false,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, aggregates the output by grouping on Project, Package, and ResolvedVersion (and optionally PackageType). Defaults to true.")]
        [bool]$Aggregate = $true,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, transitive packages are ignored. Defaults to true.")]
        [bool]$IgnoreTransitivePackages = $true,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, the aggregated output includes PackageType. Defaults to false.")]
        [bool]$IncludePackageType = $false,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, a professional title is generated and prepended to the output. Defaults to true.")]
        [bool]$GenerateTitle = $true,

        [Parameter(Mandatory = $false, HelpMessage = "Overrides the generated markdown title with a custom title. Only applied when OutputFormat is markdown.")]
        [string]$SetMarkDownTitle,

        [Parameter(Mandatory = $false, HelpMessage = "Array of ProjectNames to always include in the output.")]
        [string[]]$ProjectWhitelist,

        [Parameter(Mandatory = $false, HelpMessage = "Array of ProjectNames to exclude from the output unless they are also in the whitelist.")]
        [string[]]$ProjectBlacklist
    )

    <#
    .SYNOPSIS
    Generates a professional deprecation report from JSON input output by the dotnet list command with the '--deprecated' flag.

    .DESCRIPTION
    Processes JSON input from the dotnet list command to gather deprecation details for each project's frameworks and packages.
    Both top-level and, optionally, transitive packages are processed if they contain deprecation reasons.
    The report aggregates data (grouping by Project, Package, ResolvedVersion, and optionally PackageType) and filters by project whitelist/blacklist.
    Output is generated in text or markdown format with an optional professional title.
    Optionally, if ExitOnDeprecated is enabled and any deprecated package is found, the function exits with error code 1.

    .PARAMETER jsonInput
    Array of JSON strings output from the dotnet list command with the '--deprecated' flag.

    .PARAMETER OutputFile
    Optional file path to save the output.

    .PARAMETER OutputFormat
    Specifies the output format: 'text' or 'markdown'. Defaults to 'text'.

    .PARAMETER ExitOnDeprecated
    When set to true, the function exits with error code 1 if any deprecated package is found. Defaults to false.

    .PARAMETER Aggregate
    When set to true, aggregates the output by grouping on Project, Package, and ResolvedVersion (and optionally PackageType). Defaults to true.

    .PARAMETER IgnoreTransitivePackages
    When set to true, transitive packages are ignored. Defaults to true.

    .PARAMETER IncludePackageType
    When set to true, the aggregated output includes PackageType. Defaults to false.

    .PARAMETER GenerateTitle
    When set to true, a professional title including project names is generated and prepended to the output. Defaults to true.

    .PARAMETER SetMarkDownTitle
    Overrides the generated markdown title with a custom title. Only applied when OutputFormat is markdown.

    .PARAMETER ProjectWhitelist
    Array of ProjectNames to always include in the output.

    .PARAMETER ProjectBlacklist
    Array of ProjectNames to exclude from the output unless they are also in the whitelist.

    .EXAMPLE
    New-DotnetDeprecatedReport -jsonInput $jsonData -OutputFormat markdown -ExitOnDeprecated $true

    .EXAMPLE
    New-DotnetDeprecatedReport -jsonInput $jsonData -OutputFile "deprecated_report.txt"

    .EXAMPLE
    New-DotnetDeprecatedReport -jsonInput $jsonData -SetMarkDownTitle "Custom Deprecated Packages Report"
    #>

    try {
        $result = $jsonInput | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse JSON input from dotnet list command."
        exit 1
    }

    $deprecatedFound = @()

    # Process each project and its frameworks.
    foreach ($project in $result.projects) {
        if ($project.frameworks) {
            foreach ($framework in $project.frameworks) {
                # Process top-level packages.
                if ($framework.topLevelPackages) {
                    foreach ($package in $framework.topLevelPackages) {
                        if ($package.deprecationReasons -and $package.deprecationReasons.Count -gt 0) {
                            $deprecatedFound += [PSCustomObject]@{
                                Project            = [System.IO.Path]::GetFileNameWithoutExtension($project.path)
                                Framework          = $framework.framework
                                Package            = $package.id
                                ResolvedVersion    = $package.resolvedVersion
                                DeprecationReasons = ($package.deprecationReasons -join ", ")
                                PackageType        = "TopLevel"
                            }
                        }
                    }
                }
                # Process transitive packages if not ignored.
                if (-not $IgnoreTransitivePackages -and $framework.transitivePackages) {
                    foreach ($package in $framework.transitivePackages) {
                        if ($package.deprecationReasons -and $package.deprecationReasons.Count -gt 0) {
                            $deprecatedFound += [PSCustomObject]@{
                                Project            = [System.IO.Path]::GetFileNameWithoutExtension($project.path)
                                Framework          = $framework.framework
                                Package            = $package.id
                                ResolvedVersion    = $package.resolvedVersion
                                DeprecationReasons = ($package.deprecationReasons -join ", ")
                                PackageType        = "Transitive"
                            }
                        }
                    }
                }
            }
        }
    }

    # Filter deprecated packages by project whitelist and blacklist.
    if ($ProjectWhitelist -or $ProjectBlacklist) {
        $deprecatedFound = $deprecatedFound | Where-Object {
            if ($ProjectWhitelist -and ($ProjectWhitelist -contains $_.Project)) {
                $true
            }
            elseif ($ProjectBlacklist -and ($ProjectBlacklist -contains $_.Project)) {
                $false
            }
            else {
                $true
            }
        }
    }

    # Aggregate deprecated packages if enabled.
    if ($Aggregate) {
        if ($IncludePackageType) {
            $deprecatedFound = $deprecatedFound | Group-Object -Property Project, Package, ResolvedVersion, PackageType | ForEach-Object {
                [PSCustomObject]@{
                    Project            = $_.Group[0].Project
                    Package            = $_.Group[0].Package
                    ResolvedVersion    = $_.Group[0].ResolvedVersion
                    PackageType        = $_.Group[0].PackageType
                    DeprecationReasons = $_.Group[0].DeprecationReasons
                }
            }
        }
        else {
            $deprecatedFound = $deprecatedFound | Group-Object -Property Project, Package, ResolvedVersion | ForEach-Object {
                [PSCustomObject]@{
                    Project            = $_.Group[0].Project
                    Package            = $_.Group[0].Package
                    ResolvedVersion    = $_.Group[0].ResolvedVersion
                    DeprecationReasons = $_.Group[0].DeprecationReasons
                }
            }
        }
    }

    # Generate report output based on the specified format.
    if ($OutputFormat -eq "text") {
        if ($deprecatedFound.Count -gt 0) {
            if ($Aggregate) {
                if ($IncludePackageType) {
                    $output = $deprecatedFound | Format-Table Project, Package, ResolvedVersion, PackageType, DeprecationReasons -AutoSize | Out-String
                }
                else {
                    $output = $deprecatedFound | Format-Table Project, Package, ResolvedVersion, DeprecationReasons -AutoSize | Out-String
                }
            }
            else {
                $output = $deprecatedFound | Format-Table Project, Framework, Package, ResolvedVersion, PackageType, DeprecationReasons -AutoSize | Out-String
            }
        }
        else {
            $output = "No deprecated packages found."
        }
    }
    elseif ($OutputFormat -eq "markdown") {
        if ($deprecatedFound.Count -gt 0) {
            if ($Aggregate) {
                if ($IncludePackageType) {
                    $mdTable = @()
                    $mdTable += "| Project | Package | ResolvedVersion | PackageType | DeprecationReasons |"
                    $mdTable += "|---------|---------|-----------------|-------------|--------------------|"
                    foreach ($item in $deprecatedFound) {
                        $mdTable += "| $($item.Project) | $($item.Package) | $($item.ResolvedVersion) | $($item.PackageType) | $($item.DeprecationReasons) |"
                    }
                }
                else {
                    $mdTable = @()
                    $mdTable += "| Project | Package | ResolvedVersion | DeprecationReasons |"
                    $mdTable += "|---------|---------|-----------------|--------------------|"
                    foreach ($item in $deprecatedFound) {
                        $mdTable += "| $($item.Project) | $($item.Package) | $($item.ResolvedVersion) | $($item.DeprecationReasons) |"
                    }
                }
            }
            else {
                $mdTable = @()
                $mdTable += "| Project | Framework | Package | ResolvedVersion | PackageType | DeprecationReasons |"
                $mdTable += "|---------|-----------|---------|-----------------|-------------|--------------------|"
                foreach ($item in $deprecatedFound) {
                    $mdTable += "| $($item.Project) | $($item.Framework) | $($item.Package) | $($item.ResolvedVersion) | $($item.PackageType) | $($item.DeprecationReasons) |"
                }
            }
            $output = $mdTable -join "`n"
        }
        else {
            $output = "No deprecated packages found."
        }
    }

    # Generate and prepend a professional title if enabled.
    if ($GenerateTitle) {
        if ($deprecatedFound.Count -eq 0) {
            # If no deprecated packages, compute project list from the JSON input.
            $allProjects = $result.projects | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.path) } | Sort-Object -Unique
            if ($ProjectWhitelist -or $ProjectBlacklist) {
                $filteredProjects = $allProjects | Where-Object {
                    if ($ProjectWhitelist -and ($ProjectWhitelist -contains $_)) {
                        $true
                    }
                    elseif ($ProjectBlacklist -and ($ProjectBlacklist -contains $_)) {
                        $false
                    }
                    else {
                        $true
                    }
                }
            }
            else {
                $filteredProjects = $allProjects
            }
            $projectsForTitle = $filteredProjects
        }
        else {
            $projectsForTitle = $deprecatedFound | Select-Object -ExpandProperty Project -Unique | Sort-Object
        }
        if ($projectsForTitle.Count -eq 0) {
            $projectsStr = "None"
        }
        else {
            $projectsStr = $projectsForTitle -join ", "
        }
        $defaultTitle = "Deprecated Packages Report for Projects: $projectsStr"
        
        if ($OutputFormat -eq "markdown") {
            if ([string]::IsNullOrEmpty($SetMarkDownTitle)) {
                $titleText = "## $defaultTitle`n`n"
            }
            else {
                $titleText = "## $SetMarkDownTitle`n`n"
            }
        }
        else {
            $underline = "-" * $defaultTitle.Length
            $titleText = "$defaultTitle`n$underline`n`n"
        }
        $output = $titleText + $output
    }

    # Write output to file if specified; otherwise, output to the pipeline.
    if ($OutputFile) {
        $OutputFile = $OutputFile -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
        try {
            # Extract the directory from the output file path.
            $outputDir = Split-Path -Path $OutputFile -Parent
            
            # If the directory does not exist, create it.
            if (-not (Test-Path -Path $outputDir)) {
                New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
                Write-Verbose "Created directory: $outputDir"
            }
            
            # Write the output content to the file.
            Set-Content -Path $OutputFile -Value $output -Force
            Write-Verbose "Output written to $OutputFile"
        }
        catch {
            Write-Error "Failed to write output to file: $_"
        }
    }
    else {
        Write-Output $output
    }

    # Exit behavior: if deprecated packages are found and ExitOnDeprecated is enabled, exit with error code 1.
    if ($deprecatedFound.Count -gt 0 -and $ExitOnDeprecated) {
        Write-Host "Deprecated packages detected. Exiting with error code 1." -ForegroundColor Red
        exit 1
    }
    elseif ($deprecatedFound.Count -gt 0) {
        Write-Host "Deprecated packages detected, but not exiting due to configuration." -ForegroundColor Yellow
    }
}

function New-DotnetOutdatedReport {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Array of JSON strings output from dotnet list command with the '--outdated' flag.")]
        [string[]]$jsonInput,

        [Parameter(Mandatory = $false, HelpMessage = "Optional file path to save the output.")]
        [string]$OutputFile,

        [Parameter(Mandatory = $false, HelpMessage = "Output format: 'text' or 'markdown'. Defaults to 'text'.")]
        [ValidateSet("text", "markdown")]
        [string]$OutputFormat = "text",

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, the function exits with error code 1 if any outdated package is found. Defaults to false.")]
        [bool]$ExitOnOutdated = $false,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, aggregates the output by grouping on Project, Package, ResolvedVersion and LatestVersion (and optionally PackageType). Defaults to true.")]
        [bool]$Aggregate = $true,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, transitive packages are ignored. Defaults to true.")]
        [bool]$IgnoreTransitivePackages = $true,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, the aggregated output includes PackageType. Defaults to false.")]
        [bool]$IncludePackageType = $false,

        [Parameter(Mandatory = $false, HelpMessage = "When set to true, a professional title is generated and prepended to the output. Defaults to true.")]
        [bool]$GenerateTitle = $true,

        [Parameter(Mandatory = $false, HelpMessage = "Overrides the generated markdown title with a custom title. Only applied when OutputFormat is markdown.")]
        [string]$SetMarkDownTitle,

        [Parameter(Mandatory = $false, HelpMessage = "Array of ProjectNames to always include in the output.")]
        [string[]]$ProjectWhitelist,

        [Parameter(Mandatory = $false, HelpMessage = "Array of ProjectNames to exclude from the output unless they are also in the whitelist.")]
        [string[]]$ProjectBlacklist
    )

    <#
    .SYNOPSIS
    Generates a professional outdated packages report from JSON input output by the dotnet list command with the '--outdated' flag.

    .DESCRIPTION
    Processes JSON input from the dotnet list command to identify outdated packages for each project's frameworks.
    A package is considered outdated if its resolvedVersion does not match its latestVersion.
    Both top-level and (optionally) transitive packages are processed.
    The report aggregates data (grouping by Project, Package, ResolvedVersion, LatestVersion and optionally PackageType)
    and filters by project whitelist/blacklist. The output is generated in text or markdown format with a professional title.
    Optionally, if ExitOnOutdated is enabled and any outdated package is found, the function exits with error code 1.

    .PARAMETER jsonInput
    Array of JSON strings output from the dotnet list command with the '--outdated' flag.

    .PARAMETER OutputFile
    Optional file path to save the output.

    .PARAMETER OutputFormat
    Specifies the output format: 'text' or 'markdown'. Defaults to 'text'.

    .PARAMETER ExitOnOutdated
    When set to true, the function exits with error code 1 if any outdated package is found. Defaults to false.

    .PARAMETER Aggregate
    When set to true, aggregates the output by grouping on Project, Package, ResolvedVersion, and LatestVersion (and optionally PackageType). Defaults to true.

    .PARAMETER IgnoreTransitivePackages
    When set to true, transitive packages are ignored. Defaults to true.

    .PARAMETER IncludePackageType
    When set to true, the aggregated output includes PackageType. Defaults to false.

    .PARAMETER GenerateTitle
    When set to true, a professional title including project names is generated and prepended to the output. Defaults to true.

    .PARAMETER SetMarkDownTitle
    Overrides the generated markdown title with a custom title. Only applied when OutputFormat is markdown.

    .PARAMETER ProjectWhitelist
    Array of ProjectNames to always include in the output.

    .PARAMETER ProjectBlacklist
    Array of ProjectNames to exclude from the output unless they are also in the whitelist.

    .EXAMPLE
    New-DotnetOutdatedReport -jsonInput $jsonData -OutputFormat markdown -ExitOnOutdated $true

    .EXAMPLE
    New-DotnetOutdatedReport -jsonInput $jsonData -OutputFile "outdated_report.txt"

    .EXAMPLE
    New-DotnetOutdatedReport -jsonInput $jsonData -SetMarkDownTitle "Custom Outdated Packages Report"
    #>

    try {
        $result = $jsonInput | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse JSON input from dotnet list command."
        exit 1
    }

    $outdatedFound = @()

    # Process each project and its frameworks.
    foreach ($project in $result.projects) {
        if ($project.frameworks) {
            foreach ($framework in $project.frameworks) {
                # Process top-level packages.
                if ($framework.topLevelPackages) {
                    foreach ($package in $framework.topLevelPackages) {
                        if ($package.latestVersion -and ($package.resolvedVersion -ne $package.latestVersion)) {
                            $outdatedFound += [PSCustomObject]@{
                                Project         = [System.IO.Path]::GetFileNameWithoutExtension($project.path)
                                Framework       = $framework.framework
                                Package         = $package.id
                                ResolvedVersion = $package.resolvedVersion
                                LatestVersion   = $package.latestVersion
                                PackageType     = "TopLevel"
                            }
                        }
                    }
                }
                # Process transitive packages if not ignored.
                if (-not $IgnoreTransitivePackages -and $framework.transitivePackages) {
                    foreach ($package in $framework.transitivePackages) {
                        if ($package.latestVersion -and ($package.resolvedVersion -ne $package.latestVersion)) {
                            $outdatedFound += [PSCustomObject]@{
                                Project         = [System.IO.Path]::GetFileNameWithoutExtension($project.path)
                                Framework       = $framework.framework
                                Package         = $package.id
                                ResolvedVersion = $package.resolvedVersion
                                LatestVersion   = $package.latestVersion
                                PackageType     = "Transitive"
                            }
                        }
                    }
                }
            }
        }
    }

    # Filter outdated packages by project whitelist and blacklist.
    if ($ProjectWhitelist -or $ProjectBlacklist) {
        $outdatedFound = $outdatedFound | Where-Object {
            if ($ProjectWhitelist -and ($ProjectWhitelist -contains $_.Project)) {
                $true
            }
            elseif ($ProjectBlacklist -and ($ProjectBlacklist -contains $_.Project)) {
                $false
            }
            else {
                $true
            }
        }
    }

    # Aggregate outdated packages if enabled.
    if ($Aggregate) {
        if ($IncludePackageType) {
            $outdatedFound = $outdatedFound | Group-Object -Property Project, Package, ResolvedVersion, LatestVersion, PackageType | ForEach-Object {
                [PSCustomObject]@{
                    Project         = $_.Group[0].Project
                    Package         = $_.Group[0].Package
                    ResolvedVersion = $_.Group[0].ResolvedVersion
                    LatestVersion   = $_.Group[0].LatestVersion
                    PackageType     = $_.Group[0].PackageType
                }
            }
        }
        else {
            $outdatedFound = $outdatedFound | Group-Object -Property Project, Package, ResolvedVersion, LatestVersion | ForEach-Object {
                [PSCustomObject]@{
                    Project         = $_.Group[0].Project
                    Package         = $_.Group[0].Package
                    ResolvedVersion = $_.Group[0].ResolvedVersion
                    LatestVersion   = $_.Group[0].LatestVersion
                }
            }
        }
    }

    # Generate report output based on the specified format.
    if ($OutputFormat -eq "text") {
        if ($outdatedFound.Count -gt 0) {
            if ($Aggregate) {
                if ($IncludePackageType) {
                    $output = $outdatedFound | Format-Table -AutoSize | Out-String
                }
                else {
                    $output = $outdatedFound | Format-Table Project, Package, ResolvedVersion, LatestVersion -AutoSize | Out-String
                }
            }
            else {
                $output = $outdatedFound | Format-Table Project, Framework, Package, ResolvedVersion, LatestVersion, PackageType -AutoSize | Out-String
            }
        }
        else {
            $output = "No outdated packages found."
        }
    }
    elseif ($OutputFormat -eq "markdown") {
        if ($outdatedFound.Count -gt 0) {
            if ($Aggregate) {
                if ($IncludePackageType) {
                    $mdTable = @()
                    $mdTable += "| Project | Package | ResolvedVersion | LatestVersion | PackageType |"
                    $mdTable += "|---------|---------|-----------------|---------------|-------------|"
                    foreach ($item in $outdatedFound) {
                        $mdTable += "| $($item.Project) | $($item.Package) | $($item.ResolvedVersion) | $($item.LatestVersion) | $($item.PackageType) |"
                    }
                }
                else {
                    $mdTable = @()
                    $mdTable += "| Project | Package | ResolvedVersion | LatestVersion |"
                    $mdTable += "|---------|---------|-----------------|---------------|"
                    foreach ($item in $outdatedFound) {
                        $mdTable += "| $($item.Project) | $($item.Package) | $($item.ResolvedVersion) | $($item.LatestVersion) |"
                    }
                }
            }
            else {
                $mdTable = @()
                $mdTable += "| Project | Framework | Package | ResolvedVersion | LatestVersion | PackageType |"
                $mdTable += "|---------|-----------|---------|-----------------|---------------|-------------|"
                foreach ($item in $outdatedFound) {
                    $mdTable += "| $($item.Project) | $($item.Framework) | $($item.Package) | $($item.ResolvedVersion) | $($item.LatestVersion) | $($item.PackageType) |"
                }
            }
            $output = $mdTable -join "`n"
        }
        else {
            $output = "No outdated packages found."
        }
    }

    # Generate and prepend a professional title if enabled.
    if ($GenerateTitle) {
        if ($outdatedFound.Count -eq 0) {
            # If no outdated packages, compute project list from the JSON input.
            $allProjects = $result.projects | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.path) } | Sort-Object -Unique
            if ($ProjectWhitelist -or $ProjectBlacklist) {
                $filteredProjects = $allProjects | Where-Object {
                    if ($ProjectWhitelist -and ($ProjectWhitelist -contains $_)) {
                        $true
                    }
                    elseif ($ProjectBlacklist -and ($ProjectBlacklist -contains $_)) {
                        $false
                    }
                    else {
                        $true
                    }
                }
            }
            else {
                $filteredProjects = $allProjects
            }
            $projectsForTitle = $filteredProjects
        }
        else {
            $projectsForTitle = $outdatedFound | Select-Object -ExpandProperty Project -Unique | Sort-Object
        }
        if ($projectsForTitle.Count -eq 0) {
            $projectsStr = "None"
        }
        else {
            $projectsStr = $projectsForTitle -join ", "
        }
        $defaultTitle = "Outdated Packages Report for Projects: $projectsStr"
        
        if ($OutputFormat -eq "markdown") {
            if ([string]::IsNullOrEmpty($SetMarkDownTitle)) {
                $titleText = "## $defaultTitle`n`n"
            }
            else {
                $titleText = "## $SetMarkDownTitle`n`n"
            }
        }
        else {
            $underline = "-" * $defaultTitle.Length
            $titleText = "$defaultTitle`n$underline`n`n"
        }
        $output = $titleText + $output
    }

    # Write output to file if specified; otherwise, output to the pipeline.
    if ($OutputFile) {
        $OutputFile = $OutputFile -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
        try {
            # Extract the directory from the output file path.
            $outputDir = Split-Path -Path $OutputFile -Parent
            
            # If the directory does not exist, create it.
            if (-not (Test-Path -Path $outputDir)) {
                New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
                Write-Verbose "Created directory: $outputDir"
            }
            
            # Write the output content to the file.
            Set-Content -Path $OutputFile -Value $output -Force
            Write-Verbose "Output written to $OutputFile"
        }
        catch {
            Write-Error "Failed to write output to file: $_"
        }
    }
    else {
        Write-Output $output
    }

    # Exit behavior: if outdated packages are found and ExitOnOutdated is enabled, exit with error code 1.
    if ($outdatedFound.Count -gt 0 -and $ExitOnOutdated) {
        Write-Host "Outdated packages detected. Exiting with error code 1." -ForegroundColor Red
        exit 1
    }
    elseif ($outdatedFound.Count -gt 0) {
        Write-Host "Outdated packages detected, but not exiting due to configuration." -ForegroundColor Yellow
    }
}


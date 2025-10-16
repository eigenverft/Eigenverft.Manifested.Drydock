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


# One-liner: sticky cache derived from manifest → fast subsequent runs
#$rep = Enable-TempDotnetTools -ManifestFile "C:\dev\github.com\eigenverft\Eigenverft.Manifested.Drydock\.github\workflows\.config\dotnet-tools\dotnet-tools.json" -NoReturn  # <-- reuse the same temp cache per manifest
#$rep.Tools | Format-Table

# Use your tools anywhere in this session...
# e.g., dotnet-ef / dotnet ef / docfx, etc.
#docfx --help
# End of session: remove from PATH and (optionally) delete the cache
#Disable-TempDotnetTools -ManifestFile "C:\dev\github.com\eigenverft\Eigenverft.Manifested.Drydock\.github\workflows\.config\dotnet-tools\dotnet-tools.json"              # keep cache (fast next time)


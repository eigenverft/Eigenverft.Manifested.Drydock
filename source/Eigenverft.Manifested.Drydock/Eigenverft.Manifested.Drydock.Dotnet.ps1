function Enable-TempDotnetTools {
<#
.SYNOPSIS
Install local-tools from a manifest into an ephemeral cache and expose them for THIS session.

.DESCRIPTION
- Reads a standard dotnet local tools manifest (dotnet-tools.json) with exact versions.
- Ensures each tool exists in a --tool-path cache (sticky or fresh).
- Puts that folder at the front of PATH for the current session only.
- Returns a single object: @{ ToolPath = "..."; Tools = [ @{Id,Version,Status}, ... ] }.

.PARAMETER ManifestFile
Path to the dotnet local tools manifest (dotnet-tools.json).

.PARAMETER ToolPath
Optional explicit --tool-path. If omitted, a stable cache path is derived from the manifest hash.

.PARAMETER Fresh
If set, uses a brand-new GUID cache folder (cold start each time).

.PARAMETER NoCache
If set, passes --no-cache to dotnet (disables NuGet HTTP cache; slower).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestFile,
        [string]$ToolPath,
        [switch]$Fresh,
        [switch]$NoCache
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

    # -----------------------
    # 2) Snapshot BEFORE
    # -----------------------
    $before = _GetToolsInPath -Path $ToolPath

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
            $ok = _EnsureExactTool -Path $ToolPath -Id $id -Version $ver -NoCache:$NoCache -TryUpdateFirst:$present
            if (-not $ok) { throw "Failed to ensure $id@$ver in $ToolPath." }
            $status = $present ? "Updated" : "Installed"
        }

        $toolsResult += [pscustomobject]@{ Id = $id; Version = $ver; Status = $status }
    }

    # -----------------------
    # 4) PATH (session only)
    # -----------------------
    _PrependPathIfMissing -Path $ToolPath

    # -----------------------
    # 5) Snapshot AFTER (normalize versions actually resolved by dotnet)
    # -----------------------
    $after = _GetToolsInPath -Path $ToolPath
    for ($i = 0; $i -lt $toolsResult.Count; $i++) {
        $rid = $toolsResult[$i].Id
        if ($after.ContainsKey($rid)) { $toolsResult[$i].Version = $after[$rid] }
    }

    # -----------------------
    # 6) Return single object
    # -----------------------
    return [pscustomobject]@{
        ToolPath = $ToolPath
        Tools    = $toolsResult
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
#$rep = Enable-TempDotnetTools -ManifestFile "C:\dev\github.com\eigenverft\Eigenverft.Manifested.Drydock\.github\workflows\config\dotnet-tools\dotnet-tools.json"  # <-- reuse the same temp cache per manifest
#$rep.Tools | Format-Table

# Use your tools anywhere in this session...
# e.g., dotnet-ef / dotnet ef / docfx, etc.
#docfx --help
# End of session: remove from PATH and (optionally) delete the cache
#Disable-TempDotnetTools -ManifestFile "C:\dev\github.com\eigenverft\Eigenverft.Manifested.Drydock\.github\workflows\config\dotnet-tools\dotnet-tools.json"              # keep cache (fast next time)


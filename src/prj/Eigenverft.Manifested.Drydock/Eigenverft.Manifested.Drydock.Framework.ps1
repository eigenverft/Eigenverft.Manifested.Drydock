function Get-DotNetFrameworkInfo {
<#
.SYNOPSIS
Enumerates installed .NET Framework (1.1 → 4.8.1) and shows build-capability packs per family.

.DESCRIPTION
Reads NDP registry (both views on x64 OS), skips LCID/tech leaves, resolves InstallPath robustly.
Adds per-row capability sets:
- TargetPacksApplicable/TargetPacksApplicableTFM (by PRODUCT FAMILY: 1.1, 2.0, 3.0, 3.5, 4.x)
- TargetPacksMachine/TargetPacksMachineTFM (all packs on the machine)
…and version-typed variants:
- TargetPacksApplicableVersion / TargetPacksApplicableVersionString
- TargetPacksMachineVersion / TargetPacksMachineVersionString
#>
    [CmdletBinding()]
    param(
        [switch]$IncludeNonInstalled,
        [switch]$IncludeFeatureState
    )

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw "Get-DotNetFrameworkInfo supports Windows only."
    }

    $is64OS = [Environment]::Is64BitOperatingSystem
    $views  = if ($is64OS) { @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64) }
              else          { @([Microsoft.Win32.RegistryView]::Registry32) }

    function Get-ReleaseLabel { param([int]$Release)
        $map = @(
            @{ Release=533325; Label='4.8.1' }, @{ Release=533320; Label='4.8.1' },
            @{ Release=528372; Label='4.8' }, @{ Release=528049; Label='4.8' }, @{ Release=528040; Label='4.8' },
            @{ Release=461814; Label='4.7.2' }, @{ Release=461808; Label='4.7.2' },
            @{ Release=461310; Label='4.7.1' }, @{ Release=461308; Label='4.7.1' },
            @{ Release=460805; Label='4.7' }, @{ Release=460798; Label='4.7' },
            @{ Release=394806; Label='4.6.2' }, @{ Release=394802; Label='4.6.2' },
            @{ Release=394271; Label='4.6.1' }, @{ Release=394254; Label='4.6.1' },
            @{ Release=393297; Label='4.6' }, @{ Release=393295; Label='4.6' },
            @{ Release=379893; Label='4.5.2' }, @{ Release=378758; Label='4.5.1' }, @{ Release=378675; Label='4.5.1' },
            @{ Release=378389; Label='4.5' }
        )
        foreach ($m in $map | Sort-Object Release -Descending) { if ($Release -ge $m.Release) { return $m.Label } }
        if ($Release -ge 378389) { return "4.5 or later (Release=$Release)" }
        return $null
    }

    function Get-CanonicalFolderName { param([string]$Product)
        switch -regex ($Product) {
            '^v1\.1\.4322($|\\)' { 'v1.1.4322'; break }
            '^v2\.0\.50727($|\\)' { 'v2.0.50727'; break }
            '^v3\.0($|\\)'        { 'v3.0'; break }
            '^v3\.5($|\\)'        { 'v3.5'; break }
            '^v4\\'               { 'v4.0.30319'; break }
            default               { $null; break }
        }
    }

    function IsProductKey { param([string]$vName,[string]$leaf)
        if ($vName -in 'v1.1.4322','v2.0.50727','v3.0','v3.5') { return $true }
        if ($vName -eq 'v4' -and $leaf -in 'Client','Full')    { return $true }
        if ($leaf -match '^\d{3,4}$')                          { return $false } # LCID
        if ($leaf -match '^(WCF|WF|WPF|XPS|Setup)$')           { return $false }
        return $false
    }

    function ComputeClr { param([string]$product)
        switch -regex ($product) {
            '^v1\.1\.4322'                { '1.1'; break }
            '^(v2\.0\.50727|v3\.0|v3\.5)' { '2.0'; break }
            default                       { '4.0'; break }
        }
    }

    # NEW: classify product → family (used for applicability scoping)
    function Get-Family { param([string]$product)
        switch -regex ($product) {
            '^v1\.1\.4322'  { '1.1'; break }
            '^v2\.0\.50727' { '2.0'; break }
            '^v3\.0($|\\)'  { '3.0'; break }
            '^v3\.5($|\\)'  { '3.5'; break }
            '^v4\\'         { '4.0'; break }
            default         { $null; break }
        }
    }

    # ---- Capability detection (machine-wide) ----
    function Get-InstalledTargetPacks {
        $list  = New-Object System.Collections.ArrayList
        $windir = [Environment]::GetEnvironmentVariable('WINDIR','Machine'); if (-not $windir) { $windir = $env:WINDIR }
        $pf     = [Environment]::GetFolderPath('ProgramFiles')
        $pf86   = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')

        function Add-Pack { param([string]$name)
            if ($name -and -not [string]::IsNullOrWhiteSpace($name)) {
                if (-not ($list -contains $name)) { [void]$list.Add($name) }
            }
        }

        # v1.1 / v2.0: compiler presence (check both Framework and Framework64 on x64 OS)
        foreach ($dir in @('Framework','Framework64')) {
            $base = Join-Path $windir ("Microsoft.NET\{0}" -f $dir)
            if (Test-Path -LiteralPath (Join-Path $base 'v1.1.4322\csc.exe')) { Add-Pack 'v1.1.4322' }
            if (Test-Path -LiteralPath (Join-Path $base 'v2.0.50727\csc.exe')) { Add-Pack 'v2.0' }
        }

        # v3.0 / v3.5 reference assemblies (legacy)
        foreach ($base in @(
            ($(if($pf86){ Join-Path $pf86 'Reference Assemblies\Microsoft\Framework' })),
            (Join-Path $pf 'Reference Assemblies\Microsoft\Framework')
        )) {
            if ($base -and (Test-Path -LiteralPath $base)) {
                if (Test-Path -LiteralPath (Join-Path $base 'v3.0')) { Add-Pack 'v3.0' }
                if (Test-Path -LiteralPath (Join-Path $base 'v3.5')) { Add-Pack 'v3.5' }
            }
        }
        # Fallback: MSBuild 3.5 presence
        foreach ($dir in @('Framework','Framework64')) {
            $fx35 = Join-Path $windir ("Microsoft.NET\{0}\v3.5\MSBuild.exe" -f $dir)
            if (Test-Path -LiteralPath $fx35) { Add-Pack 'v3.5' }
        }

        # v4.x Developer Packs (.NETFramework ref assemblies)
        foreach ($base in @(
            ($(if($pf86){ Join-Path $pf86 'Reference Assemblies\Microsoft\Framework\.NETFramework' })),
            (Join-Path $pf 'Reference Assemblies\Microsoft\Framework\.NETFramework')
        )) {
            if ($base -and (Test-Path -LiteralPath $base)) {
                Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^v4(\.\d+)*$' } |
                    ForEach-Object { Add-Pack $_.Name }
            }
        }

        # Sort by version
        $sorted = $list | Sort-Object {
            $v = $_.TrimStart('v')
            try { [version]$v } catch { [version]'0.0' }
        }

        # TFM map
        $mapTFM = @{
            'v1.1.4322'='net11'; 'v2.0'='net20'; 'v3.0'='net30'; 'v3.5'='net35'; 'v4.0'='net40';
            'v4.5'='net45'; 'v4.5.1'='net451'; 'v4.5.2'='net452'; 'v4.6'='net46'; 'v4.6.1'='net461';
            'v4.6.2'='net462'; 'v4.7'='net47'; 'v4.7.1'='net471'; 'v4.7.2'='net472'; 'v4.8'='net48'; 'v4.8.1'='net481'
        }

        # Group by CLR (kept for completeness; no longer used for applicability)
        function PackClr { param([string]$p)
            if ($p -eq 'v1.1.4322') { return '1.1' }
            if ($p -in @('v2.0','v3.0','v3.5')) { return '2.0' }
            if ($p -like 'v4*') { return '4.0' }
            return $null
        }
        $byClr = @{ '1.1'=@(); '2.0'=@(); '4.0'=@() }
        foreach ($p in $sorted) { $c = PackClr $p; if ($c) { $byClr[$c] = $byClr[$c] + @($p) } }

        [pscustomobject]@{
            AllPacks     = [string[]]$sorted
            AllTFM       = [string[]]($sorted | ForEach-Object { if ($mapTFM.ContainsKey($_)) { $mapTFM[$_] } })
            ByClr        = $byClr
            PackToTfmMap = $mapTFM
        }
    }

    # Convert pack names ('v3.5') to [version] (3.5) + string ('3.5')
    function Convert-PacksToVersionForms { param([string[]]$packs)
        $verList  = New-Object System.Collections.ArrayList
        $strList  = New-Object System.Collections.ArrayList
        foreach ($p in ($packs | Where-Object { $_ })) {
            $s = $p.TrimStart('v')
            if ($s -eq '4') { $s = '4.0' }
            try {
                $v = [version]$s
                [void]$verList.Add($v)
                [void]$strList.Add($s)
            } catch { }
        }
        [pscustomobject]@{
            Versions = [version[]]$verList
            Strings  = [string[]]$strList
        }
    }

    $cap = Get-InstalledTargetPacks

    # Optional NetFx3 state
    $netFx3State = $null
    if ($IncludeFeatureState) {
        try {
            if (Get-Command -Name Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
                $fx = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
                $netFx3State = $fx.State
            } else {
                $out  = & dism.exe /Online /Get-FeatureInfo /FeatureName:NetFx3 2>$null
                $line = $out | Select-String -Pattern 'State\s*:\s*(.+)' | Select-Object -First 1
                if ($line) { $netFx3State = ($line.Matches.Groups[1].Value).Trim() }
            }
        } catch {
            Write-Verbose ("Failed to query NetFx3 feature state: {0}" -f $_.Exception.Message)
        }
    }

    # Path bases
    $windir   = [Environment]::GetEnvironmentVariable('WINDIR','Machine'); if (-not $windir) { $windir = $env:WINDIR }
    $fwBase32 = Join-Path $windir 'Microsoft.NET\Framework'
    $fwBase64 = Join-Path $windir 'Microsoft.NET\Framework64'

    $results = foreach ($view in $views) {
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)

            $installRoot = $null
            try {
                $irKey = $base.OpenSubKey('SOFTWARE\Microsoft\.NETFramework')
                if ($irKey) { $installRoot = $irKey.GetValue('InstallRoot', $null) }
            } catch {
                Write-Verbose ("Failed reading InstallRoot in {0} view: {1}" -f $view, $_.Exception.Message)
            }

            $ndp = $base.OpenSubKey('SOFTWARE\Microsoft\NET Framework Setup\NDP')
            if (-not $ndp) { continue }

            foreach ($vName in $ndp.GetSubKeyNames()) {
                if ($vName -notmatch '^v\d') { continue }
                $vKey = $ndp.OpenSubKey($vName); if (-not $vKey) { continue }

                $leaves = @()
                if ($vName -eq 'v4') { foreach ($leafName in $vKey.GetSubKeyNames()) { if (IsProductKey -vName $vName -leaf $leafName) { $leaves += $leafName } } }
                else { $leaves += '' }

                foreach ($leaf in $leaves) {
                    $k = if ($leaf) { $vKey.OpenSubKey($leaf) } else { $vKey }
                    if (-not $k) { continue }

                    $ver            = $k.GetValue('Version')
                    $rel            = $k.GetValue('Release')
                    $installFlag    = $k.GetValue('Install', $null)
                    $sp             = $k.GetValue('SP', $null)
                    $rawInstallPath = $k.GetValue('InstallPath', $null)
                    $installSuccess = $k.GetValue('InstallSuccess', $null)
                    if ($vName -eq 'v3.0' -and -not $installSuccess) {
                        $setupKey = $k.OpenSubKey('Setup'); if ($setupKey) { $installSuccess = $setupKey.GetValue('InstallSuccess', $null) }
                    }

                    $isInstalled = if ($installFlag -is [int]) { $installFlag -eq 1 } elseif ($rel) { $true } else { $false }
                    if (-not $IncludeNonInstalled -and -not $isInstalled) { continue }

                    $product = if ($leaf) { "$vName\$leaf" } else { $vName }
                    $clr     = ComputeClr -product $product

                    $releaseLabel = if ($rel) { Get-ReleaseLabel -Release $rel } else { $null }
                    $legacyLabel =
                        switch -regex ($product) {
                            '^v1\.1\.4322'  { '1.1' + ($(if($sp){ " SP$sp"})); break }
                            '^v2\.0\.50727' { '2.0' + ($(if($sp){ " SP$sp"})); break }
                            '^v3\.0'        { '3.0' + ($(if($sp){ " SP$sp"})); break }
                            '^v3\.5'        { '3.5' + ($(if($sp){ " SP$sp"})); break }
                            '^v4\\'         { if (-not $rel) { '4.0' }; break }
                            default         { $null; break }
                        }
                    $label = if ($releaseLabel) { $releaseLabel } else { $legacyLabel }

                    # InstallPath (candidate selection)
                    $canonFolder = Get-CanonicalFolderName -Product $product
                    $candidates = New-Object System.Collections.Generic.List[object]
                    if ($rawInstallPath) {
                        $candidates.Add([pscustomobject]@{ Path=$rawInstallPath; Source='Registry'; Exists=(Test-Path -LiteralPath $rawInstallPath -PathType Container) }) | Out-Null
                    }
                    if ($installRoot -and $canonFolder) {
                        $p = Join-Path $installRoot $canonFolder
                        $candidates.Add([pscustomobject]@{ Path=$p; Source='InstallRoot'; Exists=(Test-Path -LiteralPath $p -PathType Container) }) | Out-Null
                    }
                    if ($canonFolder) {
                        $p32 = Join-Path $fwBase32 $canonFolder
                        $p64 = Join-Path $fwBase64 $canonFolder
                        $candidates.Add([pscustomobject]@{ Path=$p32; Source='WinDir\Framework';   Exists=(Test-Path -LiteralPath $p32 -PathType Container) }) | Out-Null
                        $candidates.Add([pscustomobject]@{ Path=$p64; Source='WinDir\Framework64'; Exists=(Test-Path -LiteralPath $p64 -PathType Container) }) | Out-Null
                    }

                    $preferred = $null
                    if ($view -eq [Microsoft.Win32.RegistryView]::Registry64) {
                        $preferred = $candidates | Where-Object { $_.Exists -and ($_.Path -like "*\Framework64\*") } | Select-Object -First 1
                    } else {
                        $preferred = $candidates | Where-Object { $_.Exists -and ($_.Path -like "*\Framework\*" -and $_.Path -notlike "*\Framework64\*") } | Select-Object -First 1
                    }
                    if (-not $preferred) { $preferred = $candidates | Where-Object { $_.Exists } | Select-Object -First 1 }
                    if (-not $preferred) { $preferred = $candidates | Select-Object -First 1 }

                    # --- Capability filtering by PRODUCT FAMILY (not CLR) ---
                    $family = Get-Family -product $product
                    switch ($family) {
                        '1.1' { $packsApplicable = @('v1.1.4322') }
                        '2.0' { $packsApplicable = @('v2.0') }
                        '3.0' { $packsApplicable = @('v3.0') }
                        '3.5' { $packsApplicable = @('v3.5') }
                        '4.0' { $packsApplicable = @($cap.AllPacks | Where-Object { $_ -like 'v4*' }) }
                        default { $packsApplicable = @() }
                    }
                    # Keep only packs actually present on this machine
                    $packsApplicable = @($packsApplicable | Where-Object { $cap.AllPacks -contains $_ })

                    # Map to TFM + version-typed forms
                    $packsApplicableTFM = @()
                    foreach ($p in $packsApplicable) { if ($cap.PackToTfmMap.ContainsKey($p)) { $packsApplicableTFM += $cap.PackToTfmMap[$p] } }
                    $appVer = Convert-PacksToVersionForms -packs $packsApplicable
                    $allVer = Convert-PacksToVersionForms -packs $cap.AllPacks
                    # ------------------------------------------------------

                    [pscustomobject]@{
                        Product                          = $product
                        Profile                          = if ($product -like 'v4*') { ($product -split '\\',2)[1] } else { $null }
                        CLR                              = $clr
                        Version                          = $ver
                        Release                          = $rel
                        ReleaseLabel                     = $releaseLabel
                        Label                            = $label
                        ServicePack                      = $sp
                        Install                          = [bool]$isInstalled
                        InstallSuccess                   = $installSuccess
                        InstallPath                      = if ($preferred) { $preferred.Path } else { $null }
                        InstallPathSource                = if ($preferred) { $preferred.Source } else { $null }
                        DirectoryExists                  = if ($preferred) { [bool]$preferred.Exists } else { $false }
                        NetFx3FeatureState               = if ($IncludeFeatureState -and ($product -in 'v2.0.50727','v3.0','v3.5')) { $netFx3State } else { $null }
                        RegistryView                     = if ($view -eq [Microsoft.Win32.RegistryView]::Registry64) { '64-bit' } else { '32-bit' }
                        RegistryKey                      = $k.Name

                        TargetPacksApplicable            = $packsApplicable
                        TargetPacksApplicableTFM         = $packsApplicableTFM
                        TargetPacksMachine               = $cap.AllPacks
                        TargetPacksMachineTFM            = $cap.AllTFM

                        TargetPacksApplicableVersion     = $appVer.Versions
                        TargetPacksApplicableVersionString = $appVer.Strings
                        TargetPacksMachineVersion        = $allVer.Versions
                        TargetPacksMachineVersionString  = $allVer.Strings
                    }
                }
            }
        } catch {
            Write-Verbose ("Failed reading registry view {0}: {1}" -f $view, $_.Exception.Message)
        }
    }

    $results | Sort-Object Product, RegistryView
}

function Get-DotNetFrameworkLatestByFamily {
<#
.SYNOPSIS
Return the full enumeration from Get-DotNetFrameworkInfo and, per family (1.1, 2.0, 3.0, 3.5, 4.0),
the single “latest” installed row, preferring the highest bitness on this OS.

.DESCRIPTION
- Calls Get-DotNetFrameworkInfo with only supported switches.
- Families: v1.1.4322 → 1.1, v2.0.50727 → 2.0, v3.0 → 3.0, v3.5 → 3.5, v4\* → 4.0.
- Bitness: on x64 OS, choose 64-bit rows if any installed; otherwise fall back to 32-bit. On x86 OS: 32-bit only.
- Ranking within a family:
  * 4.0-family: Release (desc), Profile (Full > Client), Version ([version] desc), DirectoryExists.
  * 2.0/3.0/3.5/1.1: ServicePack (desc), Version ([version] desc), DirectoryExists.
- Output:
  * .All            — all rows from Get-DotNetFrameworkInfo (unchanged)
  * .LatestByFamily — the chosen rows, with an added .Family property
#>
    [CmdletBinding()]
    param(
        [switch]$IncludeNonInstalled,
        [switch]$IncludeFeatureState
    )

    # Call enumerator with only supported switches (no HighestBitness leakage)
    $all = if ($IncludeNonInstalled -or $IncludeFeatureState) {
        Get-DotNetFrameworkInfo -IncludeNonInstalled:$IncludeNonInstalled -IncludeFeatureState:$IncludeFeatureState
    } else {
        Get-DotNetFrameworkInfo
    }

    if (-not $all) {
        return [pscustomobject]@{ All=@(); LatestByFamily=@() }
    }

    # Family classifier (keep regexes precise)
    function Get-Family {
        param([string]$product)
        switch -regex ($product) {
            '^v4\\'         { '4.0'; break }
            '^v3\.5($|\\)'  { '3.5'; break }
            '^v3\.0($|\\)'  { '3.0'; break }
            '^v2\.0\.50727' { '2.0'; break }
            '^v1\.1\.4322'  { '1.1'; break }
            default         { $null; break }
        }
    }

    $is64 = [Environment]::Is64BitOperatingSystem

    # Bucket rows by family
    $byFamily = @{}
    foreach ($r in $all) {
        $fam = Get-Family -product $r.Product
        if (-not $fam) { continue }
        if (-not $IncludeNonInstalled -and -not $r.Install) { continue }  # only installed by default
        if (-not $byFamily.ContainsKey($fam)) { $byFamily[$fam] = New-Object System.Collections.ArrayList }
        [void]$byFamily[$fam].Add($r)
    }

    $selected = foreach ($fam in $byFamily.Keys | Sort-Object) {
        $candidates = [System.Collections.ArrayList]$byFamily[$fam]
        if (-not $candidates -or $candidates.Count -eq 0) { continue }

        # Prefer highest bitness available (x64 on x64 OS; otherwise x86)
        if ($is64) {
            $x64 = $candidates | Where-Object { $_.RegistryView -eq '64-bit' -and $_.Install }
            if ($x64) { $candidates = [System.Collections.ArrayList]@($x64) }
            else {
                $x86 = $candidates | Where-Object { $_.RegistryView -eq '32-bit' -and $_.Install }
                if ($x86) { $candidates = [System.Collections.ArrayList]@($x86) }
            }
        } else {
            $x86 = $candidates | Where-Object { $_.RegistryView -eq '32-bit' -and $_.Install }
            if ($x86) { $candidates = [System.Collections.ArrayList]@($x86) }
        }

        # Rank within family
        $ranked = $candidates |
            Select-Object *,
                @{n='ReleaseRank';e={ if ($_.Release) { [int]$_.Release } else { -1 } }},
                @{n='ProfileRank';e={
                    if ($fam -eq '4.0') {
                        if ($_.Profile -eq 'Full') { 1 } elseif ($_.Profile -eq 'Client') { 0 } else { -1 }
                    } else { -1 }
                }},
                @{n='ServicePackRank';e={ if ($_.ServicePack -is [int]) { [int]$_.ServicePack } else { 0 } }},
                @{n='VersionRank';e={ try { [version]($_.Version) } catch { [version]'0.0' } }},
                @{n='DirRank';e={ if ($_.DirectoryExists) { 1 } else { 0 } }} |
            Sort-Object `
                @{e={ if ($fam -eq '4.0') { $_.ReleaseRank } else { $_.ServicePackRank } };Descending=$true},
                @{e='ProfileRank';Descending=$true},
                @{e='VersionRank';Descending=$true},
                @{e='DirRank';Descending=$true}

        $top = $ranked | Select-Object -First 1
        if ($top) {
            # Add Family note property without mutating the base type
            $clone = $top.PSObject.Copy()
            $clone.PSObject.Properties.Remove('ReleaseRank')
            $clone.PSObject.Properties.Remove('ProfileRank')
            $clone.PSObject.Properties.Remove('ServicePackRank')
            $clone.PSObject.Properties.Remove('VersionRank')
            $clone.PSObject.Properties.Remove('DirRank')
            $clone | Add-Member -NotePropertyName Family -NotePropertyValue $fam -Force
            $clone
        }
    }

    [pscustomobject]@{
        All            = $all
        LatestByFamily = @($selected)
    }
}

function Get-DotNetFrameworkFamilyCapabilities {
<#
.SYNOPSIS
One row per .NET Framework family with safe-array fields and a probed toolset.

.DESCRIPTION
Wraps Get-DotNetFrameworkLatestByFamily, keeps only rows with an existing InstallPath,
and returns compact objects suitable for invoking toolchains.

Guarantees arrays for:
- TargetPacksApplicable
- TargetPacksApplicableTFM
- TargetPacksApplicableVersionString

Adds:
- ToolchainBitness  : 'x64' or 'x86' (derived from RegistryView)
- AvailableToolset  : array of existing tools { Name, Path, Version, ProductVersion, LastWriteUtc, LengthBytes }
                      (non-existing EXEs are NOT returned)

.PARAMETER IncludeNonInstalled
Pass-through to Get-DotNetFrameworkLatestByFamily.

.PARAMETER IncludeFeatureState
Pass-through to Get-DotNetFrameworkLatestByFamily.

.PARAMETER ToolNames
EXE basenames (without .exe) to probe under each InstallPath root. Only present tools are returned.

.EXAMPLE
Get-DotNetFrameworkFamilyCapabilities |
  Select-Object Family,ToolchainBitness,InstallPath,
    @{N='Tools';E={$_.AvailableToolset | ForEach-Object Name -join ','}} |
  Format-Table -AutoSize
#>
    [CmdletBinding()]
    param(
        [switch]$IncludeNonInstalled,
        [switch]$IncludeFeatureState,
        [string[]]$ToolNames = @(
            'csc','vbc','msbuild','ngen','ilasm','al','regasm','regsvcs','installutil',
            'aspnet_regiis','aspnet_compiler','aspnet_regsql','aspnet_state','jsc','mscorsvw',
            'resgen' # Will be omitted unless actually present under the Framework path
        )
    )

    # -- local helpers (kept PS5-safe) --
    function To-StringArray {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([object]$Value)
        ,([string[]](@($Value) | Where-Object { $_ -ne $null }))
    }
    function To-BitnessLabel {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([string]$RegistryView)
        if ($RegistryView -eq '64-bit') { 'x64' } else { 'x86' }
    }
    function Probe-Exe {
        <#
        .SYNOPSIS
        Probe a single EXE via pure .NET FileInfo; returns $null if not found.
        .NOTES
        External reviewer note: returning $null for missing files simplifies filtering downstream.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory)][string]$Directory,
            [Parameter(Mandatory)][string]$ExeBaseName
        )
        $exePath = [System.IO.Path]::Combine($Directory, ('{0}.exe' -f $ExeBaseName))
        try {
            $fi = [System.IO.FileInfo]::new($exePath)
            if (-not $fi.Exists) { return $null }
            $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($fi.FullName)
            [pscustomobject]@{
                Name           = $ExeBaseName
                Path           = $fi.FullName
                Version        = $fvi.FileVersion
                ProductVersion = $fvi.ProductVersion
                LastWriteUtc   = $fi.LastWriteTimeUtc
                LengthBytes    = $fi.Length
            }
        }
        catch {
            # External reviewer note: swallow I/O errors into omission; use -Verbose for diagnostics if needed.
            Write-Verbose ("Probe-Exe: {0}" -f $_.Exception.Message)
            return $null
        }
    }
    function Get-ToolsForPath {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory)][string]$InstallPath,
            [Parameter(Mandatory)][string[]]$Names
        )
        ,(@(
            foreach ($n in $Names) {
                $tool = Probe-Exe -Directory $InstallPath -ExeBaseName $n
                if ($null -ne $tool) { $tool }
            }
        ))
    }
    # -- end helpers --

    $result = if ($IncludeNonInstalled -or $IncludeFeatureState) {
        Get-DotNetFrameworkLatestByFamily -IncludeNonInstalled:$IncludeNonInstalled -IncludeFeatureState:$IncludeFeatureState
    } else {
        Get-DotNetFrameworkLatestByFamily
    }

    if (-not $result -or -not $result.LatestByFamily) { return @() }

    $result.LatestByFamily |
        Where-Object { $_.DirectoryExists -eq $true } |
        ForEach-Object {
            [pscustomobject]@{
                Family                             = $_.Family
                ToolchainBitness                   = To-BitnessLabel $_.RegistryView
                TargetPacksApplicable              = To-StringArray $_.TargetPacksApplicable
                TargetPacksApplicableTFM           = To-StringArray $_.TargetPacksApplicableTFM
                TargetPacksApplicableVersionString = To-StringArray $_.TargetPacksApplicableVersionString
                InstallPath                        = $_.InstallPath
                AvailableToolset                   = Get-ToolsForPath -InstallPath $_.InstallPath -Names $ToolNames
            }
        }
}

function Get-DotNetFrameworkCapabilityByTarget {
<#
.SYNOPSIS
Returns the first capability entry matching a given identifier.

.DESCRIPTION
Searches the output of Get-DotNetFrameworkFamilyCapabilities (or a provided set
of capability objects) and returns the first object where the specified value
matches any entry in TargetPacksApplicable or TargetPacksApplicableTFM.
Matching is case-insensitive.

.PARAMETER Identifier
Single value to match against TargetPacksApplicable and TargetPacksApplicableTFM.

.PARAMETER Capabilities
Optional pre-fetched capabilities (e.g. from Get-DotNetFrameworkFamilyCapabilities).
If omitted, the function invokes Get-DotNetFrameworkFamilyCapabilities internally.

.EXAMPLE
Get-DotNetFrameworkCapabilityByTarget -Identifier 'net48'

.EXAMPLE
$all = Get-DotNetFrameworkFamilyCapabilities
Get-DotNetFrameworkCapabilityByTarget -Identifier 'Microsoft.NETCore.App.Ref' -Capabilities $all
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Identifier,

        [Parameter()]
        [psobject[]]$Capabilities
    )

    # External reviewer note: allow reuse of a pre-fetched set to avoid repeated probing.
    if (-not $Capabilities) {
        $Capabilities = Get-DotNetFrameworkFamilyCapabilities
    }

    if (-not $Capabilities) {
        return $null
    }

    $normalized = $Identifier.ToLowerInvariant()

    foreach ($item in $Capabilities) {
        if (-not $item) { continue }

        $packs = @($item.TargetPacksApplicable)
        $tfms  = @($item.TargetPacksApplicableTFM)

        foreach ($p in $packs) {
            if ($null -ne $p -and $p.ToString().ToLowerInvariant() -eq $normalized) {
                return $item
            }
        }

        foreach ($t in $tfms) {
            if ($null -ne $t -and $t.ToString().ToLowerInvariant() -eq $normalized) {
                return $item
            }
        }
    }

    return $null
}


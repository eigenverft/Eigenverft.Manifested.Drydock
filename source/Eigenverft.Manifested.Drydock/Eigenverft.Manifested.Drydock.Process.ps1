function Open-UrlInBrowser {
<#
.SYNOPSIS
Open local HTML files or web URLs (PS 5–7), using default or chosen browser.
#>
    [CmdletBinding(SupportsShouldProcess = $false)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName','LiteralPath')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [switch] $Wait,

        [ValidateSet('Default','Edge','Chrome','Firefox','Safari')]
        [string] $Browser = 'Default',

        [string] $BrowserPath
    )

    # --- Platform detection ---
    $onWindows = ($IsWindows -eq $true) -or ($env:OS -eq 'Windows_NT')
    $onMacOS   = ($IsMacOS  -eq $true) -or ($PSVersionTable.OS -match 'Darwin')
    $onLinux   = ($IsLinux  -eq $true) -or (-not $onWindows -and -not $onMacOS)

    function Resolve-InputToOpenTarget {
        param([Parameter(Mandatory)][string]$InputPath)
        $uri = $null
        if ([Uri]::IsWellFormedUriString($InputPath, [UriKind]::Absolute)) {
            try { $uri = [Uri]$InputPath } catch { $uri = $null }
        }
        if ($uri) {
            if ($uri.Scheme -eq 'file') { return [PSCustomObject]@{ Type='File'; Target=$uri.LocalPath } }
            if ($uri.Scheme -in @('http','https')) { return [PSCustomObject]@{ Type='Web'; Target=$InputPath } }
        }
        try {
            $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
            return [PSCustomObject]@{ Type='File'; Target=$resolved.ProviderPath }
        } catch {
            return [PSCustomObject]@{ Type='File'; Target=$InputPath }
        }
    }

    function Invoke-DefaultOpen([string]$arg, [bool]$isWeb) {
        # Use platform-default opener. IMPORTANT: for web URLs, never call Invoke-Item.
        if ($onWindows) {
            if ($Wait) { Start-Process -FilePath $arg -Wait }
            else       { Start-Process -FilePath $arg | Out-Null }
            return
        }
        elseif ($onMacOS) {
            if ($Wait) { Start-Process -FilePath 'open' -ArgumentList @('-W', $arg) }
            else       { Start-Process -FilePath 'open' -ArgumentList @($arg) }
            return
        }
        elseif ($onLinux) {
            if (Get-Command xdg-open -ErrorAction SilentlyContinue) {
                if ($Wait) { Start-Process -FilePath 'xdg-open' -ArgumentList @($arg) -Wait }
                else       { Start-Process -FilePath 'xdg-open' -ArgumentList @($arg) | Out-Null }
            } else {
                if ($Wait) { Start-Process -FilePath $arg -Wait } else { Start-Process -FilePath $arg | Out-Null }
            }
            return
        }

        # Fallback
        if ($Wait) { Start-Process -FilePath $arg -Wait } else { Start-Process -FilePath $arg | Out-Null }
    }

    function Invoke-WithBrowser([string]$arg, [bool]$isWeb) {
        if ($BrowserPath) {
            if ($Wait) { Start-Process -FilePath $BrowserPath -ArgumentList @($arg) -Wait }
            else       { Start-Process -FilePath $BrowserPath -ArgumentList @($arg) | Out-Null }
            return
        }

        if ($onWindows) {
            function Get-WinBrowserCandidates([string]$name) {
                switch ($name) {
                    'Firefox' { @('firefox', "$env:ProgramFiles\Mozilla Firefox\firefox.exe", "$env:ProgramFiles(x86)\Mozilla Firefox\firefox.exe") }
                    'Chrome'  { @('chrome', "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe") }
                    'Edge'    { @('msedge', "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe") }
                    default   { @() }
                }
            }
            if ($Browser -eq 'Default') { Invoke-DefaultOpen $arg $isWeb; return }

            $primary  = Get-WinBrowserCandidates $Browser
            $others   = @('Firefox','Chrome','Edge') | Where-Object { $_ -ne $Browser }
            $fallback = @(); foreach ($o in $others) { $fallback += Get-WinBrowserCandidates $o }
            $candidates = $primary + $fallback

            $exe = $null
            foreach ($c in $candidates) {
                if ([IO.Path]::IsPathRooted($c)) {
                    if (Test-Path -LiteralPath $c) { $exe = $c; break }
                } else {
                    $cmd = Get-Command $c -ErrorAction SilentlyContinue
                    if ($cmd) { $exe = $cmd.Source; break }
                }
            }
            if (-not $exe) { Invoke-DefaultOpen $arg $isWeb; return }

            if ($Wait) { Start-Process -FilePath $exe -ArgumentList @($arg) -Wait }
            else       { Start-Process -FilePath $exe -ArgumentList @($arg) | Out-Null }
            return
        }

        if ($onMacOS) {
            function Get-MacAppName([string]$name) {
                switch ($name) { 'Firefox' { 'Firefox' } 'Chrome' { 'Google Chrome' } 'Safari' { 'Safari' } default { $null } }
            }
            if ($Browser -eq 'Default') {
                if ($Wait) { Start-Process -FilePath 'open' -ArgumentList @('-W', $arg) }
                else       { Start-Process -FilePath 'open' -ArgumentList @($arg) }
                return
            }

            $primary = Get-MacAppName $Browser
            $others  = @('Firefox','Chrome','Safari') | Where-Object { $_ -ne $Browser }
            $fallbackApps = @(); foreach ($o in $others) { $fallbackApps += (Get-MacAppName $o) }
            $appsToTry = @($primary) + $fallbackApps | Where-Object { $_ }

            foreach ($app in $appsToTry) {
                $cmdArgs = @('-a', $app, $arg); if ($Wait) { $cmdArgs = @('-W') + $cmdArgs }
                try { Start-Process -FilePath 'open' -ArgumentList $cmdArgs; return } catch { continue }
            }
            if ($Wait) { Start-Process -FilePath 'open' -ArgumentList @('-W', $arg) } else { Start-Process -FilePath 'open' -ArgumentList @($arg) }
            return
        }

        if ($onLinux) {
            if ($Browser -eq 'Default') {
                if (Get-Command xdg-open -ErrorAction SilentlyContinue) {
                    if ($Wait) { Start-Process -FilePath 'xdg-open' -ArgumentList @($arg) -Wait }
                    else       { Start-Process -FilePath 'xdg-open' -ArgumentList @($arg) | Out-Null }
                } else {
                    Invoke-DefaultOpen $arg $isWeb
                }
                return
            }
            function Get-LinuxBrowserCandidates([string]$name) {
                switch ($name) {
                    'Firefox' { @('firefox') }
                    'Chrome'  { @('google-chrome','google-chrome-stable','chromium-browser','chromium') }
                    'Edge'    { @('microsoft-edge','microsoft-edge-stable') }
                    default   { @() }
                }
            }
            $primary  = Get-LinuxBrowserCandidates $Browser
            $others   = @('Firefox','Chrome','Edge') | Where-Object { $_ -ne $Browser }
            $fallback = @(); foreach ($o in $others) { $fallback += Get-LinuxBrowserCandidates $o }

            $exe = (@($primary) + $fallback) | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
            if ($exe) {
                if ($Wait) { Start-Process -FilePath $exe -ArgumentList @($arg) -Wait }
                else       { Start-Process -FilePath $exe -ArgumentList @($arg) | Out-Null }
            } else {
                Invoke-DefaultOpen $arg $isWeb
            }
            return
        }

        Invoke-DefaultOpen $arg $isWeb
    }

    foreach ($p in $Path) {
        $target = Resolve-InputToOpenTarget -InputPath $p
        if ($target.Type -eq 'File') {
            try { $item = Get-Item -LiteralPath $target.Target -ErrorAction Stop } catch { throw "File not found or unreadable: $p" }
            if ($item.PSIsContainer) { throw "Expected a file but got a directory: $p" }
            $arg = $item.FullName
            if ($Browser -eq 'Default' -and -not $BrowserPath) { Invoke-DefaultOpen $arg $false } else { Invoke-WithBrowser $arg $false }
        } else {
            $arg = $target.Target
            if ($Browser -eq 'Default' -and -not $BrowserPath) { Invoke-DefaultOpen $arg $true } else { Invoke-WithBrowser $arg $true }
        }
    }
}


# Open-UrlInBrowser -Path 'https://www.powershellgallery.com/packages/Eigenverft.Manifested.Drydock/0.20255.62363/Content/LICENSE.txt' -Browser Default
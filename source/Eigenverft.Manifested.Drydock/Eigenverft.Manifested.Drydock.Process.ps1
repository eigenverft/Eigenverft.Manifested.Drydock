function Open-UrlInBrowser {
<#
.SYNOPSIS
Open local HTML files or web URLs (PS 5–7), using default or chosen browser.

.DESCRIPTION
Accepts inputs like "C:\site\index.html", "./index.html", "/var/www/index.html",
"file:///C:/site/index.html", or web URLs like "https://example.com/page".
Local file inputs (plain path or file://) are normalized to an OS path, verified to exist,
and opened via the selected browser (or default association). Web URLs are passed as-is
to the browser or default opener. Local files are always passed as plain file paths
(never file://).

.PARAMETER Path
One or more inputs; accepts local paths, file:// URIs, or http/https URLs.
Pipeline and FullName supported.

.PARAMETER Wait
Attempts to wait for the spawned process to exit (depends on browser/OS and reuse of an existing process).

.PARAMETER Browser
Optional browser hint: Default, Edge, Chrome, Firefox, Safari. Uses exec names on Windows,
"open" on macOS, and common executables on Linux. The argument is a plain file path for local
files or a URL for web inputs.

.PARAMETER BrowserPath
Explicit path to a browser executable/app. Overrides -Browser. The file path or URL is passed
as the first argument.

.EXAMPLE
Open-UrlInBrowser .\report.html

.EXAMPLE
Open-UrlInBrowser 'file:///C:/sites/demo/index.html' -Browser Chrome

.EXAMPLE
'index.html','file:///home/user/site/about.htm' | Open-UrlInBrowser -Wait

.EXAMPLE
Open-UrlInBrowser 'https://example.com/page' -Browser Edge

.NOTES
- Local files: always pass a plain path (never file://) to the launched process.
- Web URLs: pass the URL as-is.
- No Begin/Process/End blocks; no assignments to automatic variables like $IsWindows or $cmdArgs.
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

    # --- Platform detection (read-only of automatic variables) ---
    $onWindows = ($IsWindows -eq $true) -or ($env:OS -eq 'Windows_NT')
    $onMacOS   = ($IsMacOS  -eq $true) -or ($PSVersionTable.OS -match 'Darwin')
    $onLinux   = ($IsLinux  -eq $true) -or (-not $onWindows -and -not $onMacOS)

    function Resolve-InputToOpenTarget {
        param([Parameter(Mandatory)][string]$InputPath)
        # Returns a PSCustomObject with Type = 'File' or 'Web', and Target = path or url.

        # Try URI first
        $uri = $null
        if ([Uri]::IsWellFormedUriString($InputPath, [UriKind]::Absolute)) {
            try { $uri = [Uri]$InputPath } catch { $uri = $null }
        }

        if ($uri) {
            if ($uri.Scheme -eq 'file') {
                # Local file from file://
                return [PSCustomObject]@{ Type='File'; Target=$uri.LocalPath }
            }
            if ($uri.Scheme -in @('http','https')) {
                # Web URL
                return [PSCustomObject]@{ Type='Web'; Target=$InputPath }
            }
        }

        # Treat as a local path; try to resolve to a provider path
        try {
            $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
            return [PSCustomObject]@{ Type='File'; Target=$resolved.ProviderPath }
        } catch {
            # Leave as-is; existence will be checked later
            return [PSCustomObject]@{ Type='File'; Target=$InputPath }
        }
    }

    function Invoke-DefaultOpen([string]$arg, [bool]$isWeb) {
        # Use OS association (works for both files and URLs).
        if ($onWindows -or $onLinux) {
            if ($Wait) {
                Start-Process -FilePath $arg -Wait
            } else {
                try { Invoke-Item -LiteralPath $arg } catch { Start-Process -FilePath $arg | Out-Null }
            }
        } elseif ($onMacOS) {
            # macOS "open" can take files or URLs
            if ($Wait) {
                Start-Process -FilePath 'open' -ArgumentList @('-W', $arg)
            } else {
                Start-Process -FilePath 'open' -ArgumentList @($arg)
            }
        } else {
            # Fallback
            if ($Wait) { Start-Process -FilePath $arg -Wait } else { Start-Process -FilePath $arg | Out-Null }
        }
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
                    'Firefox' {
                        @(
                            'firefox',
                            "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
                            "$env:ProgramFiles(x86)\Mozilla Firefox\firefox.exe"
                        )
                    }
                    'Chrome' {
                        @(
                            'chrome',
                            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                            "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe"
                        )
                    }
                    'Edge' {
                        @(
                            'msedge',
                            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                            "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe"
                        )
                    }
                    default { @() }
                }
            }

            # If a specific browser is requested, try it first; otherwise use OS default.
            if ($Browser -eq 'Default') {
                Invoke-DefaultOpen $arg $isWeb
                return
            }

            # Primary candidates = requested browser
            $primary = Get-WinBrowserCandidates $Browser

            # Fallback list: first existing among the "other" browsers
            $others = @('Firefox','Chrome','Edge') | Where-Object { $_ -ne $Browser }
            $fallback = @()
            foreach ($o in $others) { $fallback += Get-WinBrowserCandidates $o }

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
            # Map requested browser to app name, then fallback order if not installed
            function Get-MacAppName([string]$name) {
                switch ($name) {
                    'Firefox' { 'Firefox' }
                    'Chrome'  { 'Google Chrome' }
                    'Safari'  { 'Safari' }
                    default   { $null }
                }
            }

            if ($Browser -eq 'Default') {
                if ($Wait) { Start-Process -FilePath 'open' -ArgumentList @('-W', $arg) }
                else       { Start-Process -FilePath 'open' -ArgumentList @($arg) }
                return
            }

            $primary = Get-MacAppName $Browser
            $others  = @('Firefox','Chrome','Safari') | Where-Object { $_ -ne $Browser }
            $fallbackApps = @()
            foreach ($o in $others) { $fallbackApps += (Get-MacAppName $o) }

            $appsToTry = @($primary) + $fallbackApps | Where-Object { $_ }

            foreach ($app in $appsToTry) {
                $cmdArgs = @('-a', $app, $arg)
                if ($Wait) { $cmdArgs = @('-W') + $cmdArgs }
                try {
                    Start-Process -FilePath 'open' -ArgumentList $cmdArgs
                    return
                } catch { continue }
            }

            # Last resort
            if ($Wait) { Start-Process -FilePath 'open' -ArgumentList @('-W', $arg) }
            else       { Start-Process -FilePath 'open' -ArgumentList @($arg) }
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

            # Build candidate lists per requested, then fallbacks
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
            $fallback = @()
            foreach ($o in $others) { $fallback += Get-LinuxBrowserCandidates $o }

            $exe = (@($primary) + $fallback) |
                Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
                Select-Object -First 1

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
        # Normalize input (file://, plain path, or http/https URL) to an open target.
        $target = Resolve-InputToOpenTarget -InputPath $p

        if ($target.Type -eq 'File') {
            # Verify existence and ensure it's a file, not a directory.
            try {
                $item = Get-Item -LiteralPath $target.Target -ErrorAction Stop
            } catch {
                throw "File not found or unreadable: $p"
            }
            if ($item.PSIsContainer) { throw "Expected a file but got a directory: $p" }

            # Always pass a plain, fully-qualified path for local files.
            $arg = $item.FullName
            if ($Browser -eq 'Default' -and -not $BrowserPath) { Invoke-DefaultOpen $arg $false }
            else                                              { Invoke-WithBrowser $arg $false }
        }
        else {
            # Web URL: pass as-is to default opener or chosen browser.
            $arg = $target.Target
            if ($Browser -eq 'Default' -and -not $BrowserPath) { Invoke-DefaultOpen $arg $true }
            else                                              { Invoke-WithBrowser $arg $true }
        }
    }
}


#Open-UrlInBrowser -Path 'https://www.powershellgallery.com/packages/Eigenverft.Manifested.Drydock/0.20255.62363/Content/LICENSE.txt' -Browser Firefox
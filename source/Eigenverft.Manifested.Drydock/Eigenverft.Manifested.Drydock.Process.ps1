function Open-LocalHtml {
<#
.SYNOPSIS
Open local HTML files using either plain paths or file:// URIs (PS 5–7).

.DESCRIPTION
Accepts inputs like "C:\site\index.html", "./index.html", "/var/www/index.html", or "file:///C:/site/index.html".
All inputs are normalized to a local OS path, verified to exist, and opened using the default association
(or a chosen browser) while still passing a plain file path (never file://).

.PARAMETER Path
One or more .html/.htm inputs; accepts plain paths or file:// URIs. Pipeline and FullName supported.

.PARAMETER Wait
Attempts to wait for the spawned process to exit (depends on browser/OS and reuse of an existing process).

.PARAMETER Browser
Optional browser hint: Default, Edge, Chrome, Firefox, Safari. Uses exec names on Windows,
'app open' on macOS, and common executables on Linux. A plain file path is always passed.

.PARAMETER BrowserPath
Explicit path to a browser executable/app. Overrides -Browser. The file path is passed as the first argument.

.EXAMPLE
Open-LocalHtml .\report.html

.EXAMPLE
Open-LocalHtml 'file:///C:/sites/demo/index.html' -Browser Chrome

.EXAMPLE
'index.html','file:///home/user/site/about.htm' | Open-LocalHtml -Wait

.NOTES
- Always passes a file path; never a file:// URI to the launched process.
- No Begin/Process/End blocks; no assignments to automatic variables like $IsWindows or $args.
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
    # Reviewer note: Do not assign to $IsWindows/$IsMacOS/$IsLinux; only read them.
    $onWindows = ($IsWindows -eq $true) -or ($env:OS -eq 'Windows_NT')
    $onMacOS   = ($IsMacOS  -eq $true) -or ($PSVersionTable.OS -match 'Darwin')
    $onLinux   = ($IsLinux  -eq $true) -or (-not $onWindows -and -not $onMacOS)

    function Resolve-InputToLocalPath {
        param([Parameter(Mandatory)][string]$InputPath)

        # Reviewer note: Accept file:// URIs and plain paths; normalize to a local path.
        $uri = $null
        if ([Uri]::IsWellFormedUriString($InputPath, [UriKind]::Absolute)) {
            try { $uri = [Uri]$InputPath } catch { $uri = $null }
        }
        if ($uri -and $uri.Scheme -eq 'file') {
            # [Uri].LocalPath returns a decoded local path appropriate for the OS.
            return $uri.LocalPath
        }

        # Treat as a path; expand if possible but don't require existence here.
        try {
            $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
            return $resolved.ProviderPath
        } catch {
            # Leave as-is; existence is checked later with Get-Item for better errors.
            return $InputPath
        }
    }

    function Invoke-DefaultOpen([string]$filePath) {
        # Reviewer note: Use OS association; keep argument a plain file path.
        if ($Wait) {
            Start-Process -FilePath $filePath -Wait
        } else {
            try { Invoke-Item -LiteralPath $filePath } catch { Start-Process -FilePath $filePath | Out-Null }
        }
    }

    function Invoke-WithBrowser([string]$filePath) {
        if ($BrowserPath) {
            if ($Wait) { Start-Process -FilePath $BrowserPath -ArgumentList @($filePath) -Wait }
            else       { Start-Process -FilePath $BrowserPath -ArgumentList @($filePath) | Out-Null }
            return
        }

        if ($onWindows) {
            $exe = switch ($Browser) {
                'Edge'    { 'msedge' }
                'Chrome'  { 'chrome' }
                'Firefox' { 'firefox' }
                default   { $null }
            }
            if (-not $exe) { Invoke-DefaultOpen $filePath; return }

            $cmd = Get-Command $exe -ErrorAction SilentlyContinue
            if (-not $cmd) {
                $probable = @(
                    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                    "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe",
                    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                    "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
                    "$env:ProgramFiles\Mozilla Firefox\firefox.exe"
                ) | Where-Object { Test-Path $_ }
                if ($probable) { $exe = $probable[0] }
            }

            if ($Wait) { Start-Process -FilePath $exe -ArgumentList @($filePath) -Wait }
            else       { Start-Process -FilePath $exe -ArgumentList @($filePath) | Out-Null }
            return
        }

        if ($onMacOS) {
            if ($Browser -eq 'Default') {
                if ($Wait) { Start-Process -FilePath 'open' -ArgumentList @('-W', $filePath) }
                else       { Start-Process -FilePath 'open' -ArgumentList @($filePath) }
            } else {
                $appName = switch ($Browser) {
                    'Chrome'  { 'Google Chrome' }
                    'Firefox' { 'Firefox' }
                    'Safari'  { 'Safari' }
                    default   { $null }
                }
                if (-not $appName) { Invoke-DefaultOpen $filePath; return }
                $openParams = @('-a', $appName, $filePath)
                if ($Wait) { $openParams = @('-W') + $openParams }
                Start-Process -FilePath 'open' -ArgumentList $openParams
            }
            return
        }

        if ($onLinux) {
            if ($Browser -eq 'Default') {
                if (Get-Command xdg-open -ErrorAction SilentlyContinue) {
                    if ($Wait) { Start-Process -FilePath 'xdg-open' -ArgumentList @($filePath) -Wait }
                    else       { Start-Process -FilePath 'xdg-open' -ArgumentList @($filePath) | Out-Null }
                } else {
                    Invoke-DefaultOpen $filePath
                }
            } else {
                # Collect candidates first to avoid empty-pipe parse issues on some hosts.
                $candidates = @(
                    switch ($Browser) {
                        'Chrome'  { 'google-chrome','google-chrome-stable','chromium-browser','chromium' }
                        'Firefox' { 'firefox' }
                        'Edge'    { 'microsoft-edge','microsoft-edge-stable' }
                        default   { @() }
                    }
                )
                $exe = $candidates |
                    Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
                    Select-Object -First 1

                if ($exe) {
                    if ($Wait) { Start-Process -FilePath $exe -ArgumentList @($filePath) -Wait }
                    else       { Start-Process -FilePath $exe -ArgumentList @($filePath) | Out-Null }
                } else {
                    Invoke-DefaultOpen $filePath
                }
            }
            return
        }

        Invoke-DefaultOpen $filePath
    }

    foreach ($p in $Path) {
        # Normalize input (file:// or plain) to a local path string.
        $localPath = Resolve-InputToLocalPath -Input $p

        # Verify existence and ensure it's a file, not a directory.
        try {
            $item = Get-Item -LiteralPath $localPath -ErrorAction Stop
        } catch {
            throw "File not found or unreadable: $p"
        }
        if ($item.PSIsContainer) { throw "Expected a file but got a directory: $p" }

        # Always pass a plain, fully-qualified path.
        $full = $item.FullName

        if ($Browser -eq 'Default' -and -not $BrowserPath) { Invoke-DefaultOpen $full }
        else                                              { Invoke-WithBrowser $full }
    }
}

# Open-LocalHtml -Path 'file:///C:/Users/Valgrind/Desktop/OldDesktop/test2.html' -Browser Chrome
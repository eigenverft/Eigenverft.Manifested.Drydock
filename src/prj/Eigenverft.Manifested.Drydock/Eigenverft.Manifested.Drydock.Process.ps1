function Open-UrlInBrowser {
<#
.SYNOPSIS
Opens local HTML files or web URLs using the default or a selected browser on Windows, macOS, and Linux (PS 5.1 and PS 7+).

.DESCRIPTION
Resolves each provided input to either a local file or a web URL (http/https).
Uses the platform’s default opener when -Browser 'Default' is chosen; otherwise tries the selected browser.
Fails fast with actionable errors when required external tools are unavailable (macOS 'open', Linux 'xdg-open')
or when a specific browser was requested but not found.
Designed to be idempotent and minimally chatty; emits a single Write-Host line per opened target.

.PARAMETER Path
One or more file paths or URLs. Supports absolute and relative file paths, as well as http/https/file URIs.

.PARAMETER Wait
Waits for the launched process (or app on macOS) to exit before returning.

.PARAMETER Browser
Which browser to use. 'Default' uses the OS default; otherwise a specific browser is attempted.
Supported values: Default, Edge, Chrome, Firefox, Safari (Safari is macOS only).

.PARAMETER BrowserPath
Explicit path or command to a browser. On macOS, this may be either an app name/path suitable for 'open -a'
(e.g., 'Safari' or '/Applications/Firefox.app') or a direct binary path
(e.g., '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome').

.EXAMPLE
Open-UrlInBrowser 'https://example.org'
Opens the URL with the default browser on the current platform.

.EXAMPLE
Open-UrlInBrowser -Path '.\docs\index.html' -Wait
Opens a local HTML file with the default browser and waits until the browser process (or app) closes.

.EXAMPLE
# Windows-only example
Open-UrlInBrowser -Path 'https://contoso.com' -Browser Edge
Opens the URL explicitly with Microsoft Edge on Windows; fails fast if Edge is not available.

.EXAMPLE
# macOS-only example
Open-UrlInBrowser -Path 'https://contoso.com' -Browser Safari
Opens the URL with Safari via 'open -a'; fails fast if 'open' is unavailable.

.EXAMPLE
# Linux example
Open-UrlInBrowser -Path '/home/user/site/index.html' -Browser Firefox
Opens a local file in Firefox on Linux; fails fast if Firefox is not found.

.NOTES
- Idempotent: no stateful changes are made; repeated invocations produce the same external action.
- Logging: emits a concise Write-Host per open action only.
- No SupportsShouldProcess and no pipeline binding by design (per policy).
#>
    [CmdletBinding()] # Intentionally omits SupportsShouldProcess per policy
    param(
        [Parameter(Mandatory, Position = 0)]
        [Alias('FullName','LiteralPath')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [switch] $Wait,

        [ValidateSet('Default','Edge','Chrome','Firefox','Safari')]
        [string] $Browser = 'Default',

        [string] $BrowserPath
    )

    # --- Inline helpers (local scope, deterministic, no pipeline writes) ---

    function local:_Get-Platform {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param()
        # Use RuntimeInformation when available (PS7+/newer frameworks). Fallback to env vars.
        $ri = [type]::GetType('System.Runtime.InteropServices.RuntimeInformation')
        if ($ri) {
            $win = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
            $osx = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)
            $lin = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)
        } else {
            $win = ($env:OS -eq 'Windows_NT')
            $osx = $false
            $lin = -not $win
        }
        return [PSCustomObject]@{ Windows = $win; MacOS = $osx; Linux = $lin }
    }

    function local:_Resolve-Target {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([Parameter(Mandatory)][string]$InputPath)

        # Prefer URL if clearly absolute and http/https/file
        $u = $null
        if ([Uri]::TryCreate($InputPath, [UriKind]::Absolute, [ref]$u)) {
            if ($u.Scheme -eq 'file') { return [PSCustomObject]@{ Kind='File'; Value=$u.LocalPath } }
            if ($u.Scheme -in @('http','https')) { return [PSCustomObject]@{ Kind='Web';  Value=$InputPath } }
        }

        # Resolve local file path; reject directories, fail clearly if missing
        try {
            $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
            $item = Get-Item -LiteralPath $resolved.ProviderPath -ErrorAction Stop
        } catch {
            throw "File not found or invalid URL: $InputPath"
        }
        if ($item.PSIsContainer) { throw "Expected a file but got a directory: $InputPath" }
        return [PSCustomObject]@{ Kind='File'; Value=$item.FullName }
    }

    function local:_Ensure-External {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory)][bool]$OnMac,
            [Parameter(Mandatory)][bool]$OnLinux
        )
        if ($OnMac) {
            if (-not (Get-Command -Name 'open' -ErrorAction SilentlyContinue)) {
                throw "Missing required tool 'open'. On macOS, ensure command-line tools are available (the 'open' utility is standard)."
            }
        }
        if ($OnLinux) {
            if (-not (Get-Command -Name 'xdg-open' -ErrorAction SilentlyContinue)) {
                throw "Missing required tool 'xdg-open'. Install package 'xdg-utils' via your distro's package manager."
            }
        }
    }

    function local:_Get-BrowserCommand {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory)][string]$Browser,
            [Parameter(Mandatory)][bool]$OnWindows,
            [Parameter(Mandatory)][bool]$OnMac,
            [Parameter(Mandatory)][bool]$OnLinux,
            [string]$BrowserPath
        )

        # Explicit path/command preferred when provided
        if ($BrowserPath) {
            if ($OnMac -and ($BrowserPath -like '*.app' -or $BrowserPath -eq 'Safari' -or $BrowserPath -eq 'Firefox' -or $BrowserPath -eq 'Google Chrome')) {
                return [PSCustomObject]@{ Mode='MacApp'; App=$BrowserPath }
            }
            # For direct binaries or commands, try to resolve presence when possible
            $cmd = Get-Command -Name $BrowserPath -ErrorAction SilentlyContinue
            if ($cmd) { return [PSCustomObject]@{ Mode='Exe'; Path=$cmd.Source } }
            if (Test-Path -LiteralPath $BrowserPath) { return [PSCustomObject]@{ Mode='Exe'; Path=$BrowserPath } }
            throw "BrowserPath '$BrowserPath' not found. Provide a valid app/binary path or command."
        }

        if ($Browser -eq 'Default') { return [PSCustomObject]@{ Mode='Default' } }

        if ($OnWindows) {
            $cands = switch ($Browser) {
                'Edge'    { @('msedge.exe', "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe") }
                'Chrome'  { @('chrome.exe', "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe") }
                'Firefox' { @('firefox.exe', "$env:ProgramFiles\Mozilla Firefox\firefox.exe", "$env:ProgramFiles(x86)\Mozilla Firefox\firefox.exe") }
                default   { @() }
            }
            foreach ($c in $cands) {
                $cmd = Get-Command -Name $c -ErrorAction SilentlyContinue
                if ($cmd) { return [PSCustomObject]@{ Mode='Exe'; Path=$cmd.Source } }
                if ([IO.Path]::IsPathRooted($c) -and (Test-Path -LiteralPath $c)) { return [PSCustomObject]@{ Mode='Exe'; Path=$c } }
            }
            throw "Requested browser '$Browser' was not found on Windows. Install it or use -BrowserPath."
        }

        if ($OnMac) {
            $app = switch ($Browser) {
                'Safari'  { 'Safari' }
                'Chrome'  { 'Google Chrome' }
                'Firefox' { 'Firefox' }
                default   { $null }
            }
            if (-not $app) { throw "Requested browser '$Browser' is not available on macOS." }
            return [PSCustomObject]@{ Mode='MacApp'; App=$app }
        }

        if ($OnLinux) {
            $cands = switch ($Browser) {
                'Chrome'  { @('google-chrome','google-chrome-stable','chromium-browser','chromium') }
                'Firefox' { @('firefox') }
                'Edge'    { @('microsoft-edge','microsoft-edge-stable') }
                default   { @() }
            }
            foreach ($c in $cands) {
                $cmd = Get-Command -Name $c -ErrorAction SilentlyContinue
                if ($cmd) { return [PSCustomObject]@{ Mode='Exe'; Path=$cmd.Source } }
            }
            throw "Requested browser '$Browser' was not found on Linux. Install it or use -BrowserPath."
        }

        return [PSCustomObject]@{ Mode='Default' }
    }

    # --- Execution ---
    $plat = local:_Get-Platform
    local:_Ensure-External -OnMac:$($plat.MacOS) -OnLinux:$($plat.Linux)

    foreach ($raw in $Path) {
        $t = local:_Resolve-Target -InputPath $raw
        $cmd = local:_Get-BrowserCommand -Browser $Browser -OnWindows:$($plat.Windows) -OnMac:$($plat.MacOS) -OnLinux:$($plat.Linux) -BrowserPath $BrowserPath

        if ($cmd.Mode -eq 'Default') {
            if ($plat.Windows) {
                if ($Wait) { Start-Process -FilePath $t.Value -Wait } else { Start-Process -FilePath $t.Value | Out-Null }
            } elseif ($plat.MacOS) {
                $cmdArgs = @($t.Value)
                if ($Wait) { $cmdArgs = @('-W') + $cmdArgs }
                Start-Process -FilePath 'open' -ArgumentList $cmdArgs | Out-Null
            } elseif ($plat.Linux) {
                if ($Wait) { Start-Process -FilePath 'xdg-open' -ArgumentList @($t.Value) -Wait } else { Start-Process -FilePath 'xdg-open' -ArgumentList @($t.Value) | Out-Null }
            } else {
                if ($Wait) { Start-Process -FilePath $t.Value -Wait } else { Start-Process -FilePath $t.Value | Out-Null }
            }
            Write-Host ("Opening {0} with default browser: {1}" -f $t.Kind, $t.Value)
            continue
        }

        if ($plat.MacOS -and $cmd.Mode -eq 'MacApp') {
            $cmdArgs = @('-a', $cmd.App, $t.Value)
            if ($Wait) { $cmdArgs = @('-W') + $cmdArgs }
            Start-Process -FilePath 'open' -ArgumentList $cmdArgs | Out-Null
            Write-Host ("Opening {0} with {1}: {2}" -f $t.Kind, $cmd.App, $t.Value)
            continue
        }

        # Executable path or resolved command on any platform
        $exe = $cmd.Path
        if (-not $exe) { throw "Internal resolution error: browser command could not be determined." }
        if ($Wait) { Start-Process -FilePath $exe -ArgumentList @($t.Value) -Wait } else { Start-Process -FilePath $exe -ArgumentList @($t.Value) | Out-Null }
        Write-Host ("Opening {0} with {1}: {2}" -f $t.Kind, $exe, $t.Value)
    }
}


#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-ExternalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-SiteStatePath {
    param(
        [Parameter(Mandatory)]
        [uri]$Uri,

        [string]$SessionId
    )

    $siteId = if ($SessionId) {
        ($SessionId.ToLowerInvariant() -replace '[^a-z0-9._-]', '_')
    } else {
        ($Uri.Authority.ToLowerInvariant() -replace '[^a-z0-9._-]', '_')
    }

    return Join-Path $env:LOCALAPPDATA ("Eigenverft.Manifested.Drydock\PlaywrightAuthTest\Sites\{0}\state.json" -f $siteId)
}

function Add-PlaywrightCookieToSession {
    param(
        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,

        [Parameter(Mandatory)]
        [object]$CookieState
    )

    $cookie = New-Object System.Net.Cookie
    $cookie.Name = [string]$CookieState.name
    $cookie.Value = [string]$CookieState.value
    $cookie.Path = if ($CookieState.path) { [string]$CookieState.path } else { '/' }
    $cookie.Domain = [string]$CookieState.domain
    $cookie.Secure = [bool]$CookieState.secure
    $cookie.HttpOnly = [bool]$CookieState.httpOnly

    if ($CookieState.expires) {
        try {
            $expiresSeconds = [int64][Math]::Floor([double]$CookieState.expires)
            if ($expiresSeconds -gt 0) {
                $cookie.Expires = [DateTimeOffset]::FromUnixTimeSeconds($expiresSeconds).UtcDateTime
            }
        } catch {
        }
    }

    $Session.Cookies.Add($cookie)
}

function New-WebRequestSessionFromBrowserLogin {
<#
.SYNOPSIS
Open a real browser for site login when needed and return a WebRequestSession from the saved cookies.

.DESCRIPTION
This standalone test helper writes a tiny SDK-style .NET Framework 4.6.1 console app
under LocalAppData, restores Microsoft.Playwright, launches Microsoft Edge for manual
sign-in when needed, saves Playwright storage state per site, and then converts the
saved cookies into a Microsoft.PowerShell.Commands.WebRequestSession.

Only cookies are bridged into the returned WebRequestSession. Browser-only state such
as localStorage, sessionStorage, IndexedDB, and JavaScript-generated headers is not
carried over into Invoke-WebRequest.

.PARAMETER Url
The site URL to open and test.

.PARAMETER ReadyUrl
Optional literal URL prefix used to decide that login succeeded. This is the easier
option when you want to pass a normal URL string without regex escaping.

.PARAMETER ReadyUrlRegex
Optional regex used to decide that login succeeded. Use this only when a literal
ReadyUrl is not flexible enough. If both ReadyUrl and ReadyUrlRegex are omitted,
the helper treats a same-origin URL that does not look like a login page as success.

.PARAMETER ForceLogin
Ignores cached auth state and always opens a fresh browser login.

.PARAMETER SessionId
Optional storage folder name used to separate saved browser state from other test sessions.
If omitted, the site host name is used.

.EXAMPLE
PS> $session = New-WebRequestSessionFromBrowserLogin -Url 'https://example.corp/' -ReadyUrl 'https://example.corp/profile'
PS> Invoke-WebRequest -Uri 'https://example.corp/' -WebSession $session

.EXAMPLE
PS> $session = New-WebRequestSessionFromBrowserLogin -Url 'https://example.corp/' -ReadyUrlRegex '^https://example\.corp/'
PS> Invoke-WebRequest -Uri 'https://example.corp/' -WebSession $session
#>
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [string]$ReadyUrl,

        [string]$ReadyUrlRegex,

        [string]$SessionId,

        [switch]$ForceLogin
    )

    if (-not (Test-ExternalCommand -Name 'dotnet')) {
        throw '.NET SDK is required. Install the .NET SDK first.'
    }

    if ($ReadyUrl -and $ReadyUrlRegex) {
        throw 'Use either -ReadyUrl or -ReadyUrlRegex, not both.'
    }

    $uri = [uri]$Url
    $statePath = Get-SiteStatePath -Uri $uri -SessionId $SessionId
    $stateDirectory = Split-Path -Parent $statePath
    if ($stateDirectory -and -not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $toolRoot = Join-Path $env:LOCALAPPDATA 'Eigenverft.Manifested.Drydock\PlaywrightAuthTest\Tool'
    if (-not (Test-Path -LiteralPath $toolRoot)) {
        New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    }

    $projectPath = Join-Path $toolRoot 'PlaywrightAuthTool.csproj'
    $programPath = Join-Path $toolRoot 'Program.cs'

    $csprojText = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net461</TargetFramework>
    <LangVersion>latest</LangVersion>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.Playwright" Version="1.58.0" />
    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies.net461" Version="1.0.3" PrivateAssets="All" />
  </ItemGroup>
</Project>
'@

    $programText = @'
using System.Text.RegularExpressions;
using Microsoft.Playwright;

var options = RunnerOptions.Parse(args);
var runner = new PlaywrightAuthRunner(options);
return await runner.RunAsync();

internal sealed class RunnerOptions
{
    public string Url { get; set; }
    public string StatePath { get; set; }
    public string ReadyUrl { get; set; }
    public string ReadyUrlRegex { get; set; }
    public int TimeoutSeconds { get; set; }
    public bool ForceLogin { get; set; }

    public static RunnerOptions Parse(string[] args)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var forceLogin = false;

        for (var i = 0; i < args.Length; i++)
        {
            var current = args[i];
            if (string.Equals(current, "--force-login", StringComparison.OrdinalIgnoreCase))
            {
                forceLogin = true;
                continue;
            }

            if (!current.StartsWith("--", StringComparison.Ordinal))
                throw new ArgumentException($"Unexpected argument: {current}");

            if (i + 1 >= args.Length)
                throw new ArgumentException($"Missing value for argument: {current}");

            map[current] = args[++i];
        }

        if (!map.TryGetValue("--url", out var url) || string.IsNullOrWhiteSpace(url))
            throw new ArgumentException("Missing required argument --url");

        if (!map.TryGetValue("--state-path", out var statePath) || string.IsNullOrWhiteSpace(statePath))
            throw new ArgumentException("Missing required argument --state-path");

        var timeoutSeconds = 600;
        if (map.TryGetValue("--timeout-seconds", out var timeoutText) &&
            !int.TryParse(timeoutText, out timeoutSeconds))
        {
            throw new ArgumentException("Invalid integer value for --timeout-seconds");
        }

        return new RunnerOptions
        {
            Url = url,
            StatePath = statePath,
            ReadyUrl = map.TryGetValue("--ready-url", out var readyUrl) ? readyUrl : null,
            ReadyUrlRegex = map.TryGetValue("--ready-url-regex", out var readyRegex) ? readyRegex : null,
            TimeoutSeconds = timeoutSeconds,
            ForceLogin = forceLogin
        };
    }
}

internal sealed class PlaywrightAuthRunner
{
    private static readonly Regex LoginUrlHints =
        new("(login|sign-?in|oauth|authorize|saml)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private const int SavedStateSettleSeconds = 8;

    private readonly RunnerOptions _options;

    public PlaywrightAuthRunner(RunnerOptions options)
    {
        _options = options;
    }

    public async Task<int> RunAsync()
    {
        try
        {
            var stateDirectory = Path.GetDirectoryName(_options.StatePath);
            if (!string.IsNullOrWhiteSpace(stateDirectory))
                Directory.CreateDirectory(stateDirectory);

            using var playwright = await Playwright.CreateAsync();
            await using var browser = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
            {
                Headless = false,
                Channel = "msedge"
            });

            IBrowserContext context = null;
            try
            {
                if (!_options.ForceLogin && File.Exists(_options.StatePath))
                {
                    context = await browser.NewContextAsync(new BrowserNewContextOptions
                    {
                        StorageStatePath = _options.StatePath
                    });

                    var page = await context.NewPageAsync();
                    var savedAttempt = await NavigateAndCheckAsync(page, SavedStateSettleSeconds);
                    if (savedAttempt.IsAuthenticated)
                    {
                        Console.WriteLine("[INFO] Reused saved authentication state.");
                        return 0;
                    }

                    Console.WriteLine($"[INFO] Saved-state probe ended on: {savedAttempt.CurrentUrl}");
                    Console.WriteLine("[INFO] Saved authentication state no longer works. Fresh login is required.");
                    await context.CloseAsync();
                    context = null;
                }

                context = await browser.NewContextAsync();
                var loginPage = await context.NewPageAsync();

                Console.WriteLine("[INFO] Opening Microsoft Edge for interactive login...");
                await loginPage.GotoAsync(_options.Url, new PageGotoOptions
                {
                    WaitUntil = WaitUntilState.DOMContentLoaded
                });

                Console.WriteLine("[INFO] Complete login in the browser window. Waiting for the protected site to become available...");
                var finalUrl = await WaitForInteractiveLoginAsync(loginPage);

                await context.StorageStateAsync(new BrowserContextStorageStateOptions
                {
                    Path = _options.StatePath
                });

                Console.WriteLine($"[INFO] Authentication saved to: {_options.StatePath}");
                Console.WriteLine($"[INFO] Final authenticated URL: {finalUrl}");
                return 0;
            }
            finally
            {
                if (context is not null)
                    await context.CloseAsync();
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ERR] {ex.Message}");
            return 1;
        }
    }

    private async Task<NavigationAttempt> NavigateAndCheckAsync(IPage page, int settleSeconds = 0)
    {
        await page.GotoAsync(GetProbeUrl(), new PageGotoOptions
        {
            WaitUntil = WaitUntilState.DOMContentLoaded
        });

        var currentUrl = page.Url;
        if (IsAuthenticatedUrl(currentUrl))
            return new NavigationAttempt(currentUrl, true);

        if (settleSeconds > 0)
        {
            var deadline = DateTimeOffset.UtcNow.AddSeconds(settleSeconds);
            while (DateTimeOffset.UtcNow < deadline)
            {
                await page.WaitForTimeoutAsync(1000);
                currentUrl = page.Url;
                if (IsAuthenticatedUrl(currentUrl))
                    return new NavigationAttempt(currentUrl, true);
            }
        }

        currentUrl = page.Url;
        return new NavigationAttempt(currentUrl, IsAuthenticatedUrl(currentUrl));
    }

    private async Task<string> WaitForInteractiveLoginAsync(IPage page)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(_options.TimeoutSeconds);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (IsAuthenticatedUrl(page.Url))
                return page.Url;

            await page.WaitForTimeoutAsync(1500);
        }

        throw new TimeoutException("Timed out waiting for manual login to complete.");
    }

    private bool IsAuthenticatedUrl(string currentUrl)
    {
        if (string.IsNullOrWhiteSpace(currentUrl))
            return false;

        if (!string.IsNullOrWhiteSpace(_options.ReadyUrl))
            return MatchesReadyUrl(currentUrl);

        if (!string.IsNullOrWhiteSpace(_options.ReadyUrlRegex))
            return Regex.IsMatch(currentUrl, _options.ReadyUrlRegex, RegexOptions.IgnoreCase);

        var targetOrigin = new Uri(_options.Url).GetLeftPart(UriPartial.Authority);
        return currentUrl.StartsWith(targetOrigin, StringComparison.OrdinalIgnoreCase) &&
               !LoginUrlHints.IsMatch(currentUrl);
    }

    private string GetProbeUrl()
    {
        if (!string.IsNullOrWhiteSpace(_options.ReadyUrl))
            return _options.ReadyUrl;

        return _options.Url;
    }

    private bool MatchesReadyUrl(string currentUrl)
    {
        if (currentUrl.StartsWith(_options.ReadyUrl, StringComparison.OrdinalIgnoreCase))
            return true;

        if (!Uri.TryCreate(_options.ReadyUrl, UriKind.Absolute, out var readyUri) ||
            !Uri.TryCreate(currentUrl, UriKind.Absolute, out var currentUri))
        {
            return false;
        }

        var sameOrigin = string.Equals(
            readyUri.GetLeftPart(UriPartial.Authority),
            currentUri.GetLeftPart(UriPartial.Authority),
            StringComparison.OrdinalIgnoreCase);

        var samePath = string.Equals(
            NormalizePath(readyUri.AbsolutePath),
            NormalizePath(currentUri.AbsolutePath),
            StringComparison.OrdinalIgnoreCase);

        return sameOrigin && samePath && !LoginUrlHints.IsMatch(currentUrl);
    }

    private static string NormalizePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return "/";

        var normalized = path.Trim();
        if (normalized.Length > 1)
            normalized = normalized.TrimEnd('/');

        return string.IsNullOrWhiteSpace(normalized) ? "/" : normalized;
    }

    private sealed class NavigationAttempt
    {
        public NavigationAttempt(string currentUrl, bool isAuthenticated)
        {
            CurrentUrl = currentUrl;
            IsAuthenticated = isAuthenticated;
        }

        public string CurrentUrl { get; private set; }
        public bool IsAuthenticated { get; private set; }
    }
}
'@

    [System.IO.File]::WriteAllText($projectPath, $csprojText, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($programPath, $programText, [System.Text.UTF8Encoding]::new($false))

    $dotnetArgs = @(
        'run'
        '--project', $projectPath
        '--framework', 'net461'
        '--'
        '--url', $uri.AbsoluteUri
        '--state-path', ([System.IO.Path]::GetFullPath($statePath))
        '--timeout-seconds', '600'
    )

    if ($ReadyUrl) {
        $dotnetArgs += @('--ready-url', $ReadyUrl)
    }

    if ($ReadyUrlRegex) {
        $dotnetArgs += @('--ready-url-regex', $ReadyUrlRegex)
    }

    if ($ForceLogin) {
        $dotnetArgs += '--force-login'
    }

    Write-Host ("[INFO] Site: {0}" -f $uri.AbsoluteUri)
    Write-Host ("[INFO] State path: {0}" -f ([System.IO.Path]::GetFullPath($statePath)))
    Write-Host "[INFO] Launching local .NET Playwright helper..."

    & dotnet @dotnetArgs | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw ("The .NET Playwright helper failed with exit code {0}." -f $LASTEXITCODE)
    }

    if (-not (Test-Path -LiteralPath $statePath)) {
        throw ("Playwright auth state was not created: {0}" -f $statePath)
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    if ($state.cookies) {
        foreach ($cookieState in $state.cookies) {
            Add-PlaywrightCookieToSession -Session $session -CookieState $cookieState
        }
    }

    Write-Host ("[INFO] Imported {0} cookies into a WebRequestSession." -f @($state.cookies).Count)
    return $session
}

# Example:
# . .\foo.ps1
$session = New-WebRequestSessionFromBrowserLogin `
     -Url 'https://account.microsoft.com/' `
     -SessionId 'account-test' `
     -ReadyUrl 'https://account.microsoft.com/?refd=account.microsoft.com'
$foo = Invoke-WebRequest -Uri 'https://account.microsoft.com/' -WebSession $session
$foo.RawContent

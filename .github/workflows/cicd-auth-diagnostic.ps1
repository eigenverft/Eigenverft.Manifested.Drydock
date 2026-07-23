param (
    [Parameter(Mandatory = $true)]
    [string]$NuGetGitHubPush,

    [string]$GitHubPackagesUser = 'eigenverft',
    [string]$GitHubSourceUri = 'https://nuget.pkg.github.com/eigenverft/index.json',
    [string]$ResultPath = (Join-Path $env:RUNNER_TEMP 'cicd-auth-diagnostic.json')
)

# This script intentionally mirrors only the safe startup/authentication part of cicd.ps1.
# It does not build, publish, commit, tag, push, or create a release.
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

Write-Output "PowerShell script $(Split-Path -Leaf $PSCommandPath) has started."

if ([string]::IsNullOrWhiteSpace($NuGetGitHubPush)) {
    throw 'NuGetGitHubPush is empty. The diagnostic requires github.token.'
}

Import-Module PackageManagement -Force -ErrorAction Stop
Import-Module PowerShellGet -MinimumVersion 2.2.5 -Force -ErrorAction Stop

$secureToken = ConvertTo-SecureString -String $NuGetGitHubPush -AsPlainText -Force
$credential = [System.Management.Automation.PSCredential]::new($GitHubPackagesUser, $secureToken)
$sourceName = 'github-auth-diagnostic'

function Get-SafeErrorDetails {
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    [ordered]@{
        ExceptionType       = $ErrorRecord.Exception.GetType().FullName
        Message             = $ErrorRecord.Exception.Message
        FullyQualifiedError = $ErrorRecord.FullyQualifiedErrorId
        Category            = $ErrorRecord.CategoryInfo.Category.ToString()
    }
}

function Invoke-HttpProbe {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [System.Management.Automation.PSCredential]$Credential
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $handler.UseDefaultCredentials = $false

    if ($null -ne $Credential) {
        $handler.Credentials = $Credential.GetNetworkCredential()
        $handler.PreAuthenticate = $true
    }

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)

    try {
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        try {
            $wwwAuthenticate = @($response.Headers.WwwAuthenticate | ForEach-Object { $_.ToString() }) -join ', '
            $contentType = if ($null -ne $response.Content.Headers.ContentType) {
                $response.Content.Headers.ContentType.ToString()
            }
            else {
                $null
            }

            return [ordered]@{
                Success         = $response.IsSuccessStatusCode
                StatusCode      = [int]$response.StatusCode
                ReasonPhrase    = $response.ReasonPhrase
                EffectiveUri    = $response.RequestMessage.RequestUri.AbsoluteUri
                WwwAuthenticate = $wwwAuthenticate
                ContentType     = $contentType
                Error           = $null
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch {
        return [ordered]@{
            Success         = $false
            StatusCode      = $null
            ReasonPhrase    = $null
            EffectiveUri    = $Uri
            WwwAuthenticate = $null
            ContentType     = $null
            Error           = Get-SafeErrorDetails -ErrorRecord $_
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Remove-DiagnosticSources {
    $existingRepository = Get-PSRepository -Name $sourceName -ErrorAction SilentlyContinue
    if ($null -ne $existingRepository) {
        Unregister-PSRepository -Name $sourceName -ErrorAction Stop
    }

    & dotnet nuget remove source $sourceName 2>&1 | Out-Null
    $global:LASTEXITCODE = 0
}

function Invoke-RepositoryRegistrationProbe {
    param (
        [Parameter(Mandatory = $true)]
        [bool]$UseCredential
    )

    $registration = @{
        Name                  = $sourceName
        SourceLocation        = $GitHubSourceUri
        PublishLocation       = $GitHubSourceUri
        ScriptSourceLocation  = $GitHubSourceUri
        ScriptPublishLocation = $GitHubSourceUri
        InstallationPolicy    = 'Trusted'
    }

    if ($UseCredential) {
        $registration.Credential = $credential
    }

    try {
        Register-PSRepository @registration -ErrorAction Stop
        $registered = Get-PSRepository -Name $sourceName -ErrorAction Stop

        return [ordered]@{
            Success                   = $true
            UsedExplicitCredential    = $UseCredential
            Name                      = $registered.Name
            SourceLocation            = $registered.SourceLocation
            PublishLocation           = $registered.PublishLocation
            PackageManagementProvider = $registered.PackageManagementProvider
            Error                     = $null
        }
    }
    catch {
        return [ordered]@{
            Success                   = $false
            UsedExplicitCredential    = $UseCredential
            Name                      = $sourceName
            SourceLocation            = $GitHubSourceUri
            PublishLocation           = $GitHubSourceUri
            PackageManagementProvider = $null
            Error                     = Get-SafeErrorDetails -ErrorRecord $_
        }
    }
    finally {
        $existingRepository = Get-PSRepository -Name $sourceName -ErrorAction SilentlyContinue
        if ($null -ne $existingRepository) {
            Unregister-PSRepository -Name $sourceName -ErrorAction Stop
        }
    }
}

$registerCommand = Get-Command Register-PSRepository -ErrorAction Stop
$powerShellGetModules = @(Get-Module -ListAvailable PowerShellGet | Sort-Object Version -Descending | ForEach-Object {
    [ordered]@{
        Version = $_.Version.ToString()
        Path    = $_.Path
    }
})
$packageManagementModules = @(Get-Module -ListAvailable PackageManagement | Sort-Object Version -Descending | ForEach-Object {
    [ordered]@{
        Version = $_.Version.ToString()
        Path    = $_.Path
    }
})
$nugetProviders = @(Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        Name    = $_.Name
        Version = $_.Version.ToString()
    }
})
$dotnetVersion = (& dotnet --version 2>&1 | Out-String).Trim()

$runtime = [ordered]@{
    RunnerOS                    = $env:RUNNER_OS
    RunnerArchitecture          = $env:RUNNER_ARCH
    ImageOS                     = $env:ImageOS
    ImageVersion                = $env:ImageVersion
    PowerShellVersion           = $PSVersionTable.PSVersion.ToString()
    PowerShellEdition           = $PSVersionTable.PSEdition
    DotNetVersion               = $dotnetVersion
    RegisterCommandSource       = $registerCommand.Source
    RegisterCommandVersion      = $registerCommand.Version.ToString()
    RegisterHasCredential       = $registerCommand.Parameters.ContainsKey('Credential')
    PowerShellGetModules        = $powerShellGetModules
    PackageManagementModules    = $packageManagementModules
    NuGetProviders              = $nugetProviders
}

Write-Output "Runner image: $($runtime.ImageOS) $($runtime.ImageVersion)"
Write-Output "PowerShell: $($runtime.PowerShellVersion) ($($runtime.PowerShellEdition))"
Write-Output "PowerShellGet command: $($runtime.RegisterCommandSource) $($runtime.RegisterCommandVersion)"
Write-Output "dotnet: $($runtime.DotNetVersion)"

$anonymousHttp = Invoke-HttpProbe -Uri $GitHubSourceUri
$authenticatedHttp = Invoke-HttpProbe -Uri $GitHubSourceUri -Credential $credential

Remove-DiagnosticSources
$dotnetAddOutput = & dotnet nuget add source $GitHubSourceUri --username $GitHubPackagesUser --password $NuGetGitHubPush --store-password-in-clear-text --name $sourceName 2>&1
$dotnetAddExitCode = $LASTEXITCODE
$dotnetAdd = [ordered]@{
    Success  = ($dotnetAddExitCode -eq 0)
    ExitCode = $dotnetAddExitCode
    Output   = (@($dotnetAddOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
}

$registerWithoutCredential = Invoke-RepositoryRegistrationProbe -UseCredential $false
$registerWithCredential = Invoke-RepositoryRegistrationProbe -UseCredential $true

Remove-DiagnosticSources

$anonymousRejected = ($anonymousHttp.StatusCode -in @(401, 403))
$authenticatedAccepted = ($authenticatedHttp.StatusCode -ge 200 -and $authenticatedHttp.StatusCode -lt 300)
$dotnetSourceDidNotAuthorizePowerShellGet = ($dotnetAdd.Success -and -not $registerWithoutCredential.Success)
$explicitCredentialFixedRegistration = (-not $registerWithoutCredential.Success -and $registerWithCredential.Success)
$proofConfirmed = ($anonymousRejected -and $authenticatedAccepted -and $dotnetSourceDidNotAuthorizePowerShellGet -and $explicitCredentialFixedRegistration)

$conclusion = if ($proofConfirmed) {
    'CONFIRMED: The feed rejects anonymous access, accepts the same token via explicit Basic credentials, dotnet nuget add source does not authorize Register-PSRepository, and Register-PSRepository succeeds when the same token is passed as PSCredential.'
}
elseif (-not $authenticatedAccepted) {
    'NOT CONFIRMED: The token did not produce a successful authenticated HTTP response. Token permissions or package access must be investigated first.'
}
elseif (-not $registerWithCredential.Success) {
    'PARTIAL: The token authenticates at HTTP level, but Register-PSRepository still fails with explicit PSCredential. The JSON error identifies the next compatibility layer to investigate.'
}
else {
    'INCONCLUSIVE: Observed outcomes did not match the expected A/B model. Review the JSON artifact.'
}

$result = [ordered]@{
    TimestampUtc                             = [DateTime]::UtcNow.ToString('o')
    SourceUri                                = $GitHubSourceUri
    Runtime                                  = $runtime
    AnonymousHttp                            = $anonymousHttp
    AuthenticatedHttp                        = $authenticatedHttp
    DotNetNuGetAddSource                     = $dotnetAdd
    RegisterWithoutCredential                = $registerWithoutCredential
    RegisterWithCredential                   = $registerWithCredential
    AnonymousRejected                        = $anonymousRejected
    AuthenticatedAccepted                    = $authenticatedAccepted
    DotNetSourceDidNotAuthorizePowerShellGet = $dotnetSourceDidNotAuthorizePowerShellGet
    ExplicitCredentialFixedRegistration      = $explicitCredentialFixedRegistration
    ProofConfirmed                           = $proofConfirmed
    Conclusion                               = $conclusion
}

$resultDirectory = Split-Path -Parent $ResultPath
if (-not [string]::IsNullOrWhiteSpace($resultDirectory)) {
    New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
}
$result | ConvertTo-Json -Depth 12 | Set-Content -Path $ResultPath -Encoding utf8

$summary = @"
## GitHub Packages / PowerShellGet authentication proof

| Probe | Result |
|---|---|
| Runner | `$($runtime.ImageOS)` / `$($runtime.ImageVersion)` |
| PowerShell | `$($runtime.PowerShellVersion)` |
| PowerShellGet | `$($runtime.RegisterCommandVersion)` |
| Anonymous HTTP | `$($anonymousHttp.StatusCode)` `$($anonymousHttp.ReasonPhrase)` |
| Authenticated HTTP | `$($authenticatedHttp.StatusCode)` `$($authenticatedHttp.ReasonPhrase)` |
| `dotnet nuget add source` | success: `$($dotnetAdd.Success)` |
| `Register-PSRepository` without `-Credential` | success: `$($registerWithoutCredential.Success)` |
| `Register-PSRepository` with `-Credential` | success: `$($registerWithCredential.Success)` |
| Proof confirmed | **`$proofConfirmed`** |

$conclusion

No package was built or published. No commit, tag, push, or release was created by the diagnostic script.
"@

Write-Output $summary
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if (-not $proofConfirmed) {
    throw "Authentication proof was not fully confirmed. See $ResultPath for the complete diagnostic result."
}

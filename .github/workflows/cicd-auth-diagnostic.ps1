param (
    [Parameter(Mandatory = $true)]
    [string]$NuGetGitHubPush,

    [string]$GitHubPackagesUser = 'eigenverft',
    [string]$GitHubSourceUri = 'https://nuget.pkg.github.com/eigenverft/index.json',
    [string]$ResultPath = (Join-Path $env:RUNNER_TEMP 'cicd-auth-diagnostic.json'),
    [string]$PackageManagementModulePath,
    [string]$PowerShellGetModulePath,
    [switch]$DoNotFailOnUnexpected
)

# This script intentionally mirrors only the safe startup/authentication part of cicd.ps1.
# It does not build, publish, commit, tag, push, or create a release.
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

Write-Output "PowerShell script $(Split-Path -Leaf $PSCommandPath) has started."

if ([string]::IsNullOrWhiteSpace($NuGetGitHubPush)) {
    throw 'NuGetGitHubPush is empty. The diagnostic requires github.token.'
}

if ([string]::IsNullOrWhiteSpace($PackageManagementModulePath)) {
    Import-Module PackageManagement -Force -ErrorAction Stop
}
else {
    Import-Module $PackageManagementModulePath -Force -ErrorAction Stop
}

if ([string]::IsNullOrWhiteSpace($PowerShellGetModulePath)) {
    Import-Module PowerShellGet -MinimumVersion 2.2.5 -Force -ErrorAction Stop
}
else {
    Import-Module $PowerShellGetModulePath -Force -ErrorAction Stop
}

$secureToken = ConvertTo-SecureString -String $NuGetGitHubPush -AsPlainText -Force
$credential = [System.Management.Automation.PSCredential]::new($GitHubPackagesUser, $secureToken)
$sourceName = 'github-auth-diagnostic'

function Get-SafeErrorDetails {
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    [pscustomobject][ordered]@{
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

            return [pscustomobject][ordered]@{
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
        return [pscustomobject][ordered]@{
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
        $null = Unregister-PSRepository -Name $sourceName -ErrorAction Stop
    }

    & dotnet nuget remove source $sourceName 2>&1 | Out-Null
    $null = ($global:LASTEXITCODE = 0)
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
        $null = Register-PSRepository @registration -ErrorAction Stop
        $registered = Get-PSRepository -Name $sourceName -ErrorAction Stop

        return [pscustomobject][ordered]@{
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
        return [pscustomobject][ordered]@{
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
            $null = Unregister-PSRepository -Name $sourceName -ErrorAction Stop
        }
    }
}

function Get-ModuleTreeFingerprint {
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSModuleInfo]$Module
    )

    $moduleRoot = Split-Path -Parent $Module.Path
    $fileEntries = @(Get-ChildItem -LiteralPath $moduleRoot -File -Recurse | Sort-Object FullName | ForEach-Object {
        [pscustomobject][ordered]@{
            RelativePath = [System.IO.Path]::GetRelativePath($moduleRoot, $_.FullName)
            Sha256       = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            Length       = $_.Length
        }
    })

    $fingerprintText = @($fileEntries | ForEach-Object {
        "$($_.RelativePath)|$($_.Sha256)|$($_.Length)"
    }) -join "`n"
    $fingerprintBytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprintText)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $aggregateHash = [System.Convert]::ToHexString($sha256.ComputeHash($fingerprintBytes)).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    return [pscustomobject][ordered]@{
        Name            = $Module.Name
        Version         = $Module.Version.ToString()
        Path            = $Module.Path
        Root            = $moduleRoot
        FileCount       = $fileEntries.Count
        AggregateSha256 = $aggregateHash
        Files           = $fileEntries
    }
}

function Get-SingleProbeResult {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$ProbeName
    )

    $candidates = @($InputObject | Where-Object {
        $null -ne $_ -and $null -ne $_.PSObject.Properties['Success']
    })

    if ($candidates.Count -ne 1) {
        $observedTypes = @($InputObject | ForEach-Object {
            if ($null -eq $_) { '<null>' } else { $_.GetType().FullName }
        }) -join ', '
        throw "Probe '$ProbeName' returned $($candidates.Count) result objects with a Success property. Observed pipeline types: $observedTypes"
    }

    return $candidates[0]
}

$importedPowerShellGet = Get-Module PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1
$importedPackageManagement = Get-Module PackageManagement | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $importedPowerShellGet -or $null -eq $importedPackageManagement) {
    throw 'PowerShellGet or PackageManagement was not imported.'
}
$powerShellGetFingerprint = Get-ModuleTreeFingerprint -Module $importedPowerShellGet
$packageManagementFingerprint = Get-ModuleTreeFingerprint -Module $importedPackageManagement

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
    ImportedPowerShellGet       = $powerShellGetFingerprint
    ImportedPackageManagement   = $packageManagementFingerprint
}

Write-Output "Runner image: $($runtime.ImageOS) $($runtime.ImageVersion)"
Write-Output "PowerShell: $($runtime.PowerShellVersion) ($($runtime.PowerShellEdition))"
Write-Output "PowerShellGet command: $($runtime.RegisterCommandSource) $($runtime.RegisterCommandVersion)"
Write-Output "dotnet: $($runtime.DotNetVersion)"

$anonymousHttp = Get-SingleProbeResult -ProbeName 'AnonymousHttp' -InputObject @(Invoke-HttpProbe -Uri $GitHubSourceUri)
$authenticatedHttp = Get-SingleProbeResult -ProbeName 'AuthenticatedHttp' -InputObject @(Invoke-HttpProbe -Uri $GitHubSourceUri -Credential $credential)

Remove-DiagnosticSources
$dotnetAddOutput = & dotnet nuget add source $GitHubSourceUri --username $GitHubPackagesUser --password $NuGetGitHubPush --store-password-in-clear-text --name $sourceName 2>&1
$dotnetAddExitCode = $LASTEXITCODE
$dotnetAdd = [pscustomobject][ordered]@{
    Success  = ($dotnetAddExitCode -eq 0)
    ExitCode = $dotnetAddExitCode
    Output   = (@($dotnetAddOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
}

$registerWithoutCredential = Get-SingleProbeResult -ProbeName 'RegisterWithoutCredential' -InputObject @(Invoke-RepositoryRegistrationProbe -UseCredential $false)
$registerWithCredential = Get-SingleProbeResult -ProbeName 'RegisterWithCredential' -InputObject @(Invoke-RepositoryRegistrationProbe -UseCredential $true)

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
elseif ($registerWithoutCredential.Success -and $registerWithCredential.Success) {
    'OBSERVED: Implicit registration succeeded without -Credential under this PowerShell/runtime/module combination; explicit registration also succeeded.'
}
elseif (-not $registerWithCredential.Success) {
    'PARTIAL: The token authenticates at HTTP level, but Register-PSRepository still fails with explicit PSCredential. The JSON error identifies the next compatibility layer to investigate.'
}
else {
    'INCONCLUSIVE: Observed outcomes did not match a known A/B model. Review the JSON artifact.'
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
| Runner | <code>$($runtime.ImageOS)</code> / <code>$($runtime.ImageVersion)</code> |
| PowerShell | <code>$($runtime.PowerShellVersion)</code> |
| PowerShellGet | <code>$($runtime.RegisterCommandVersion)</code> |
| Anonymous HTTP | <code>$($anonymousHttp.StatusCode)</code> <code>$($anonymousHttp.ReasonPhrase)</code> |
| Authenticated HTTP | <code>$($authenticatedHttp.StatusCode)</code> <code>$($authenticatedHttp.ReasonPhrase)</code> |
| dotnet nuget add source | success: <code>$($dotnetAdd.Success)</code> |
| Register-PSRepository without -Credential | success: <code>$($registerWithoutCredential.Success)</code> |
| Register-PSRepository with -Credential | success: <code>$($registerWithCredential.Success)</code> |
| Proof confirmed | **<code>$proofConfirmed</code>** |

$conclusion

No package was built or published. No commit, tag, push, or release was created by the diagnostic script.
"@

Write-Output $summary
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if (-not $proofConfirmed -and -not $DoNotFailOnUnexpected) {
    throw "Authentication proof was not fully confirmed. See $ResultPath for the complete diagnostic result."
}

param(
    [string]$ModuleManifestPath = 'source/Eigenverft.Manifested.Drydock/Eigenverft.Manifested.Drydock.psd1'
)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

Write-Output "PowerShell script $(Split-Path -Leaf $PSCommandPath) has started."

$resolvedManifestPath = (Resolve-Path -LiteralPath $ModuleManifestPath -ErrorAction Stop).Path
Import-Module -Name $resolvedManifestPath -Force -ErrorAction Stop

$publishCommand = Get-Command -Name 'Publish-PowerShellModuleRelease' -Module 'Eigenverft.Manifested.Drydock' -ErrorAction Stop
if ($publishCommand.Parameters['Target'].ParameterType -ne [string]) {
    throw "Publish-PowerShellModuleRelease Target must be a scalar string, not an aggregate type."
}

$temporaryRoot = Join-Path $env:RUNNER_TEMP ('publish-release-smoke-' + [Guid]::NewGuid().ToString('N'))
$testModuleName = 'Drydock.PublishRelease.Smoke'
$testModulePath = Join-Path $temporaryRoot $testModuleName
$localRepositoryPath = Join-Path $temporaryRoot 'LocalRepository'
$localRepositoryName = 'DrydockPublishReleaseSmoke'

try {
    New-Item -ItemType Directory -Path $testModulePath -Force | Out-Null
    New-Item -ItemType Directory -Path $localRepositoryPath -Force | Out-Null

    $rootModulePath = Join-Path $testModulePath ($testModuleName + '.psm1')
    $manifestPath = Join-Path $testModulePath ($testModuleName + '.psd1')

    Set-Content -LiteralPath $rootModulePath -Encoding UTF8 -Value @'
function Get-DrydockPublishReleaseSmokeValue {
    [CmdletBinding()]
    param()

    return 'ok'
}
'@

    New-ModuleManifest `
        -Path $manifestPath `
        -RootModule ($testModuleName + '.psm1') `
        -ModuleVersion '1.0.0' `
        -Guid ([Guid]::NewGuid()) `
        -Author 'Eigenverft CI' `
        -CompanyName 'Eigenverft' `
        -Copyright '(c) Eigenverft' `
        -Description 'Generated smoke module for Publish-PowerShellModuleRelease.' `
        -FunctionsToExport @('Get-DrydockPublishReleaseSmokeValue')

    $localResult = Publish-PowerShellModuleRelease `
        -Path $testModulePath `
        -Target 'Local' `
        -RepositoryName $localRepositoryName `
        -RepositoryPath $localRepositoryPath `
        -PassThru

    if (-not $localResult.Published) {
        throw 'Local publish smoke result did not report Published=True.'
    }
    if ($localResult.Target -ne 'Local') {
        throw "Unexpected local result target '$($localResult.Target)'."
    }
    if (-not $localResult.CleanupCompleted) {
        throw 'Local publish smoke result did not report successful cleanup.'
    }

    $publishedPackages = @(Get-ChildItem -LiteralPath $localRepositoryPath -Filter '*.nupkg' -File -ErrorAction Stop)
    if ($publishedPackages.Count -ne 1) {
        throw "Expected exactly one local nupkg, found $($publishedPackages.Count)."
    }

    $remainingRepository = Get-PSRepository -Name $localRepositoryName -ErrorAction SilentlyContinue
    if ($null -ne $remainingRepository) {
        throw "Temporary local repository '$localRepositoryName' was not removed."
    }

    $githubWhatIf = Publish-PowerShellModuleRelease `
        -Path $testModulePath `
        -Target 'GitHubPackages' `
        -RepositoryName 'github-smoke-whatif' `
        -GitHubOwner 'eigenverft' `
        -GitHubToken 'not-a-real-token' `
        -PassThru `
        -WhatIf

    if ($githubWhatIf.Published) {
        throw 'GitHub WhatIf smoke result unexpectedly reported Published=True.'
    }
    if ($githubWhatIf.AuthenticationMode -ne 'ExplicitCredential') {
        throw "GitHub default authentication mode was '$($githubWhatIf.AuthenticationMode)' instead of ExplicitCredential."
    }

    $legacyWhatIf = Publish-PowerShellModuleRelease `
        -Path $testModulePath `
        -Target 'GitHubPackages' `
        -RepositoryName 'github-smoke-legacy-whatif' `
        -GitHubOwner 'eigenverft' `
        -GitHubToken 'not-a-real-token' `
        -UseLegacyGitHubRegistration `
        -PassThru `
        -WhatIf

    if ($legacyWhatIf.AuthenticationMode -ne 'LegacyImplicitCredential') {
        throw "GitHub legacy authentication mode was '$($legacyWhatIf.AuthenticationMode)' instead of LegacyImplicitCredential."
    }

    $psGalleryWhatIf = Publish-PowerShellModuleRelease `
        -Path $testModulePath `
        -Target 'PSGallery' `
        -ApiKey 'not-a-real-api-key' `
        -PassThru `
        -WhatIf

    if ($psGalleryWhatIf.Published) {
        throw 'PSGallery WhatIf smoke result unexpectedly reported Published=True.'
    }

    $customRepositoryWhatIf = Publish-PowerShellModuleRelease `
        -Path $testModulePath `
        -Target 'PowerShellRepository' `
        -RepositoryName 'TestGalleryWhatIf' `
        -SourceLocation 'https://example.invalid/api/v2' `
        -PublishLocation 'https://example.invalid/api/v2/package' `
        -ApiKey 'not-a-real-api-key' `
        -PassThru `
        -WhatIf

    if ($customRepositoryWhatIf.Published) {
        throw 'Custom repository WhatIf smoke result unexpectedly reported Published=True.'
    }

    $missingGitHubTokenError = $null
    try {
        Publish-PowerShellModuleRelease `
            -Path $testModulePath `
            -Target 'GitHubPackages' `
            -GitHubOwner 'eigenverft' `
            -WhatIf
    }
    catch {
        $missingGitHubTokenError = $_
    }

    if ($null -eq $missingGitHubTokenError) {
        throw 'GitHubPackages did not reject a missing GitHubToken.'
    }

    Write-Output ("Missing-token validation rejected the call: {0}" -f $missingGitHubTokenError)

    Write-Output 'Publish-PowerShellModuleRelease smoke test completed successfully.'
}
finally {
    $remainingRepository = Get-PSRepository -Name $localRepositoryName -ErrorAction SilentlyContinue
    if ($null -ne $remainingRepository) {
        Unregister-PSRepository -Name $localRepositoryName -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

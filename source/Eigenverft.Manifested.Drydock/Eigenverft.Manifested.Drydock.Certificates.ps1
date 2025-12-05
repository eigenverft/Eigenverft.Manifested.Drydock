function New-DomainCsr {
<#
.SYNOPSIS
Generates a PKCS#10 certificate signing request (CSR) and a PFX containing the
private key (stored inside a temporary self-signed certificate).

.DESCRIPTION
Creates a new RSA key pair and builds a CSR in PEM format that you can copy/paste
into a CA or hosting control panel.

Additionally, a PFX file is always created. The PFX contains:
- a temporary self-signed certificate, and
- the corresponding private key.

This PFX is intended to be used later to combine the private key with the
provider-issued certificate and chain.

.PARAMETER CommonName
Required. The primary DNS name of the certificate (for example: eigenverft.com).

.PARAMETER DnsNames
Optional. Additional DNS names for the Subject Alternative Name (SAN) extension.
It is recommended to include the CommonName here as well.

.PARAMETER Country
Required. Two-letter country code (for example: DE). Case-insensitive; will be
normalized to upper case.

.PARAMETER State
Optional. State or province.

.PARAMETER Locality
Optional. City or locality.

.PARAMETER Organization
Optional. Legal organization name.

.PARAMETER OrganizationalUnit
Optional. Organizational unit.

.PARAMETER KeyLength
Optional. RSA key size in bits. Default is 2048.

.PARAMETER HashAlgorithm
Optional. Hash algorithm for the CSR signature. One of SHA256, SHA384, SHA512.

.PARAMETER OutputPath
Optional. File path where the CSR will be saved.

.PARAMETER PfxPath
Required. File path where the PFX (containing a temporary self-signed certificate
and the private key) will be written.

.PARAMETER PfxPassword
Required. Plain-text password to protect the PFX file. Handle this value securely
in your own code (for example, by not hard-coding it).

.PARAMETER CopyToClipboard
Optional. If specified, the resulting CSR PEM text is copied to the clipboard.

.EXAMPLE
New-DomainCsr `
    -CommonName "eigenverft.com" `
    -DnsNames "eigenverft.com","www.eigenverft.com" `
    -Country "DE" `
    -State "NRW" `
    -Locality "Düsseldorf" `
    -Organization "Eigenverft GmbH" `
    -OrganizationalUnit "IT" `
    -OutputPath ".\eigenverft.csr" `
    -PfxPath ".\eigenverft_key.pfx" `
    -PfxPassword "ChangeMe!" `
    -CopyToClipboard
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommonName,

        [string[]]$DnsNames,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z]{2}$')]
        [string]$Country,

        [string]$State,
        [string]$Locality,
        [string]$Organization,
        [string]$OrganizationalUnit,

        [ValidateRange(2048, 8192)]
        [int]$KeyLength = 2048,

        [ValidateSet("SHA256","SHA384","SHA512")]
        [string]$HashAlgorithm = "SHA256",

        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string]$PfxPath,

        [Parameter(Mandatory = $true)]
        [string]$PfxPassword,

        [switch]$CopyToClipboard
    )

    # Normalize country code to upper case.
    $Country = $Country.ToUpperInvariant()

    # Build X.500 subject distinguished name.
    $subjectParts = @()
    $subjectParts += "CN=$CommonName"
    if ($Organization)       { $subjectParts += "O=$Organization" }
    if ($OrganizationalUnit) { $subjectParts += "OU=$OrganizationalUnit" }
    if ($Locality)           { $subjectParts += "L=$Locality" }
    if ($State)              { $subjectParts += "ST=$State" }
    if ($Country)            { $subjectParts += "C=$Country" }

    $subjectString = [string]::Join(", ", $subjectParts)
    $subject       = New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName($subjectString)

    # Create an RSA key pair.
    $rsa = [System.Security.Cryptography.RSA]::Create($KeyLength)

    $hashName = [System.Security.Cryptography.HashAlgorithmName]::$HashAlgorithm
    $padding  = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1

    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $subject,
        $rsa,
        $hashName,
        $padding
    )

    # Basic constraints: end-entity, not a CA.
    $basicConstraints = [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
        $false,  # certificateAuthority
        $false,  # hasPathLengthConstraint
        0,       # pathLengthConstraint (ignored here)
        $true    # critical
    )
    $null = $request.CertificateExtensions.Add($basicConstraints)

    # Key usage extension: digital signature + key encipherment.
    $keyUsageFlags = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature `
                   -bor [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment

    $keyUsage = [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        $keyUsageFlags,
        $true   # critical
    )
    $null = $request.CertificateExtensions.Add($keyUsage)

    # Enhanced key usage: server authentication.
    $ekuOids = New-Object System.Security.Cryptography.OidCollection
    $null = $ekuOids.Add(
        [System.Security.Cryptography.Oid]::new("1.3.6.1.5.5.7.3.1", "Server Authentication")
    )
    $eku = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
        $ekuOids,
        $false  # not critical
    )
    $null = $request.CertificateExtensions.Add($eku)

    # SAN extension.
    if ($DnsNames -and $DnsNames.Count -gt 0) {
        $sanBuilder = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        foreach ($dns in $DnsNames) {
            if (-not [string]::IsNullOrWhiteSpace($dns)) {
                $sanBuilder.AddDnsName($dns.Trim())
            }
        }
        $sanExtension = $sanBuilder.Build()
        $null = $request.CertificateExtensions.Add($sanExtension)
    }

    # Create CSR (PKCS#10).
    $csrBytes  = $request.CreateSigningRequest()
    $csrBase64 = [System.Convert]::ToBase64String(
        $csrBytes,
        [System.Base64FormattingOptions]::InsertLineBreaks
    )

    $csrPem = @(
        "-----BEGIN CERTIFICATE REQUEST-----"
        $csrBase64
        "-----END CERTIFICATE REQUEST-----"
    ) -join "`r`n"

    # Save CSR to file (ASCII encoding for PEM).
    if ($OutputPath) {
        $dir = [System.IO.Path]::GetDirectoryName($OutputPath)

        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        Set-Content -Path $OutputPath -Value $csrPem -NoNewline -Encoding ascii
    }

    # Always export private key as PFX with a temporary self-signed certificate.
    $notBefore = [DateTimeOffset]::Now.AddDays(-1)
    $notAfter  = [DateTimeOffset]::Now.AddYears(1)
    $tempCert  = $request.CreateSelfSigned($notBefore, $notAfter)

    $pfxBytes = $tempCert.Export(
        [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
        $PfxPassword
    )

    $pfxDir = [System.IO.Path]::GetDirectoryName($PfxPath)
    if (-not [string]::IsNullOrWhiteSpace($pfxDir) -and -not (Test-Path -Path $pfxDir)) {
        New-Item -ItemType Directory -Path $pfxDir -Force | Out-Null
    }

    [System.IO.File]::WriteAllBytes($PfxPath, $pfxBytes)

    # Copy CSR to clipboard, if requested.
    if ($CopyToClipboard) {
        try {
            if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
                $csrPem | Set-Clipboard
            }
            else {
                Write-Warning "Set-Clipboard is not available in this session."
            }
        }
        catch {
            Write-Warning "Failed to copy CSR to clipboard. Error: $($_.Exception.Message)"
        }
    }

    # Output the CSR PEM so it can be copied from the console as well.
    $csrPem
}

function New-CertPfxFromChain {
<#
.SYNOPSIS
Creates a PFX file from a signed certificate, its chain and an existing private key.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LeafCertPath,

        [string[]]$ChainCertPaths,

        [Parameter(Mandatory = $true)]
        [string]$KeyPfxPath,

        [Parameter(Mandatory = $true)]
        [string]$KeyPfxPassword,

        [Parameter(Mandatory = $true)]
        [string]$OutputPfxPath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPfxPassword
    )

    # Helper: load a certificate from DER or PEM .crt.
    function Get-CertificateFromFile {
        param([string]$Path)

        if (-not (Test-Path -Path $Path)) {
            throw "Certificate file '$Path' not found."
        }

        $raw = [System.IO.File]::ReadAllBytes($Path)

        try {
            return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($raw)
        }
        catch {
            # Try PEM (-----BEGIN CERTIFICATE-----).
            $text = [System.IO.File]::ReadAllText($Path)
            $begin = "-----BEGIN CERTIFICATE-----"
            $end   = "-----END CERTIFICATE-----"

            $startIndex = $text.IndexOf($begin)
            if ($startIndex -lt 0) {
                throw "File '$Path' is not a valid DER or PEM certificate."
            }
            $startIndex += $begin.Length
            $endIndex = $text.IndexOf($end, $startIndex)
            if ($endIndex -lt 0) {
                throw "File '$Path' contains a BEGIN CERTIFICATE marker but no matching END."
            }

            $base64 = $text.Substring($startIndex, $endIndex - $startIndex)
            $base64 = ($base64 -replace '\s','')
            $bytes  = [System.Convert]::FromBase64String($base64)

            return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
        }
    }

    $storageFlags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable

    # 1) Load existing PFX that contains the private key from the CSR.
    $keyCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        $KeyPfxPath,
        $KeyPfxPassword,
        $storageFlags
    )

    if (-not $keyCert.HasPrivateKey) {
        throw "The PFX at '$KeyPfxPath' does not contain a private key."
    }

    # 2) Load leaf certificate from provider.
    $leafCert = Get-CertificateFromFile -Path $LeafCertPath

    # 3) Attach the private key to the leaf certificate (PS 5.1 / .NET Framework-safe).
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($keyCert)
    if (-not $rsa) {
        throw "Private key in '$KeyPfxPath' is not an RSA key (this script currently expects RSA)."
    }

    $leafWithKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$leafCert,
        [System.Security.Cryptography.RSA]$rsa
    )

    if (-not $leafWithKey) {
        throw "Failed to attach private key from '$KeyPfxPath' to leaf certificate '$LeafCertPath'."
    }

    # 4) Build collection: leaf + chain.
    $collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $null = $collection.Add($leafWithKey)

    if ($ChainCertPaths) {
        foreach ($chainPath in $ChainCertPaths) {
            if (-not [string]::IsNullOrWhiteSpace($chainPath)) {
                $chainCert = Get-CertificateFromFile -Path $chainPath
                $null = $collection.Add($chainCert)
            }
        }
    }

    # 5) Export new PFX.
    $pfxBytes = $collection.Export(
        [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
        $OutputPfxPassword
    )

    $outDir = [System.IO.Path]::GetDirectoryName($OutputPfxPath)
    if ($outDir -and -not (Test-Path -Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    [System.IO.File]::WriteAllBytes($OutputPfxPath, $pfxBytes)

    Write-Host "Created PFX: $OutputPfxPath"
}

function Test-CertPfx {
<#
.SYNOPSIS
Inspects a PFX file and writes basic certificate and chain information to the console.

.DESCRIPTION
Loads a PFX file, lists all contained certificates, identifies the certificate
that has a private key (the leaf for typical TLS usage) and attempts to build a
chain from leaf to root using the other certificates in the PFX as additional
chain elements.

This is intended as a diagnostic helper to verify that a PFX produced by
New-CertPfxFromChain contains:
- exactly one leaf certificate with a private key, and
- the expected intermediate / root certificates.

.PARAMETER PfxPath
Path to the PFX file that should be inspected.

.PARAMETER PfxPassword
Plain-text password that protects the PFX file.

.EXAMPLE
Test-CertPfx -PfxPath ".\eigenverft_final.pfx" -PfxPassword "FinalPfxPassword123!"

Loads eigenverft_final.pfx, dumps the certificates inside, and shows the
constructed chain from leaf to root including chain build status.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PfxPath,

        [Parameter(Mandatory = $true)]
        [string]$PfxPassword
    )

    if (-not (Test-Path -Path $PfxPath)) {
        throw "PFX file '$PfxPath' not found."
    }

    # Load all certificates from the PFX into a collection.
    $certs = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $certs.Import(
        $PfxPath,
        $PfxPassword,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    )

    Write-Host "PFX file : $PfxPath"
    Write-Host "Password : (provided)"
    Write-Host "Certs in PFX: $($certs.Count)"
    Write-Host ""

    # Dump basic info for each certificate in the PFX.
    $index = 0
    foreach ($c in $certs) {
        $index++
        Write-Host "[$index] ----------------------------------------"
        Write-Host (" Subject     : {0}" -f $c.Subject)
        Write-Host (" Issuer      : {0}" -f $c.Issuer)
        Write-Host (" NotBefore   : {0}" -f $c.NotBefore)
        Write-Host (" NotAfter    : {0}" -f $c.NotAfter)
        Write-Host (" Thumbprint  : {0}" -f $c.Thumbprint)
        Write-Host (" HasPrivateKey: {0}" -f $c.HasPrivateKey)
        Write-Host ""
    }

    # Identify the leaf certificate (the one with the private key).
    $leafWithKey = $certs | Where-Object { $_.HasPrivateKey } 

    if (-not $leafWithKey -or $leafWithKey.Count -eq 0) {
        Write-Warning "No certificate with a private key found in the PFX. Expected one leaf certificate with a private key."
        return
    }

    if ($leafWithKey.Count -gt 1) {
        Write-Warning "More than one certificate with a private key found in the PFX. Using the first one for chain analysis."
        $leaf = $leafWithKey | Select-Object -First 1
    }
    else {
        $leaf = $leafWithKey
    }

    Write-Host "Leaf certificate (with private key) selected for chain build:"
    Write-Host (" Subject : {0}" -f $leaf.Subject)
    Write-Host (" Issuer  : {0}" -f $leaf.Issuer)
    Write-Host (" Thumbprint: {0}" -f $leaf.Thumbprint)
    Write-Host ""

    # Build a chain from the leaf certificate.
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain

    # Do not perform revocation checks here; this is a structural test only.
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $chain.ChainPolicy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::EndCertificateOnly
    $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreWrongUsage

    # Add all non-leaf certificates from the PFX to the ExtraStore so the chain
    # builder can use them, even if they are not in the OS stores.
    foreach ($c in $certs) {
        if ($c.Thumbprint -ne $leaf.Thumbprint) {
            [void]$chain.ChainPolicy.ExtraStore.Add($c)
        }
    }

    $chainBuilt = $chain.Build($leaf)

    Write-Host "Chain build result: $chainBuilt"
    if (-not $chainBuilt -and $chain.ChainStatus.Count -gt 0) {
        Write-Host "Chain status:"
        foreach ($status in $chain.ChainStatus) {
            if ($status.Status -ne [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::NoError) {
                Write-Host (" - {0}: {1}" -f $status.Status, $status.StatusInformation.Trim())
            }
        }
        Write-Host ""
    }

    Write-Host "Chain elements (leaf -> root) according to X509Chain:"
    $i = 0
    foreach ($elem in $chain.ChainElements) {
        $i++
        $c = $elem.Certificate
        Write-Host (" ({0}) Subject : {1}" -f $i, $c.Subject)
        Write-Host ("     Issuer  : {0}" -f $c.Issuer)
        Write-Host ("     Thumbprint: {0}" -f $c.Thumbprint)
        Write-Host ""
    }
}

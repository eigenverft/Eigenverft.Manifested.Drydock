function Test-PSGalleryConnectivity {
<#
.SYNOPSIS
Fast connectivity test to PowerShell Gallery with HEAD→GET fallback.
.DESCRIPTION
Attempts a HEAD request to https://www.powershellgallery.com/api/v2/.
If the server returns 405 (Method Not Allowed), retries with GET.
Considers HTTP 200–399 as reachable. Writes status and returns $true/$false.
.EXAMPLE
Test-PSGalleryConnectivity
.OUTPUTS
System.Boolean
#>
    [CmdletBinding()]
    param()

    $url = 'https://www.powershellgallery.com/api/v2/'
    $timeoutMs = 5000

    function Invoke-WebCheck {
        param([string]$Method)

        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Method            = $Method
            $req.Timeout           = $timeoutMs
            $req.ReadWriteTimeout  = $timeoutMs
            $req.AllowAutoRedirect = $true
            $req.UserAgent         = 'WindowsPowerShell/5.1 PSGalleryConnectivityCheck'

            # NOTE: No proxy credential munging here—use system defaults.
            $res = $req.GetResponse()
            $status = [int]$res.StatusCode
            $res.Close()

            if ($status -ge 200 -and $status -lt 400) {
                Write-Host "[OK] PSGallery reachable via $Method (HTTP $status)."
                return $true
            } else {
                Write-Host "Error: PSGallery returned HTTP $status on $Method." -ForegroundColor Red
                return $false
            }
        } catch [System.Net.WebException] {
            $wex = $_.Exception
            $resp = $wex.Response
            if ($resp -and $resp -is [System.Net.HttpWebResponse]) {
                $status = [int]$resp.StatusCode
                $resp.Close()
                if ($status -eq 405 -and $Method -eq 'HEAD') {
                    # Fallback handled by caller
                    return $null
                }
                Write-Host "Error: PSGallery $Method failed (HTTP $status): $($wex.Message)" -ForegroundColor Red
                return $false
            } else {
                Write-Host "Error: PSGallery $Method failed: $($wex.Message)" -ForegroundColor Red
                return $false
            }
        } catch {
            Write-Host "Error: PSGallery $Method failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }

    # Try HEAD first for speed; if 405, fall back to GET.
    $headResult = Invoke-WebCheck -Method 'HEAD'
    if ($headResult -eq $true) { return $true }
    if ($null -eq $headResult) {
        # 405 from HEAD → retry with GET
        $getResult = Invoke-WebCheck -Method 'GET'
        return [bool]$getResult
    }

    return $false
}

function Test-GitHubConnectivity {
<#
.SYNOPSIS
    Fast connectivity test to GitHub API with HEAD→GET fallback.

.DESCRIPTION
    Attempts a HEAD request to https://api.github.com/rate_limit.
    If the server returns 405 (Method Not Allowed), retries with GET.
    Considers HTTP 200–399 as reachable. Writes status and returns $true/$false.
    Enforces TLS 1.2 on Windows PowerShell 5.1. Sets required User-Agent and Accept headers.

.EXAMPLE
    Test-GitHubConnectivity

.OUTPUTS
    System.Boolean
#>
    [CmdletBinding()]
    param()

    $url = 'https://api.github.com/rate_limit'
    $timeoutMs = 5000

    # Ensure TLS 1.2 on PS5.1 without permanently altering session settings.
    $origTls = [System.Net.ServicePointManager]::SecurityProtocol
    try {
        # Add Tls12 flag if missing (bitwise OR avoids clobbering existing flags).
        [System.Net.ServicePointManager]::SecurityProtocol = $origTls -bor [System.Net.SecurityProtocolType]::Tls12

        function Invoke-WebCheck {
            param([string]$Method)

            try {
                $req = [System.Net.HttpWebRequest]::Create($url)
                $req.Method            = $Method
                $req.Timeout           = $timeoutMs
                $req.ReadWriteTimeout  = $timeoutMs
                $req.AllowAutoRedirect = $true
                $req.UserAgent         = 'WindowsPowerShell/5.1 GitHubConnectivityCheck'
                $req.Accept            = 'application/vnd.github+json'

                # NOTE: Use system proxy defaults; no credential munging here.
                $res = $req.GetResponse()
                $status = [int]$res.StatusCode
                $res.Close()

                if ($status -ge 200 -and $status -lt 400) {
                    Write-Host "[OK] GitHub reachable via $Method (HTTP $status)."
                    return $true
                } else {
                    Write-Host "Error: GitHub returned HTTP $status on $Method." -ForegroundColor Red
                    return $false
                }
            } catch [System.Net.WebException] {
                $wex = $_.Exception
                $resp = $wex.Response
                if ($resp -and $resp -is [System.Net.HttpWebResponse]) {
                    $status = [int]$resp.StatusCode
                    $resp.Close()
                    if ($status -eq 405 -and $Method -eq 'HEAD') {
                        # Signal fallback to GET
                        return $null
                    }
                    Write-Host "Error: GitHub $Method failed (HTTP $status): $($wex.Message)" -ForegroundColor Red
                    return $false
                } else {
                    Write-Host "Error: GitHub $Method failed: $($wex.Message)" -ForegroundColor Red
                    return $false
                }
            } catch {
                Write-Host "Error: GitHub $Method failed: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
        }

        # Try HEAD first; if 405, fall back to GET.
        $headResult = Invoke-WebCheck -Method 'HEAD'
        if ($headResult -eq $true) { return $true }
        if ($null -eq $headResult) {
            $getResult = Invoke-WebCheck -Method 'GET'
            return [bool]$getResult
        }
        return $false
    }
    finally {
        # Restore original TLS settings.
        [System.Net.ServicePointManager]::SecurityProtocol = $origTls
    }
}

function Test-RemoteResourcesAvailable {
<#
.SYNOPSIS
    Runs the existing PSGallery and GitHub connectivity checks and aggregates the result.

.DESCRIPTION
    Delegates to:
      - Test-PSGalleryConnectivity
      - Test-GitHubConnectivity
    Each dependency prints its own status. This wrapper returns a summary object or, with -Quiet, a single boolean.

.PARAMETER Quiet
    Return only a boolean (True iff both checks succeed).

.EXAMPLE
    Test-RemoteResourcesAvailable

.EXAMPLE
    Test-RemoteResourcesAvailable -Quiet

.OUTPUTS
    PSCustomObject (default) or System.Boolean (with -Quiet)
#>
    [CmdletBinding()]
    param(
        [switch]$Quiet
    )

    # Ensure the two dependency functions exist; if not, mark as failed and note it.
    $hasPSG = [bool](Get-Command -Name Test-PSGalleryConnectivity -CommandType Function -ErrorAction SilentlyContinue)
    $hasGH  = [bool](Get-Command -Name Test-GitHubConnectivity   -CommandType Function -ErrorAction SilentlyContinue)

    if (-not $hasPSG) { Write-Verbose "Dependency 'Test-PSGalleryConnectivity' not found in session." }
    if (-not $hasGH)  { Write-Verbose "Dependency 'Test-GitHubConnectivity' not found in session." }

    $psgOk = $false
    $ghOk  = $false

    if ($hasPSG) { $psgOk = [bool](Test-PSGalleryConnectivity) }
    if ($hasGH)  { $ghOk  = [bool](Test-GitHubConnectivity)   }

    $overall = $psgOk -and $ghOk

    if ($Quiet) {
        return $overall
    }

    [pscustomobject]@{
        PSGallery = $psgOk
        GitHub    = $ghOk
        Overall   = $overall
        Notes     = @(
            if (-not $hasPSG) { "Missing: Test-PSGalleryConnectivity" }
            if (-not $hasGH)  { "Missing: Test-GitHubConnectivity"   }
        ) -join '; '
    }
}


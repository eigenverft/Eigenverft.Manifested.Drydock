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
                Write-ConsoleLog -Level INF -Message "PSGallery reachable via $Method (HTTP $status)."
                return $true
            } else {
                Write-ConsoleLog -Level WRN -Message "Error: PSGallery returned HTTP $status on $Method."
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
                Write-ConsoleLog -Level WRN -Message "Error: PSGallery $Method failed (HTTP $status): $($wex.Message)"
                return $false
            } else {
                Write-ConsoleLog -Level WRN -Message "Error: PSGallery $Method failed: $($wex.Message)"
                return $false
            }
        } catch {
            Write-ConsoleLog -Level WRN -Message "Error: PSGallery $Method failed: $($_.Exception.Message)"
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
                    Write-ConsoleLog -Level INF -Message "GitHub reachable via $Method (HTTP $status)."
                    return $true
                } else {
                    Write-ConsoleLog -Level WRN -Message "Error: GitHub returned HTTP $status on $Method."
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
                    Write-ConsoleLog -Level WRN -Message "Error: GitHub $Method failed (HTTP $status): $($wex.Message)"
                    return $false
                } else {
                    Write-ConsoleLog -Level WRN -Message "Error: GitHub $Method failed: $($wex.Message)"
                    return $false
                }
            } catch {
                Write-ConsoleLog -Level WRN -Message "Error: GitHub $Method failed: $($_.Exception.Message)"
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

function Write-ConsoleLog {
<#
.SYNOPSIS
Deterministic logger gated ONLY by MinLevel; non-errors use Output, errors use Error.

.DESCRIPTION
Formats: "[yyyy-MM-dd HH:mm:ss:fff LEVEL] [file.ps1] [function] message"
Visibility is controlled solely by MinLevel (TRC..FTL). Preferences like Verbose/Debug/Warning do not affect output.
Streams:
  - TRC/DBG/INF/WRN -> Write-Output
  - ERR/FTL         -> Write-Error (terminates when $ErrorActionPreference = 'Stop')
If an error is requested (ERR/FTL) but MinLevel is stricter (e.g., FTL), the function auto-escalates to match MinLevel
so it isn’t filtered out (useful in catch).

.PARAMETER Message
Text to log.

.PARAMETER Level
TRC | DBG | INF | WRN | ERR | FTL. Default: INF.

.PARAMETER MinLevel
TRC | DBG | INF | WRN | ERR | FTL. Defaults to $Global:ConsoleLogMinLevel or 'INF'.

.PARAMETER LocalTime
Use local time (UTC is default).

.EXAMPLE
# Global config (only these matter)
$ErrorActionPreference     = 'Stop'   # errors become terminating
$Global:ConsoleLogMinLevel = 'INF'    # gate: TRC/DBG/INF/WRN/ERR/FTL

.EXAMPLE
# 1) Normal flow
Write-ConsoleLog -Level INF -Message 'started'     # goes to Output

.EXAMPLE
# 2) Try/Catch – you just say ERR in catch
try {
    Write-ConsoleLog -Level INF -Message 'work ok'
}
catch {
    Write-ConsoleLog -Level ERR -Message 'not ok'   # goes to Error; terminates because EAPref=Stop
}

.EXAMPLE
# 3) Gate to warnings and above (no preferences involved)
$Global:ConsoleLogMinLevel = 'WRN'
Write-ConsoleLog -Level INF -Message 'hidden'
Write-ConsoleLog -Level WRN -Message 'shown (Output)'

.EXAMPLE
# 4) Gate to fatal only; catch auto-escalates
$Global:ConsoleLogMinLevel = 'FTL'
try { throw 'boom' } catch { Write-ConsoleLog -Level ERR -Message 'fatal path' }  # escalates to FTL → Error → Stop
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')]
        [string]$Level = 'INF',

        [Parameter()]
        [ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')]
        [string]$MinLevel,

        [Parameter()]
        [switch]$LocalTime
    )

    # Resolve MinLevel: explicit > global > default
    if (-not $PSBoundParameters.ContainsKey('MinLevel')) {
        $MinLevel = if ($Global:ConsoleLogMinLevel) { $Global:ConsoleLogMinLevel } else { 'INF' }
    }

    $sevMap = @{ TRC=0; DBG=1; INF=2; WRN=3; ERR=4; FTL=5 }
    $lvl = $Level.ToUpperInvariant()
    $min = $MinLevel.ToUpperInvariant()
    $sev = $sevMap[$lvl]
    $gate= $sevMap[$min]

    # Auto-escalate requested errors to meet strict MinLevel (e.g., MinLevel=FTL)
    if ($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4) {
        $lvl = $min
        $sev = $gate
    }

    # Drop below gate
    if ($sev -lt $gate) { return }

    # Format line
    $now = if ($LocalTime) { Get-Date } else { [DateTime]::UtcNow }
    $ts  = $now.ToString('yyyy-MM-dd HH:mm:ss:fff')

    # Resolve caller (external reviewer perspective)
    $self   = $MyInvocation.MyCommand.Name
    $caller = Get-PSCallStack | Where-Object { $_.FunctionName -ne $self } | Select-Object -First 1
    if (-not $caller) { $caller = [pscustomobject]@{ ScriptName=$PSCommandPath; FunctionName='<scriptblock>' } }

    $file = if ($caller.ScriptName) { Split-Path -Leaf $caller.ScriptName } else { 'console' }
    $func = if ($caller.FunctionName) { $caller.FunctionName } else { '<scriptblock>' }
    $line = "[{0} {1}] [{2}] [{3}] {4}" -f $ts, $lvl, $file, $func.ToLower(), $Message

    # Emit: Output for non-errors; Error for ERR/FTL. Termination via $ErrorActionPreference.
    if ($sev -ge 4) {
        if ($ErrorActionPreference -eq 'Stop') {
            Write-Error -Message $line -ErrorId ("ConsoleLog.{0}" -f $lvl) -Category NotSpecified -ErrorAction Stop
        } else {
            Write-Error -Message $line -ErrorId ("ConsoleLog.{0}" -f $lvl) -Category NotSpecified
        }
    } else {
        Write-Information -MessageData $line -InformationAction Continue
    }
}



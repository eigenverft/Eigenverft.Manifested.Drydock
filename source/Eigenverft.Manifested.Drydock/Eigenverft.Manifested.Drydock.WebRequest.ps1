function Write-StandardMessage {
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
        [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$Level='INF',
        [Parameter()][ValidateSet('TRC','DBG','INF','WRN','ERR','FTL')][string]$MinLevel
    )
    if ($null -eq $Message) { $Message = [string]::Empty }
    $sevMap=@{TRC=0;DBG=1;INF=2;WRN=3;ERR=4;FTL=5}
    if(-not $PSBoundParameters.ContainsKey('MinLevel')){
        $gv=Get-Variable ConsoleLogMinLevel -Scope Global -ErrorAction SilentlyContinue
        $MinLevel=if($gv -and $gv.Value -and -not [string]::IsNullOrEmpty([string]$gv.Value)){[string]$gv.Value}else{'INF'}
    }
    $lvl=$Level.ToUpperInvariant()
    $min=$MinLevel.ToUpperInvariant()
    $sev=$sevMap[$lvl];if($null -eq $sev){$lvl='INF';$sev=$sevMap['INF']}
    $gate=$sevMap[$min];if($null -eq $gate){$min='INF';$gate=$sevMap['INF']}
    if($sev -ge 4 -and $sev -lt $gate -and $gate -ge 4){$lvl=$min;$sev=$gate}
    if($sev -lt $gate){return}
    $ts=[DateTime]::UtcNow.ToString('yy-MM-dd HH:mm:ss')
    $stack=Get-PSCallStack ; $helperName=$MyInvocation.MyCommand.Name ; $helperScript=$MyInvocation.MyCommand.ScriptBlock.File ; $caller=$null
    if($stack){
        # 1: prefer first non-underscore function not defined in the helper's own file
        for($i=0;$i -lt $stack.Count;$i++){
            $f=$stack[$i];$fn=$f.FunctionName;$sn=$f.ScriptName
            if($fn -and $fn -ne $helperName -and -not $fn.StartsWith('_') -and (-not $helperScript -or -not $sn -or $sn -ne $helperScript)){$caller=$f;break}
        }
        # 2: fallback to first non-underscore function (any file)
        if(-not $caller){
            for($i=0;$i -lt $stack.Count;$i++){
                $f=$stack[$i];$fn=$f.FunctionName
                if($fn -and $fn -ne $helperName -and -not $fn.StartsWith('_')){$caller=$f;break}
            }
        }
        # 3: fallback to first non-helper frame not from helper's own file
        if(-not $caller){
            for($i=0;$i -lt $stack.Count;$i++){
                $f=$stack[$i];$fn=$f.FunctionName;$sn=$f.ScriptName
                if($fn -and $fn -ne $helperName -and (-not $helperScript -or -not $sn -or $sn -ne $helperScript)){$caller=$f;break}
            }
        }
        # 4: final fallback to first non-helper frame
        if(-not $caller){
            for($i=0;$i -lt $stack.Count;$i++){
                $f=$stack[$i];$fn=$f.FunctionName
                if($fn -and $fn -ne $helperName){$caller=$f;break}
            }
        }
    }
    if(-not $caller){$caller=[pscustomobject]@{ScriptName=$PSCommandPath;FunctionName=$null}}
    $lineNumber=$null ; 
    $p=$caller.PSObject.Properties['ScriptLineNumber'];if($p -and $p.Value){$lineNumber=[string]$p.Value}
    if(-not $lineNumber){
        $p=$caller.PSObject.Properties['Position']
        if($p -and $p.Value){
            $sp=$p.Value.PSObject.Properties['StartLineNumber'];if($sp -and $sp.Value){$lineNumber=[string]$sp.Value}
        }
    }
    if(-not $lineNumber){
        $p=$caller.PSObject.Properties['Location']
        if($p -and $p.Value){
            $m=[regex]::Match([string]$p.Value,':(\d+)\s+char:','IgnoreCase');if($m.Success -and $m.Groups.Count -gt 1){$lineNumber=$m.Groups[1].Value}
        }
    }
    $file=if($caller.ScriptName){Split-Path -Leaf $caller.ScriptName}else{'cmd'}
    if($file -ne 'console' -and $lineNumber){$file="{0}:{1}" -f $file,$lineNumber}
    $prefix="[$ts "
    #$suffix="] [$file] $Message"
    $suffix="] $Message"
    $cfg=@{TRC=@{Fore='DarkGray';Back=$null};DBG=@{Fore='Cyan';Back=$null};INF=@{Fore='Green';Back=$null};WRN=@{Fore='Yellow';Back=$null};ERR=@{Fore='Red';Back=$null};FTL=@{Fore='Red';Back='DarkRed'}}[$lvl]
    $fore=$cfg.Fore
    $back=$cfg.Back
    $isInteractive = [System.Environment]::UserInteractive
    if($isInteractive -and ($fore -or $back)){
        Write-Host -NoNewline $prefix
        if($fore -and $back){Write-Host -NoNewline $lvl -ForegroundColor $fore -BackgroundColor $back}
        elseif($fore){Write-Host -NoNewline $lvl -ForegroundColor $fore}
        elseif($back){Write-Host -NoNewline $lvl -BackgroundColor $back}
        Write-Host $suffix
    } else {
        Write-Host "$prefix$lvl$suffix"
    }

    if($sev -ge 4 -and $ErrorActionPreference -eq 'Stop'){throw ("ConsoleLog.{0}: {1}" -f $lvl,$Message)}
}
function Invoke-WebRequestEx {
<#
.SYNOPSIS
    Invokes a web request with Windows PowerShell 5.1 compatibility improvements, retry logic, proxy/TLS handling, resilient streaming downloads, resume support, and optional final hash verification.

.DESCRIPTION
    Invoke-WebRequestEx is a compatibility-first wrapper around Invoke-WebRequest,
    primarily intended for Windows PowerShell 5.1 environments where large or
    long-running downloads can be unreliable or operationally awkward.

    The function preserves native Invoke-WebRequest behavior for general web
    requests whenever possible, but extends it with additional behavior that is
    useful for automation, infrastructure scripts, artifact downloads, and
    resumable file transfer scenarios.

    Added behavior includes:
    - TLS 1.2 enablement when not already active
    - OutFile parent directory creation
    - Proxy auto-discovery when the caller did not explicitly provide proxy settings
    - Retry handling for all HTTP methods
    - Optional total retry budget across attempts
    - Optional streaming download engine for compatible GET + OutFile requests
    - Automatic resume for compatible streaming downloads unless disabled
    - Resume metadata validation using persisted ETag / Last-Modified sidecar state
    - Cooperative lock file handling to reduce concurrent download collisions for the same target
    - Optional final required hash verification for streaming downloads
    - Optional certificate validation bypass for development or lab scenarios
    - Optional automatic retry with UseDefaultCredentials after an initial 401 challenge
      when the target appears intranet-like and the caller did not explicitly provide credentials

    Compatibility is prioritized:
    - Native Invoke-WebRequest remains the default engine for general requests
    - The streaming engine is only used for compatible download-shaped requests
    - Wrapper-only features are mainly applied to the streaming download path

    Streaming download mode is generally selected only when:
    - Method is GET
    - OutFile is specified
    - No incompatible compatibility-sensitive parameters are present

    Resume behavior:
    - Resume is enabled by default for compatible streaming downloads
    - Resume can be disabled with -DisableResumeStreamingDownload
    - Resume only appends when remote validator checks still match
    - If resume is unsafe or unsupported, the transfer restarts from byte 0

    Required final hash behavior:
    - If -RequiredStreamingHashType and -RequiredStreamingHash are supplied,
      the completed streaming download is verified before success is reported
    - A hash mismatch invalidates the downloaded file
    - Hash verification is intended for the streaming download path only

.PARAMETER Uri
    The request URI.

.PARAMETER RetryCount
    Maximum number of request attempts. Applies to both native and streaming paths.

.PARAMETER RetryDelayMilliseconds
    Delay between retry attempts in milliseconds.

.PARAMETER TotalTimeoutSec
    Optional total retry budget in seconds across all attempts.
    A value of 0 disables total-budget enforcement.

.PARAMETER BufferSizeBytes
    Buffer size used by the streaming download engine.

.PARAMETER ProgressIntervalPercent
    Progress reporting interval, in percent, when the total content length is known.

.PARAMETER ProgressIntervalBytes
    Progress reporting interval, in bytes, when the total content length is unknown.

.PARAMETER UseStreamingDownload
    Prefer the streaming download engine when the request is safely compatible with it.

.PARAMETER DisableResumeStreamingDownload
    Disables automatic resume behavior for the streaming download path.
    When set, streaming retries restart from scratch instead of resuming.

.PARAMETER DeletePartialStreamingDownloadOnFailure
    Deletes the target file on terminal streaming failure when the file was created
    by the current invocation and the operation does not complete successfully.

.PARAMETER RequiredStreamingHashType
    Required final hash algorithm for streaming download verification.
    Currently intended for wrapper-managed final file validation.

.PARAMETER RequiredStreamingHash
    Required final hash value for streaming download verification.
    Must be supplied together with -RequiredStreamingHashType.

.PARAMETER SkipCertificateCheck
    Skips TLS certificate validation for this request.
    Intended for development, isolated lab, or other non-production scenarios.

.PARAMETER DisableAutoUseDefaultCredentials
    Disables the automatic retry with UseDefaultCredentials after an initial 401
    challenge when the target appears intranet-like.

.PARAMETER AllowSelfSigned
    Legacy alias for SkipCertificateCheck.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://example.org'

    Performs a general web request using native Invoke-WebRequest behavior when
    no wrapper-specific download path is needed.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://example.org/file.zip' -OutFile 'C:\Temp\file.zip'

    Downloads a file. For compatible GET + OutFile requests, the wrapper may use
    the streaming download engine automatically.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://example.org/api' -Method Post -Body '{ "a": 1 }' -RetryCount 3

    Sends a POST request with retry support while remaining on the native path.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://example.org/file.iso' -OutFile 'C:\Temp\file.iso' -UseStreamingDownload

    Explicitly prefers the streaming download engine when the request is compatible.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://example.org/file.iso' -OutFile 'C:\Temp\file.iso' -RetryCount 10 -RetryDelayMilliseconds 5000

    Retries a download up to 10 times with a 5 second delay between attempts.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://example.org/file.iso' -OutFile 'C:\Temp\file.iso' -TotalTimeoutSec 1800

    Limits the total retry budget for the operation to 30 minutes.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://example.org/file.iso' -OutFile 'C:\Temp\file.iso' -DisableResumeStreamingDownload

    Disables resume behavior for a compatible streaming download so retries restart
    from scratch.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://example.org/file.iso' -OutFile 'C:\Temp\file.iso' -DeletePartialStreamingDownloadOnFailure

    Deletes the partial file on terminal failure when appropriate for the current invocation.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://devbox.local/file.zip' -OutFile 'C:\Temp\file.zip' -SkipCertificateCheck

    Allows download from a development or lab endpoint with certificate validation bypass.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://intranet-app/api/status'

    If the server responds with 401 and the target is detected as intranet-like,
    the wrapper may retry automatically with default credentials unless disabled.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://intranet-app/api/status' -DisableAutoUseDefaultCredentials

    Prevents the wrapper from automatically retrying with default credentials.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-UD-IQ2_XXS.gguf' -OutFile 'C:\Temp\Qwen3.5-9B-UD-IQ2_XXS.gguf'

    Downloads a large model artifact using the resilient streaming path when compatible.
    Resume support is enabled by default for compatible streaming downloads.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-UD-IQ2_XXS.gguf' -OutFile 'C:\Temp\Qwen3.5-9B-UD-IQ2_XXS.gguf' -RequiredStreamingHashType SHA256 -RequiredStreamingHash '570CE2BBC92545CFFBCB01DF43CBA59D86093DADC34C25DA9F554D256BC70B91'

    Downloads a large artifact and verifies the final file against the required SHA256
    before success is reported.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-UD-IQ2_XXS.gguf' -OutFile '.\Qwen3.5-9B-UD-IQ2_XXS.gguf' -RequiredStreamingHashType SHA256 -RequiredStreamingHash '570CE2BBC92545CFFBCB01DF43CBA59D86093DADC34C25DA9F554D256BC70B91' -UseBasicParsing

    UseBasicParsing is accepted for compatibility with native Invoke-WebRequest,
    but has no practical effect when the wrapper selects the streaming download path.

.EXAMPLE
    $ErrorActionPreference = 'Stop'
    Invoke-WebRequestEx -Uri 'https://example.org/file.iso' -OutFile 'C:\Temp\file.iso'

    Uses caller-controlled error preference behavior through Write-StandardMessage.
    In Stop mode, error-level log events can terminate the call.

.NOTES
    Wrapper-specific features such as streaming download, resume, lock handling,
    and required final hash verification are not a full reimplementation of every
    native Invoke-WebRequest feature. They are intentionally focused on compatible
    resilient download scenarios.

    Parameters such as UseBasicParsing are mainly relevant when the request remains
    on the native Invoke-WebRequest path.

    For large artifact downloads in Windows PowerShell 5.1, this wrapper is intended
    to improve operational reliability while preserving native behavior where practical.
#>
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Url')]
        [uri]$Uri,

        [Parameter()]
        [switch]$UseBasicParsing,

        [Parameter()]
        [object]$WebSession,

        [Parameter()]
        [string]$SessionVariable,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [switch]$UseDefaultCredentials,

        [Parameter()]
        [string]$CertificateThumbprint,

        [Parameter()]
        [System.Security.Cryptography.X509Certificates.X509Certificate]$Certificate,

        [Parameter()]
        [string]$UserAgent,

        [Parameter()]
        [switch]$DisableKeepAlive,

        [Parameter()]
        [int]$TimeoutSec,

        [Parameter()]
        [System.Collections.IDictionary]$Headers,

        [Parameter()]
        [int]$MaximumRedirection,

        [Parameter()]
        [ValidateSet('Default','Get','Head','Post','Put','Delete','Trace','Options','Merge','Patch')]
        [string]$Method,

        [Parameter()]
        [uri]$Proxy,

        [Parameter()]
        [System.Management.Automation.PSCredential]$ProxyCredential,

        [Parameter()]
        [switch]$ProxyUseDefaultCredentials,

        [Parameter()]
        [object]$Body,

        [Parameter()]
        [string]$ContentType,

        [Parameter()]
        [string]$TransferEncoding,

        [Parameter()]
        [string]$InFile,

        [Parameter()]
        [string]$OutFile,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [Alias('AllowSelfSigned')]
        [switch]$SkipCertificateCheck,

        [Parameter()]
        [switch]$DisableAutoUseDefaultCredentials,

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$RetryCount = 3,

        [Parameter()]
        [ValidateRange(0, 86400000)]
        [int]$RetryDelayMilliseconds = 1000,

        [Parameter()]
        [ValidateRange(0, 2147483647)]
        [int]$TotalTimeoutSec = 0,

        [Parameter()]
        [ValidateRange(1024, 268435456)]
        [Alias('BufferSize')]
        [int]$BufferSizeBytes = 4194304,

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$ProgressIntervalPercent = 10,

        [Parameter()]
        [ValidateRange(1048576, 9223372036854775807)]
        [long]$ProgressIntervalBytes = 52428800,

        [Parameter()]
        [Alias('DeleteStreamingFragmentsOnFailure')]
        [switch]$DeletePartialStreamingDownloadOnFailure,

        [Parameter()]
        [switch]$UseStreamingDownload,

        [Parameter()]
        [switch]$DisableResumeStreamingDownload,

        [Parameter()]
        [ValidateSet('SHA256')]
        [string]$RequiredStreamingHashType,

        [Parameter()]
        [string]$RequiredStreamingHash
    )

    function local:_UriDisplayShortener {
        param([Parameter(Mandatory = $true)][uri]$TargetUri)

        $originalText = [string]$TargetUri
        if ([string]::IsNullOrWhiteSpace($originalText)) { return $originalText }

        try {
            $hostDisplay = $TargetUri.Host
            $absolutePath = $TargetUri.AbsolutePath
            $querySuffix = if (-not [string]::IsNullOrEmpty($TargetUri.Query)) { '?...' } else { '' }
            $fragmentSuffix = if (-not [string]::IsNullOrEmpty($TargetUri.Fragment)) { '#...' } else { '' }

            if ([string]::IsNullOrEmpty($absolutePath) -or $absolutePath -eq '/') {
                return ($hostDisplay + '/' + $querySuffix + $fragmentSuffix)
            }

            $segments = @($absolutePath -split '/' | Where-Object { $_ -ne '' })
            if ($segments.Count -le 1) {
                return ($hostDisplay + $absolutePath + $querySuffix + $fragmentSuffix)
            }

            if ($absolutePath.EndsWith('/')) {
                return ($hostDisplay + '/.../' + $querySuffix + $fragmentSuffix)
            }

            $lastSegment = $segments[$segments.Count - 1]
            return ($hostDisplay + '/.../' + $lastSegment + $querySuffix + $fragmentSuffix)
        }
        catch {
            return $originalText
        }
    }

    function local:_GetResponseFromErrorRecord {
        param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

        foreach ($candidate in @($ErrorRecord.Exception, $ErrorRecord.Exception.InnerException)) {
            if ($null -eq $candidate) { continue }
            $responseProperty = $candidate.PSObject.Properties['Response']
            if ($responseProperty -and $null -ne $responseProperty.Value) {
                return $responseProperty.Value
            }
        }

        return $null
    }

    function local:_GetHttpStatusCodeFromErrorRecord {
        param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

        $response = _GetResponseFromErrorRecord -ErrorRecord $ErrorRecord
        if ($null -ne $response) {
            try {
                if ($null -ne $response.StatusCode) {
                    return [int]$response.StatusCode
                }
            }
            catch {
            }
        }

        foreach ($candidate in @($ErrorRecord.Exception, $ErrorRecord.Exception.InnerException)) {
            if ($null -eq $candidate) { continue }

            $statusCodeProperty = $candidate.PSObject.Properties['StatusCode']
            if ($statusCodeProperty -and $null -ne $statusCodeProperty.Value) {
                try {
                    return [int]$statusCodeProperty.Value
                }
                catch {
                }
            }
        }

        return $null
    }

    function local:_GetWwwAuthenticateValuesFromErrorRecord {
        param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

        $values = New-Object System.Collections.Generic.List[string]
        $response = _GetResponseFromErrorRecord -ErrorRecord $ErrorRecord

        if ($null -ne $response) {
            try {
                $headers = $response.Headers

                if ($null -ne $headers) {
                    $directValue = $headers['WWW-Authenticate']
                    if (-not [string]::IsNullOrWhiteSpace([string]$directValue)) {
                        $values.Add([string]$directValue)
                    }

                    $wwwAuthenticateProperty = $headers.PSObject.Properties['WwwAuthenticate']
                    if ($wwwAuthenticateProperty -and $null -ne $wwwAuthenticateProperty.Value) {
                        foreach ($headerValue in @($wwwAuthenticateProperty.Value)) {
                            if ($null -eq $headerValue) { continue }
                            $headerText = [string]$headerValue
                            if (-not [string]::IsNullOrWhiteSpace($headerText)) {
                                $values.Add($headerText)
                            }
                        }
                    }
                }
            }
            catch {
            }
        }

        $seen = @{}
        $result = New-Object System.Collections.Generic.List[string]
        foreach ($value in $values) {
            if (-not $seen.ContainsKey($value)) {
                $seen[$value] = $true
                $result.Add($value)
            }
        }

        return ,$result.ToArray()
    }

    function local:_TestIsPrivateOrIntranetAddress {
        param([Parameter(Mandatory = $true)][System.Net.IPAddress]$Address)

        if ([System.Net.IPAddress]::IsLoopback($Address)) { return $true }

        if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
            if ($Address.IsIPv4MappedToIPv6) {
                try { return _TestIsPrivateOrIntranetAddress -Address $Address.MapToIPv4() } catch { return $false }
            }

            $bytes = $Address.GetAddressBytes()
            if ($bytes.Length -ge 2) {
                if (($bytes[0] -band 0xFE) -eq 0xFC) { return $true }
                if ($bytes[0] -eq 0xFE -and ($bytes[1] -band 0xC0) -eq 0x80) { return $true }
            }

            return $false
        }

        if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            $bytes = $Address.GetAddressBytes()
            if ($bytes[0] -eq 10) { return $true }
            if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }
            if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }
            if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $true }
            if ($bytes[0] -eq 127) { return $true }
            return $false
        }

        return $false
    }

    function local:_GetAutoUseDefaultCredentialsGuardInfo {
        param([Parameter(Mandatory = $true)][uri]$TargetUri)

        $signals = New-Object System.Collections.Generic.List[string]
        $resolvedAddresses = New-Object System.Collections.Generic.List[string]

        $hostname = if (-not [string]::IsNullOrWhiteSpace($TargetUri.DnsSafeHost)) { $TargetUri.DnsSafeHost } else { $TargetUri.Host }

        if ($TargetUri.IsLoopback) {
            $signals.Add("The URI is loopback.")
        }

        if (-not [string]::IsNullOrWhiteSpace($hostname)) {
            $hostAddress = $null

            if ([System.Net.IPAddress]::TryParse($hostname, [ref]$hostAddress)) {
                $resolvedAddresses.Add($hostAddress.IPAddressToString)

                if (_TestIsPrivateOrIntranetAddress -Address $hostAddress) {
                    $signals.Add("The host is a private, link-local, or loopback IP address ('$($hostAddress.IPAddressToString)').")
                }
            }
            else {
                if ($hostname.IndexOf('.') -lt 0) {
                    $signals.Add("The host '$hostname' is dotless and intranet-like.")
                }

                try {
                    $addresses = [System.Net.Dns]::GetHostAddresses($hostname)
                    foreach ($address in $addresses) {
                        $addressText = $address.IPAddressToString

                        if (-not $resolvedAddresses.Contains($addressText)) {
                            $resolvedAddresses.Add($addressText)
                        }

                        if (_TestIsPrivateOrIntranetAddress -Address $address) {
                            $signals.Add("DNS resolved '$hostname' to private, link-local, or loopback address '$addressText'.")
                            break
                        }
                    }
                }
                catch {
                }
            }
        }

        return [pscustomobject]@{
            IsIntranetLike    = ($signals.Count -gt 0)
            Signals           = @($signals.ToArray())
            ResolvedAddresses = @($resolvedAddresses.ToArray())
        }
    }

    function local:_GetDownloadLocalState {
        param([Parameter(Mandatory = $true)][string]$Path)

        try {
            $fileInfo = New-Object System.IO.FileInfo($Path)
            if ($fileInfo.Exists) {
                return [pscustomobject]@{
                    Exists = $true
                    Length = [int64]$fileInfo.Length
                }
            }
        }
        catch {
        }

        return [pscustomobject]@{
            Exists = $false
            Length = 0L
        }
    }

    function local:_GetDownloadResponseInfo {
        param([Parameter(Mandatory = $true)][System.Net.HttpWebResponse]$Response)

        $headers = $null
        $statusCode = $null
        $contentLength = $null
        $acceptRanges = $null
        $etag = $null
        $lastModified = $null
        $contentRange = $null
        $contentRangeStart = $null
        $contentRangeTotalLength = $null

        try { $headers = $Response.Headers } catch {}
        try { if ($null -ne $Response.StatusCode) { $statusCode = [int]$Response.StatusCode } } catch {}
        try { if ($Response.ContentLength -ge 0) { $contentLength = [int64]$Response.ContentLength } } catch {}

        if ($null -ne $headers) {
            try { $acceptRanges = [string]$headers['Accept-Ranges'] } catch {}
            try { $etag = [string]$headers['ETag'] } catch {}
            try { $contentRange = [string]$headers['Content-Range'] } catch {}
        }

        if (-not [string]::IsNullOrWhiteSpace($contentRange)) {
            $match = [regex]::Match($contentRange, '^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$', 'IgnoreCase')
            if ($match.Success) {
                $contentRangeStart = [int64]$match.Groups[1].Value
                if ($match.Groups[3].Value -ne '*') {
                    $contentRangeTotalLength = [int64]$match.Groups[3].Value
                }
            }
            else {
                $match = [regex]::Match($contentRange, '^\s*bytes\s+\*/(\d+|\*)\s*$', 'IgnoreCase')
                if ($match.Success -and $match.Groups[1].Value -ne '*') {
                    $contentRangeTotalLength = [int64]$match.Groups[1].Value
                }
            }
        }

        try { $lastModified = $Response.LastModified } catch {}

        return [pscustomobject]@{
            StatusCode              = $statusCode
            ContentLength           = $contentLength
            AcceptRanges            = $acceptRanges
            ETag                    = $etag
            LastModified            = $lastModified
            ContentRange            = $contentRange
            ContentRangeStart       = $contentRangeStart
            ContentRangeTotalLength = $contentRangeTotalLength
        }
    }

    function local:_OpenDownloadFileStream {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter()][System.IO.FileMode]$FileMode = [System.IO.FileMode]::Create
        )

        return [System.IO.File]::Open(
            $Path,
            $FileMode,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    }

    function local:_GetResolvedDownloadPath {
        param([Parameter(Mandatory = $true)][string]$Path)

        try {
            return [System.IO.Path]::GetFullPath($Path)
        }
        catch {
            return $Path
        }
    }

    function local:_GetDownloadSidecarHash {
        param(
            [Parameter(Mandatory = $true)][uri]$TargetUri,
            [Parameter(Mandatory = $true)][string]$OutFilePath
        )

        $identityText = "{0}`n{1}" -f $TargetUri.AbsoluteUri, $OutFilePath
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identityText)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()

        try {
            $hashBytes = $sha256.ComputeHash($bytes)
        }
        finally {
            $sha256.Dispose()
        }

        return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant())
    }

    function local:_GetDownloadLockPath {
        param(
            [Parameter(Mandatory = $true)][uri]$TargetUri,
            [Parameter(Mandatory = $true)][string]$OutFilePath
        )

        $hash = _GetDownloadSidecarHash -TargetUri $TargetUri -OutFilePath $OutFilePath
        return ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("InvokeWebRequestEx_{0}.lock" -f $hash)))
    }

    function local:_GetResumeMetadataPath {
        param(
            [Parameter(Mandatory = $true)][uri]$TargetUri,
            [Parameter(Mandatory = $true)][string]$OutFilePath
        )

        $hash = _GetDownloadSidecarHash -TargetUri $TargetUri -OutFilePath $OutFilePath
        return ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("InvokeWebRequestEx_{0}.resume" -f $hash)))
    }

    function local:_ReadJsonFile {
        param([Parameter(Mandatory = $true)][string]$Path)

        if (-not [System.IO.File]::Exists($Path)) { return $null }

        try {
            $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            return ($raw | ConvertFrom-Json)
        }
        catch {
            return $null
        }
    }

    function local:_WriteJsonFile {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][object]$Data
        )

        $json = $Data | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
    }

    function local:_RemoveFileIfExists {
        param([Parameter(Mandatory = $true)][string]$Path)

        try {
            if ([System.IO.File]::Exists($Path)) {
                [System.IO.File]::Delete($Path)
            }
        }
        catch {
        }
    }

    function local:_GetCurrentProcessStartTimeUtcText {
        try {
            return ([System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o'))
        }
        catch {
            return $null
        }
    }

    function local:_TestDownloadLockIsStale {
        param([Parameter(Mandatory = $true)][string]$LockPath)

        $lockData = _ReadJsonFile -Path $LockPath
        if ($null -eq $lockData) {
            return $true
        }

        $pidValue = $null
        $startTimeValue = $null

        try { $pidValue = [int]$lockData.Pid } catch {}
        try { $startTimeValue = [string]$lockData.ProcessStartTimeUtc } catch {}

        if ($null -eq $pidValue) {
            return $true
        }

        try {
            $proc = Get-Process -Id $pidValue -ErrorAction Stop
        }
        catch {
            return $true
        }

        if ([string]::IsNullOrWhiteSpace($startTimeValue)) {
            return $false
        }

        try {
            $actualStartTime = $proc.StartTime.ToUniversalTime().ToString('o')
            if ($actualStartTime -ne $startTimeValue) {
                return $true
            }
        }
        catch {
            return $false
        }

        return $false
    }

    function local:_GetFileHashHex {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][ValidateSet('SHA256')][string]$Algorithm
        )

        $algorithmInstance = $null
        $stream = $null

        try {
            switch ($Algorithm.ToUpperInvariant()) {
                'SHA256' { $algorithmInstance = [System.Security.Cryptography.SHA256]::Create() }
                default { throw ("Unsupported hash algorithm '{0}'." -f $Algorithm) }
            }

            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $hashBytes = $algorithmInstance.ComputeHash($stream)
            return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToUpperInvariant())
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
            if ($null -ne $algorithmInstance) { $algorithmInstance.Dispose() }
        }
    }

    $uriDisplay = _UriDisplayShortener -TargetUri $Uri
    Write-StandardMessage -Message ("[STATUS] Initializing Invoke-WebRequestEx for '{0}'." -f $uriDisplay) -Level INF

    $effectiveMethod = if ($PSBoundParameters.ContainsKey('Method') -and -not [string]::IsNullOrWhiteSpace($Method)) {
        $Method.ToUpperInvariant()
    }
    else {
        'GET'
    }

    $runningOnPwsh = $PSVersionTable.PSEdition -eq 'Core'
    $nativeSupportsSkipCertificateCheck = $runningOnPwsh -and $PSVersionTable.PSVersion -ge [version]'7.0'

    $explicitCredentialSupplied = $PSBoundParameters.ContainsKey('Credential') -and $null -ne $Credential
    $explicitUseDefaultCredentialsSupplied = $PSBoundParameters.ContainsKey('UseDefaultCredentials')
    $autoUseDefaultCredentialsAllowed =
        (-not $DisableAutoUseDefaultCredentials) -and
        (-not $explicitCredentialSupplied) -and
        (-not $explicitUseDefaultCredentialsSupplied)

    $autoUpgradedToDefaultCredentials = $false
    $autoUseDefaultCredentialsGuardInfo = $null
    $autoUseDefaultCredentialsGuardInfoResolved = $false

    $callParams = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        switch ($entry.Key) {
            'SkipCertificateCheck' {
                if ($nativeSupportsSkipCertificateCheck) {
                    $callParams[$entry.Key] = $entry.Value
                }
                continue
            }
            'DisableAutoUseDefaultCredentials' { continue }
            'RetryCount' { continue }
            'RetryDelayMilliseconds' { continue }
            'TotalTimeoutSec' { continue }
            'BufferSizeBytes' { continue }
            'ProgressIntervalPercent' { continue }
            'ProgressIntervalBytes' { continue }
            'DeletePartialStreamingDownloadOnFailure' { continue }
            'DeleteStreamingFragmentsOnFailure' { continue }
            'UseStreamingDownload' { continue }
            'DisableResumeStreamingDownload' { continue }
            'RequiredStreamingHashType' { continue }
            'RequiredStreamingHash' { continue }
            default { $callParams[$entry.Key] = $entry.Value }
        }
    }

    $streamingHashValidationRequested =
        $PSBoundParameters.ContainsKey('RequiredStreamingHashType') -or
        $PSBoundParameters.ContainsKey('RequiredStreamingHash')

    if ($streamingHashValidationRequested) {
        if (-not $PSBoundParameters.ContainsKey('RequiredStreamingHashType') -or [string]::IsNullOrWhiteSpace($RequiredStreamingHashType)) {
            Write-StandardMessage -Message ("[ERR] Parameter 'RequiredStreamingHashType' is required when 'RequiredStreamingHash' is supplied.") -Level ERR
            return
        }

        if (-not $PSBoundParameters.ContainsKey('RequiredStreamingHash') -or [string]::IsNullOrWhiteSpace($RequiredStreamingHash)) {
            Write-StandardMessage -Message ("[ERR] Parameter 'RequiredStreamingHash' is required when 'RequiredStreamingHashType' is supplied.") -Level ERR
            return
        }

        $RequiredStreamingHash = $RequiredStreamingHash.Trim().ToUpperInvariant()
    }

    $previousSecurityProtocol = $null
    $securityProtocolChanged = $false

    try {
        $tls12 = [System.Net.SecurityProtocolType]::Tls12
        $previousSecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol

        if (($previousSecurityProtocol -band $tls12) -ne $tls12) {
            [System.Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol -bor $tls12
            $securityProtocolChanged = $true
            Write-StandardMessage -Message ("[STATUS] Added TLS 1.2 to the current process security protocol flags.") -Level INF
        }
    }
    catch {
        Write-StandardMessage -Message ("[WRN] Failed to ensure TLS 1.2: {0}" -f $_) -Level WRN
    }

    if ($PSBoundParameters.ContainsKey('OutFile')) {
        try {
            $directory = [System.IO.Path]::GetDirectoryName($OutFile)
            if (-not [string]::IsNullOrWhiteSpace($directory)) {
                if (-not [System.IO.Directory]::Exists($directory)) {
                    [void][System.IO.Directory]::CreateDirectory($directory)
                    Write-StandardMessage -Message ("[STATUS] Created output directory '{0}'." -f $directory) -Level INF
                }
            }
        }
        catch {
            Write-StandardMessage -Message ("[ERR] Failed to prepare output directory for '{0}': {1}" -f $OutFile, $_) -Level ERR
            return
        }
    }

    $callerHandledProxy =
        $PSBoundParameters.ContainsKey('Proxy') -or
        $PSBoundParameters.ContainsKey('ProxyCredential') -or
        $PSBoundParameters.ContainsKey('ProxyUseDefaultCredentials')

    if (-not $callerHandledProxy) {
        try {
            $systemProxy = [System.Net.WebRequest]::GetSystemWebProxy()
            $systemProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials

            if (-not $systemProxy.IsBypassed($Uri)) {
                $proxyUri = $systemProxy.GetProxy($Uri)
                if ($null -ne $proxyUri -and $proxyUri.AbsoluteUri -ne $Uri.AbsoluteUri) {
                    $callParams['Proxy'] = $proxyUri
                    $callParams['ProxyUseDefaultCredentials'] = $true
                    Write-StandardMessage -Message ("[STATUS] Using auto-discovered proxy '{0}' for '{1}'." -f $proxyUri.AbsoluteUri, $uriDisplay) -Level INF
                }
                else {
                    Write-StandardMessage -Message ("[STATUS] System proxy configuration resolved no distinct proxy for '{0}'." -f $uriDisplay) -Level INF
                }
            }
            else {
                Write-StandardMessage -Message ("[STATUS] System proxy bypass is active for '{0}'." -f $uriDisplay) -Level INF
            }
        }
        catch {
            Write-StandardMessage -Message ("[WRN] Failed to auto-discover proxy for '{0}': {1}" -f $uriDisplay, $_) -Level WRN
        }
    }
    else {
        Write-StandardMessage -Message ("[STATUS] Caller supplied proxy-related parameters for '{0}'. Auto-discovery is skipped." -f $uriDisplay) -Level INF
    }

    $useStreamingEngine = $false
    $streamingCompatible = $false

    $isDownloadShape =
        $PSBoundParameters.ContainsKey('OutFile') -and
        $effectiveMethod -eq 'GET'

    if ($UseStreamingDownload -or $isDownloadShape) {
        $streamingCompatible = $true

        if (-not $PSBoundParameters.ContainsKey('OutFile')) { $streamingCompatible = $false }
        if ($effectiveMethod -ne 'GET') { $streamingCompatible = $false }

        $incompatibleParameters = @(
            'PassThru',
            'WebSession',
            'SessionVariable',
            'InFile',
            'Body',
            'ContentType',
            'TransferEncoding',
            'CertificateThumbprint',
            'Certificate'
        )

        foreach ($parameterName in $incompatibleParameters) {
            if ($PSBoundParameters.ContainsKey($parameterName)) {
                $streamingCompatible = $false
                break
            }
        }

        if ($streamingCompatible -and $Headers) {
            foreach ($headerKey in $Headers.Keys) {
                $headerName = [string]$headerKey
                if ($headerName -match '^(?i:Cookie|Date|Range)$') {
                    $streamingCompatible = $false
                    break
                }
            }
        }

        if ($streamingCompatible) {
            $useStreamingEngine = $true
        }
        elseif ($UseStreamingDownload) {
            Write-StandardMessage -Message ("[WRN] Streaming download was requested, but the current parameter combination is not safely compatible. Falling back to native Invoke-WebRequest for '{0}'." -f $uriDisplay) -Level WRN
        }
    }

    if ($streamingHashValidationRequested -and -not $useStreamingEngine) {
        Write-StandardMessage -Message ("[ERR] Required streaming hash validation is only supported for the streaming download path (GET + OutFile compatible requests).") -Level ERR
        return
    }

    if ($nativeSupportsSkipCertificateCheck -and $SkipCertificateCheck) {
        $useStreamingEngine = $false
        Write-StandardMessage -Message ("[STATUS] PowerShell {0} will pass -SkipCertificateCheck directly to native Invoke-WebRequest. Streaming path is disabled for '{1}'." -f $PSVersionTable.PSVersion, $uriDisplay) -Level INF
    }

    if ($streamingHashValidationRequested -and -not $useStreamingEngine) {
        Write-StandardMessage -Message ("[ERR] Required streaming hash validation is only supported for the streaming download path in the effective request configuration.") -Level ERR
        return
    }

    if ($useStreamingEngine) {
        Write-StandardMessage -Message ("[STATUS] Using the streaming download path for '{0}'." -f $uriDisplay) -Level INF
    }
    else {
        Write-StandardMessage -Message ("[STATUS] Using the native Invoke-WebRequest path for '{0}'." -f $uriDisplay) -Level INF
    }

    $downloadTargetExistedBeforeInvocation = $false
    $resolvedOutFilePath = $null
    $resumeMetadataPath = $null
    $downloadLockPath = $null

    if ($useStreamingEngine -and -not [string]::IsNullOrWhiteSpace($OutFile)) {
        $downloadTargetStateAtInvocation = _GetDownloadLocalState -Path $OutFile
        $downloadTargetExistedBeforeInvocation = [bool]$downloadTargetStateAtInvocation.Exists

        $resolvedOutFilePath = _GetResolvedDownloadPath -Path $OutFile
        $downloadLockPath = _GetDownloadLockPath -TargetUri $Uri -OutFilePath $resolvedOutFilePath

        if (-not $DisableResumeStreamingDownload) {
            $resumeMetadataPath = _GetResumeMetadataPath -TargetUri $Uri -OutFilePath $resolvedOutFilePath
        }
    }

    $previousCertificateValidationCallback = $null
    $skipCertificateCheckEnabled = $false

    try {
        if ($SkipCertificateCheck -and -not $nativeSupportsSkipCertificateCheck) {
            try {
                Write-StandardMessage -Message ("[STATUS] Enabling temporary certificate validation bypass for '{0}'." -f $uriDisplay) -Level INF

                if (-not ('CertificateValidationHelper' -as [type])) {
                    Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class CertificateValidationHelper
{
    public static bool AcceptAll(
        object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors)
    {
        return true;
    }
}
'@
                }

                $bindingFlags =
                    [System.Reflection.BindingFlags]::Public -bor
                    [System.Reflection.BindingFlags]::Static

                $methodInfo = [CertificateValidationHelper].GetMethod('AcceptAll', $bindingFlags)
                if ($null -eq $methodInfo) {
                    throw "Failed to resolve CertificateValidationHelper.AcceptAll."
                }

                $acceptAllCallback = [System.Net.Security.RemoteCertificateValidationCallback](
                    [System.Delegate]::CreateDelegate(
                        [System.Net.Security.RemoteCertificateValidationCallback],
                        $methodInfo
                    )
                )

                $previousCertificateValidationCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $acceptAllCallback
                $skipCertificateCheckEnabled = $true
            }
            catch {
                Write-StandardMessage -Message ("[ERR] Failed to enable temporary certificate validation bypass for '{0}': {1}" -f $uriDisplay, $_) -Level ERR
                return
            }
        }

        $retryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        for ($attemptIndex = 1; $attemptIndex -le $RetryCount; $attemptIndex++) {
            $requestUseDefaultCredentials =
                ($autoUpgradedToDefaultCredentials) -or
                ($explicitUseDefaultCredentialsSupplied -and [bool]$UseDefaultCredentials)

            if (-not $requestUseDefaultCredentials -and $callParams.ContainsKey('UseDefaultCredentials') -and -not $explicitUseDefaultCredentialsSupplied) {
                [void]$callParams.Remove('UseDefaultCredentials')
            }

            if ($requestUseDefaultCredentials -and -not $useStreamingEngine) {
                $callParams['UseDefaultCredentials'] = $true
            }

            if ($attemptIndex -gt 1) {
                Write-StandardMessage -Message ("[STATUS] Starting attempt {0} of {1} for {2} {3}." -f $attemptIndex, $RetryCount, $effectiveMethod, $uriDisplay) -Level INF
            }

            while ($true) {
                try {
                    if ($useStreamingEngine) {
                        $request = $null
                        $response = $null
                        $responseStream = $null
                        $fileStream = $null
                        $downloadLockAcquired = $false
                        $forceFreshDownload = $false

                        while ($true) {
                            if (-not $downloadLockAcquired) {
                                while (-not $downloadLockAcquired) {
                                    try {
                                        $lockStream = [System.IO.File]::Open(
                                            $downloadLockPath,
                                            [System.IO.FileMode]::CreateNew,
                                            [System.IO.FileAccess]::Write,
                                            [System.IO.FileShare]::None
                                        )

                                        try {
                                            $lockData = [pscustomobject]@{
                                                Pid                 = $PID
                                                ProcessStartTimeUtc = (_GetCurrentProcessStartTimeUtcText)
                                            }

                                            $lockJson = $lockData | ConvertTo-Json -Depth 3
                                            $lockBytes = [System.Text.Encoding]::UTF8.GetBytes($lockJson)
                                            $lockStream.Write($lockBytes, 0, $lockBytes.Length)
                                            $lockStream.Flush()
                                        }
                                        finally {
                                            $lockStream.Dispose()
                                        }

                                        $downloadLockAcquired = $true
                                        break
                                    }
                                    catch [System.IO.IOException] {
                                        if (_TestDownloadLockIsStale -LockPath $downloadLockPath) {
                                            Write-StandardMessage -Message ("[STATUS] Removing stale download lock '{0}'." -f $downloadLockPath) -Level WRN
                                            _RemoveFileIfExists -Path $downloadLockPath
                                            continue
                                        }

                                        $remainingMillisecondsForLock = [int]::MaxValue
                                        if ($TotalTimeoutSec -gt 0) {
                                            $remainingMillisecondsForLock = [int](($TotalTimeoutSec * 1000) - $retryStopwatch.ElapsedMilliseconds)
                                        }

                                        if ($TotalTimeoutSec -gt 0 -and $remainingMillisecondsForLock -le 0) {
                                            throw ("Timed out while waiting for download lock '{0}'." -f $downloadLockPath)
                                        }

                                        Write-StandardMessage -Message ("[STATUS] Another process is downloading '{0}'. Waiting for lock '{1}' to clear." -f $uriDisplay, $downloadLockPath) -Level INF

                                        $sleepForLockMs = $RetryDelayMilliseconds
                                        if ($TotalTimeoutSec -gt 0 -and $sleepForLockMs -gt $remainingMillisecondsForLock) {
                                            $sleepForLockMs = $remainingMillisecondsForLock
                                        }
                                        if ($sleepForLockMs -lt 0) { $sleepForLockMs = 0 }

                                        if ($sleepForLockMs -gt 0) {
                                            Start-Sleep -Milliseconds $sleepForLockMs
                                        }
                                    }
                                }
                            }

                            $downloadState = [pscustomobject]@{
                                FileExistedBeforeAttempt   = $false
                                ExistingFileLength         = 0L
                                StartingOffset             = 0L
                                ResumeRequested            = $false
                                ResumeApplied              = $false
                                BytesDownloadedThisAttempt = 0L
                                TotalBytesOnDisk           = 0L
                                ResponseStatusCode         = $null
                                RemoteContentLength        = $null
                                RemoteAcceptRanges         = $null
                                RemoteETag                 = $null
                                RemoteLastModified         = $null
                                RemoteContentRange         = $null
                                RemoteContentRangeStart    = $null
                                RemoteTotalLength          = $null
                            }

                            try {
                                $localDownloadState = _GetDownloadLocalState -Path $OutFile
                                $downloadState.FileExistedBeforeAttempt = [bool]$localDownloadState.Exists
                                $downloadState.ExistingFileLength = [int64]$localDownloadState.Length

                                if (
                                    -not $forceFreshDownload -and
                                    -not $DisableResumeStreamingDownload -and
                                    $downloadState.FileExistedBeforeAttempt -and
                                    $downloadState.ExistingFileLength -gt 0
                                ) {
                                    $downloadState.ResumeRequested = $true
                                    $downloadState.StartingOffset = $downloadState.ExistingFileLength
                                    $downloadState.TotalBytesOnDisk = $downloadState.StartingOffset

                                    Write-StandardMessage -Message ("[STATUS] Attempting resume for '{0}' from byte {1}." -f $uriDisplay, $downloadState.StartingOffset) -Level INF
                                }
                                else {
                                    $downloadState.StartingOffset = 0L
                                    $downloadState.TotalBytesOnDisk = 0L
                                }

                                $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
                                if ($null -eq $request) {
                                    throw ("Failed to create HttpWebRequest for '{0}'." -f $uriDisplay)
                                }

                                $request.Method = 'GET'

                                if ($downloadState.ResumeRequested) {
                                    $request.AutomaticDecompression = [System.Net.DecompressionMethods]::None
                                }
                                else {
                                    $request.AutomaticDecompression =
                                        [System.Net.DecompressionMethods]::GZip -bor
                                        [System.Net.DecompressionMethods]::Deflate
                                }

                                if ($DisableKeepAlive) {
                                    $request.KeepAlive = $false
                                }

                                if ($PSBoundParameters.ContainsKey('MaximumRedirection')) {
                                    if ($MaximumRedirection -le 0) {
                                        $request.AllowAutoRedirect = $false
                                    }
                                    else {
                                        $request.AllowAutoRedirect = $true
                                        $request.MaximumAutomaticRedirections = $MaximumRedirection
                                    }
                                }

                                if ($TimeoutSec -gt 0) {
                                    $timeoutMilliseconds = $TimeoutSec * 1000
                                    $request.Timeout = $timeoutMilliseconds
                                    $request.ReadWriteTimeout = $timeoutMilliseconds
                                }

                                if ($explicitCredentialSupplied) {
                                    $request.Credentials = $Credential
                                }
                                elseif ($requestUseDefaultCredentials) {
                                    $request.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                                }

                                if ($callParams.ContainsKey('Proxy') -and $null -ne $callParams['Proxy']) {
                                    $webProxy = New-Object System.Net.WebProxy(([uri]$callParams['Proxy']).AbsoluteUri, $true)

                                    if ($PSBoundParameters.ContainsKey('ProxyCredential') -and $null -ne $ProxyCredential) {
                                        $webProxy.Credentials = $ProxyCredential
                                    }
                                    elseif ($callParams.ContainsKey('ProxyUseDefaultCredentials') -and [bool]$callParams['ProxyUseDefaultCredentials']) {
                                        $webProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                                    }

                                    $request.Proxy = $webProxy
                                }

                                if ($PSBoundParameters.ContainsKey('UserAgent') -and -not [string]::IsNullOrWhiteSpace($UserAgent)) {
                                    $request.UserAgent = $UserAgent
                                }

                                if ($Headers) {
                                    foreach ($headerKey in $Headers.Keys) {
                                        $headerName = [string]$headerKey
                                        $headerValue = [string]$Headers[$headerKey]

                                        switch -Regex ($headerName) {
                                            '^(?i:Accept)$' {
                                                $request.Accept = $headerValue
                                                continue
                                            }
                                            '^(?i:Connection)$' {
                                                if ($headerValue -match '^(?i:close)$') {
                                                    $request.KeepAlive = $false
                                                }
                                                else {
                                                    $request.Connection = $headerValue
                                                }
                                                continue
                                            }
                                            '^(?i:Content-Type)$' {
                                                $request.ContentType = $headerValue
                                                continue
                                            }
                                            '^(?i:Expect)$' {
                                                $request.Expect = $headerValue
                                                continue
                                            }
                                            '^(?i:Host)$' {
                                                $request.Host = $headerValue
                                                continue
                                            }
                                            '^(?i:If-Modified-Since)$' {
                                                $request.IfModifiedSince = [DateTime]::Parse($headerValue, [System.Globalization.CultureInfo]::InvariantCulture)
                                                continue
                                            }
                                            '^(?i:Referer)$' {
                                                $request.Referer = $headerValue
                                                continue
                                            }
                                            '^(?i:Transfer-Encoding)$' {
                                                $request.SendChunked = $true
                                                $request.TransferEncoding = $headerValue
                                                continue
                                            }
                                            '^(?i:User-Agent)$' {
                                                if ([string]::IsNullOrWhiteSpace($request.UserAgent)) {
                                                    $request.UserAgent = $headerValue
                                                }
                                                continue
                                            }
                                            default {
                                                $request.Headers[$headerName] = $headerValue
                                                continue
                                            }
                                        }
                                    }
                                }

                                if ($downloadState.ResumeRequested) {
                                    $request.AddRange([long]$downloadState.StartingOffset)
                                }

                                Write-StandardMessage -Message ("[STATUS] Sending streaming GET request to '{0}'." -f $uriDisplay) -Level INF

                                $response = [System.Net.HttpWebResponse]$request.GetResponse()
                                $responseStream = $response.GetResponseStream()

                                if ($null -eq $responseStream) {
                                    throw ("The remote server returned an empty response stream for '{0}'." -f $uriDisplay)
                                }

                                $downloadResponseInfo = _GetDownloadResponseInfo -Response $response
                                $downloadState.ResponseStatusCode = $downloadResponseInfo.StatusCode
                                $downloadState.RemoteContentLength = $downloadResponseInfo.ContentLength
                                $downloadState.RemoteAcceptRanges = $downloadResponseInfo.AcceptRanges
                                $downloadState.RemoteETag = $downloadResponseInfo.ETag
                                $downloadState.RemoteLastModified = $downloadResponseInfo.LastModified
                                $downloadState.RemoteContentRange = $downloadResponseInfo.ContentRange
                                $downloadState.RemoteContentRangeStart = $downloadResponseInfo.ContentRangeStart
                                $downloadState.RemoteTotalLength = $downloadResponseInfo.ContentRangeTotalLength

                                if ($downloadState.ResumeRequested) {
                                    if ($downloadState.ResponseStatusCode -eq 206) {
                                        if ($null -eq $downloadState.RemoteContentRangeStart -or $downloadState.RemoteContentRangeStart -ne $downloadState.StartingOffset) {
                                            throw ("The server returned a partial response for '{0}', but the content range did not match the requested resume offset {1}." -f $uriDisplay, $downloadState.StartingOffset)
                                        }

                                        $resumeMetadata = $null
                                        if (-not [string]::IsNullOrWhiteSpace($resumeMetadataPath)) {
                                            $resumeMetadata = _ReadJsonFile -Path $resumeMetadataPath
                                        }

                                        $resumeIdentityMatches = $false

                                        if ($null -ne $resumeMetadata) {
                                            $storedUri = $null
                                            $storedETag = $null
                                            $storedLastModified = $null
                                            try { $storedUri = [string]$resumeMetadata.Uri } catch {}
                                            try { $storedETag = [string]$resumeMetadata.ETag } catch {}
                                            try { $storedLastModified = [string]$resumeMetadata.LastModified } catch {}

                                            if (-not [string]::IsNullOrWhiteSpace($storedUri) -and $storedUri -eq [string]$Uri.AbsoluteUri) {
                                                if (-not [string]::IsNullOrWhiteSpace($storedETag) -and -not [string]::IsNullOrWhiteSpace([string]$downloadState.RemoteETag)) {
                                                    if ($storedETag -eq [string]$downloadState.RemoteETag) {
                                                        $resumeIdentityMatches = $true
                                                    }
                                                }
                                                elseif (-not [string]::IsNullOrWhiteSpace($storedLastModified) -and $null -ne $downloadState.RemoteLastModified) {
                                                    $currentLastModifiedText = $downloadState.RemoteLastModified.ToUniversalTime().ToString('o')
                                                    if ($storedLastModified -eq $currentLastModifiedText) {
                                                        $resumeIdentityMatches = $true
                                                    }
                                                }
                                            }
                                        }

                                        if (-not $resumeIdentityMatches) {
                                            Write-StandardMessage -Message ("[WRN] Resume metadata for '{0}' is missing or does not match the current remote object. Restarting from byte 0." -f $uriDisplay) -Level WRN

                                            if ($null -ne $responseStream) { $responseStream.Dispose(); $responseStream = $null }
                                            if ($null -ne $response) { $response.Close(); $response = $null }

                                            $forceFreshDownload = $true
                                            continue
                                        }

                                        $downloadState.ResumeApplied = $true
                                        Write-StandardMessage -Message ("[STATUS] Resume accepted by the server for '{0}' at byte {1}." -f $uriDisplay, $downloadState.StartingOffset) -Level INF
                                    }
                                    elseif ($downloadState.ResponseStatusCode -eq 200) {
                                        Write-StandardMessage -Message ("[WRN] The server ignored the resume range for '{0}'. Restarting the download from byte 0." -f $uriDisplay) -Level WRN

                                        if ($null -ne $responseStream) { $responseStream.Dispose(); $responseStream = $null }
                                        if ($null -ne $response) { $response.Close(); $response = $null }

                                        $forceFreshDownload = $true
                                        continue
                                    }
                                    else {
                                        throw ("The server returned unexpected HTTP status {0} for resumed download '{1}'." -f $downloadState.ResponseStatusCode, $uriDisplay)
                                    }
                                }

                                if ($downloadState.ResumeApplied) {
                                    $fileStream = _OpenDownloadFileStream -Path $OutFile -FileMode ([System.IO.FileMode]::Append)
                                }
                                else {
                                    $fileStream = _OpenDownloadFileStream -Path $OutFile -FileMode ([System.IO.FileMode]::Create)
                                }

                                if (-not [string]::IsNullOrWhiteSpace($resumeMetadataPath)) {
                                    $metadataLastModifiedText = $null
                                    if ($null -ne $downloadState.RemoteLastModified) {
                                        try {
                                            $metadataLastModifiedText = $downloadState.RemoteLastModified.ToUniversalTime().ToString('o')
                                        }
                                        catch {
                                        }
                                    }

                                    $metadataToPersist = [pscustomobject]@{
                                        Uri          = [string]$Uri.AbsoluteUri
                                        ETag         = if ($null -ne $downloadState.RemoteETag) { [string]$downloadState.RemoteETag } else { $null }
                                        LastModified = $metadataLastModifiedText
                                    }
                                    _WriteJsonFile -Path $resumeMetadataPath -Data $metadataToPersist
                                }

                                $buffer = New-Object byte[] $BufferSizeBytes
                                $lastReportedPercent = $null

                                if ($null -ne $downloadState.RemoteTotalLength) {
                                    $contentLength = [long]$downloadState.RemoteTotalLength
                                }
                                elseif ($downloadState.ResumeApplied -and $null -ne $downloadState.RemoteContentLength) {
                                    $contentLength = [long]($downloadState.StartingOffset + $downloadState.RemoteContentLength)
                                }
                                elseif ($null -ne $downloadState.RemoteContentLength) {
                                    $contentLength = [long]$downloadState.RemoteContentLength
                                }
                                else {
                                    $contentLength = -1L
                                }

                                $displayThresholdBytes = 1048576L
                                $useMegabyteDisplay = $contentLength -gt $displayThresholdBytes

                                if ($contentLength -gt 0) {
                                    $progressThresholdBytes = [long][Math]::Floor($contentLength * ($ProgressIntervalPercent / 100.0))
                                    if ($progressThresholdBytes -lt 1048576) {
                                        $progressThresholdBytes = 1048576
                                    }
                                }
                                else {
                                    $progressThresholdBytes = $ProgressIntervalBytes
                                }

                                if ($progressThresholdBytes -le 0) {
                                    $progressThresholdBytes = 1048576
                                }

                                $nextProgressBytes = $downloadState.StartingOffset + $progressThresholdBytes

                                while ($true) {
                                    $bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)
                                    if ($bytesRead -le 0) { break }

                                    $fileStream.Write($buffer, 0, $bytesRead)
                                    $downloadState.BytesDownloadedThisAttempt += [long]$bytesRead
                                    $downloadState.TotalBytesOnDisk = $downloadState.StartingOffset + $downloadState.BytesDownloadedThisAttempt

                                    if ($downloadState.TotalBytesOnDisk -ge $nextProgressBytes) {
                                        if ($contentLength -gt 0) {
                                            $percent = [int][Math]::Floor(($downloadState.TotalBytesOnDisk * 100.0) / $contentLength)
                                            if ($ProgressIntervalPercent -gt 1) {
                                                $percent = [int]([Math]::Floor($percent / [double]$ProgressIntervalPercent) * $ProgressIntervalPercent)
                                            }
                                            if ($percent -lt $ProgressIntervalPercent) { $percent = $ProgressIntervalPercent }
                                            if ($percent -gt 100) { $percent = 100 }

                                            $lastReportedPercent = $percent

                                            if ($useMegabyteDisplay) {
                                                $downloadedMbText = ([int64][Math]::Round($downloadState.TotalBytesOnDisk / 1048576.0, 0)).ToString()
                                                $contentLengthMbText = ([int64][Math]::Round($contentLength / 1048576.0, 0)).ToString()
                                                $percentText = $percent.ToString().PadLeft(3)
                                                $downloadedMbText = $downloadedMbText.PadLeft($contentLengthMbText.Length)

                                                Write-StandardMessage -Message ("[DL] {0} MB of {1} MB ({2} %) for '{3}'." -f $downloadedMbText, $contentLengthMbText, $percentText, $uriDisplay) -Level INF
                                            }
                                            else {
                                                $percentText = $percent.ToString().PadLeft(3)
                                                Write-StandardMessage -Message ("[DL] {0} of {1} bytes ({2} %) for '{3}'." -f $downloadState.TotalBytesOnDisk, $contentLength, $percentText, $uriDisplay) -Level INF
                                            }
                                        }
                                        else {
                                            $megaBytesText = ([int64][Math]::Round($downloadState.TotalBytesOnDisk / 1048576.0, 0)).ToString()
                                            Write-StandardMessage -Message ("[DL] ~{0} MB from '{1}'." -f $megaBytesText, $uriDisplay) -Level INF
                                        }

                                        $nextProgressBytes += $progressThresholdBytes
                                    }
                                }

                                if ($contentLength -gt 0) {
                                    if ($lastReportedPercent -ne 100) {
                                        if ($useMegabyteDisplay) {
                                            $totalMbText = ([int64][Math]::Round($downloadState.TotalBytesOnDisk / 1048576.0, 0)).ToString()
                                            $contentLengthMbText = ([int64][Math]::Round($contentLength / 1048576.0, 0)).ToString()
                                            $totalMbText = $totalMbText.PadLeft($contentLengthMbText.Length)

                                            Write-StandardMessage -Message ("[DL] {0} MB of {1} MB (100 %) for '{2}'." -f $totalMbText, $contentLengthMbText, $uriDisplay) -Level INF
                                        }
                                        else {
                                            Write-StandardMessage -Message ("[DL] {0} of {1} bytes (100 %) for '{2}'." -f $downloadState.TotalBytesOnDisk, $contentLength, $uriDisplay) -Level INF
                                        }
                                    }
                                }
                                else {
                                    $finalMbText = ([int64][Math]::Round($downloadState.TotalBytesOnDisk / 1048576.0, 0)).ToString()
                                    Write-StandardMessage -Message ("[DL] Complete, total {0} MB from '{1}'." -f $finalMbText, $uriDisplay) -Level INF
                                }

                                if ($streamingHashValidationRequested) {
                                    Write-StandardMessage -Message ("[STATUS] Verifying {0} for '{1}'." -f $RequiredStreamingHashType, $OutFile) -Level INF
                                    $actualStreamingHash = _GetFileHashHex -Path $OutFile -Algorithm $RequiredStreamingHashType

                                    if ($actualStreamingHash -ne $RequiredStreamingHash) {
                                        $hashMismatchMessage = ("Required {0} mismatch for '{1}'. Expected '{2}', actual '{3}'." -f $RequiredStreamingHashType, $OutFile, $RequiredStreamingHash, $actualStreamingHash)

                                        if ($null -ne $fileStream) { $fileStream.Dispose(); $fileStream = $null }
                                        if (-not [string]::IsNullOrWhiteSpace($resumeMetadataPath)) {
                                            _RemoveFileIfExists -Path $resumeMetadataPath
                                        }
                                        if ([System.IO.File]::Exists($OutFile)) {
                                            try { [System.IO.File]::Delete($OutFile) } catch {}
                                        }

                                        throw $hashMismatchMessage
                                    }

                                    Write-StandardMessage -Message ("[OK] Required {0} matched for '{1}'." -f $RequiredStreamingHashType, $OutFile) -Level INF
                                }

                                if (-not [string]::IsNullOrWhiteSpace($resumeMetadataPath)) {
                                    _RemoveFileIfExists -Path $resumeMetadataPath
                                }

                                Write-StandardMessage -Message ("[OK] Wrote {0} bytes from '{1}' to '{2}' on attempt {3} of {4}. File size is now {5} bytes." -f $downloadState.BytesDownloadedThisAttempt, $uriDisplay, $OutFile, $attemptIndex, $RetryCount, $downloadState.TotalBytesOnDisk) -Level INF
                                return
                            }
                            finally {
                                if ($null -ne $responseStream) { $responseStream.Dispose() }
                                if ($null -ne $fileStream) { $fileStream.Dispose() }
                                if ($null -ne $response) { $response.Close() }
                            }
                        }
                    }
                    else {
                        $result = Invoke-WebRequest @callParams
                        Write-StandardMessage -Message ("[OK] Request completed successfully on attempt {0} of {1} for {2} {3}." -f $attemptIndex, $RetryCount, $effectiveMethod, $uriDisplay) -Level INF
                        return $result
                    }
                }
                catch {
                    $caughtError = $_
                    $statusCode = _GetHttpStatusCodeFromErrorRecord -ErrorRecord $caughtError

                    if ($useStreamingEngine -and -not $DisableResumeStreamingDownload -and $statusCode -eq 416 -and -not [string]::IsNullOrWhiteSpace($OutFile)) {
                        try {
                            $localStateOn416 = _GetDownloadLocalState -Path $OutFile
                            if ($localStateOn416.Exists -and $localStateOn416.Length -gt 0) {
                                $errorResponse = _GetResponseFromErrorRecord -ErrorRecord $caughtError
                                if ($null -ne $errorResponse) {
                                    $errorResponseInfo = _GetDownloadResponseInfo -Response $errorResponse
                                    if ($null -ne $errorResponseInfo.ContentRangeTotalLength -and $localStateOn416.Length -eq $errorResponseInfo.ContentRangeTotalLength) {
                                        if (-not [string]::IsNullOrWhiteSpace($resumeMetadataPath)) {
                                            _RemoveFileIfExists -Path $resumeMetadataPath
                                        }

                                        if ($streamingHashValidationRequested) {
                                            Write-StandardMessage -Message ("[STATUS] Verifying {0} for '{1}'." -f $RequiredStreamingHashType, $OutFile) -Level INF
                                            $actualStreamingHashOn416 = _GetFileHashHex -Path $OutFile -Algorithm $RequiredStreamingHashType
                                            if ($actualStreamingHashOn416 -ne $RequiredStreamingHash) {
                                                try { [System.IO.File]::Delete($OutFile) } catch {}
                                                throw ("Required {0} mismatch for '{1}'. Expected '{2}', actual '{3}'." -f $RequiredStreamingHashType, $OutFile, $RequiredStreamingHash, $actualStreamingHashOn416)
                                            }

                                            Write-StandardMessage -Message ("[OK] Required {0} matched for '{1}'." -f $RequiredStreamingHashType, $OutFile) -Level INF
                                        }

                                        Write-StandardMessage -Message ("[OK] The existing file '{0}' already matches the remote content length ({1} bytes). No download was necessary." -f $OutFile, $localStateOn416.Length) -Level INF
                                        return
                                    }
                                }
                            }
                        }
                        catch {
                            $caughtError = $_
                            $statusCode = _GetHttpStatusCodeFromErrorRecord -ErrorRecord $caughtError
                        }
                    }

                    $wwwAuthenticateValues = _GetWwwAuthenticateValuesFromErrorRecord -ErrorRecord $caughtError
                    $hasWwwAuthenticateChallenge = $wwwAuthenticateValues.Count -gt 0

                    $hasAutoUpgradeTrigger =
                        $autoUseDefaultCredentialsAllowed -and
                        (-not $requestUseDefaultCredentials) -and
                        ($statusCode -eq 401) -and
                        $hasWwwAuthenticateChallenge

                    if ($hasAutoUpgradeTrigger -and -not $autoUseDefaultCredentialsGuardInfoResolved) {
                        $autoUseDefaultCredentialsGuardInfo = _GetAutoUseDefaultCredentialsGuardInfo -TargetUri $Uri
                        $autoUseDefaultCredentialsGuardInfoResolved = $true

                        if ($autoUseDefaultCredentialsGuardInfo.IsIntranetLike) {
                            Write-StandardMessage -Message ("[STATUS] Automatic default-credentials guard passed for '{0}'. Signal(s): {1}" -f $uriDisplay, ($autoUseDefaultCredentialsGuardInfo.Signals -join '; ')) -Level INF
                        }
                        else {
                            $resolvedAddressText = if ($autoUseDefaultCredentialsGuardInfo.ResolvedAddresses.Count -gt 0) {
                                $autoUseDefaultCredentialsGuardInfo.ResolvedAddresses -join ', '
                            }
                            else {
                                'none'
                            }

                            Write-StandardMessage -Message ("[STATUS] Automatic default-credentials guard blocked upgrade for '{0}'. No intranet-like signals were found. Resolved address(es): {1}" -f $uriDisplay, $resolvedAddressText) -Level INF
                        }
                    }

                    $shouldAutoUpgradeToDefaultCredentials =
                        $hasAutoUpgradeTrigger -and
                        $autoUseDefaultCredentialsGuardInfoResolved -and
                        $autoUseDefaultCredentialsGuardInfo.IsIntranetLike

                    if ($shouldAutoUpgradeToDefaultCredentials) {
                        $requestUseDefaultCredentials = $true
                        $autoUpgradedToDefaultCredentials = $true

                        if (-not $useStreamingEngine) {
                            $callParams['UseDefaultCredentials'] = $true
                        }

                        Write-StandardMessage -Message ("[STATUS] Received 401 with WWW-Authenticate challenge for '{0}'. Retrying the current attempt with default credentials. Challenge(s): {1}" -f $uriDisplay, ($wwwAuthenticateValues -join ', ')) -Level WRN
                        continue
                    }

                    $remainingMilliseconds = [int]::MaxValue
                    if ($TotalTimeoutSec -gt 0) {
                        $remainingMilliseconds = [int](($TotalTimeoutSec * 1000) - $retryStopwatch.ElapsedMilliseconds)
                    }

                    $isLastAttempt = $attemptIndex -ge $RetryCount
                    $retryBudgetExpired = ($TotalTimeoutSec -gt 0 -and $remainingMilliseconds -le 0)

                    if ($isLastAttempt -or $retryBudgetExpired) {
                        if ($useStreamingEngine -and $DeletePartialStreamingDownloadOnFailure -and -not [string]::IsNullOrWhiteSpace($OutFile)) {
                            try {
                                if ([System.IO.File]::Exists($OutFile)) {
                                    if (-not $downloadTargetExistedBeforeInvocation) {
                                        [System.IO.File]::Delete($OutFile)
                                        if (-not [string]::IsNullOrWhiteSpace($resumeMetadataPath)) {
                                            _RemoveFileIfExists -Path $resumeMetadataPath
                                        }
                                    }
                                    else {
                                        Write-StandardMessage -Message ("[STATUS] Streaming download failed, but '{0}' existed before this invocation and will be left in place." -f $OutFile) -Level INF
                                    }
                                }
                            }
                            catch {
                                Write-StandardMessage -Message ("[WRN] Failed to delete the partial streaming download '{0}': {1}" -f $OutFile, $_) -Level WRN
                            }
                        }

                        if ($retryBudgetExpired) {
                            Write-StandardMessage -Message ("[ERR] Retry budget expired after {0} ms while processing {1} {2}: {3}" -f $retryStopwatch.ElapsedMilliseconds, $effectiveMethod, $uriDisplay, $caughtError) -Level ERR
                        }
                        else {
                            Write-StandardMessage -Message ("[ERR] Attempt {0} of {1} failed and no retries remain for {2} {3}: {4}" -f $attemptIndex, $RetryCount, $effectiveMethod, $uriDisplay, $caughtError) -Level ERR
                        }

                        return
                    }

                    $sleepMilliseconds = $RetryDelayMilliseconds
                    if ($TotalTimeoutSec -gt 0 -and $sleepMilliseconds -gt $remainingMilliseconds) {
                        $sleepMilliseconds = $remainingMilliseconds
                    }
                    if ($sleepMilliseconds -lt 0) { $sleepMilliseconds = 0 }

                    Write-StandardMessage -Message ("[RETRY] Attempt {0} of {1} failed for {2} {3}: {4}. Retrying in {5} ms." -f $attemptIndex, $RetryCount, $effectiveMethod, $uriDisplay, $caughtError, $sleepMilliseconds) -Level WRN

                    if ($sleepMilliseconds -gt 0) {
                        Start-Sleep -Milliseconds $sleepMilliseconds
                    }

                    break
                }
                finally {
                    if ($useStreamingEngine -and -not [string]::IsNullOrWhiteSpace($downloadLockPath)) {
                        if (_TestDownloadLockIsStale -LockPath $downloadLockPath) {
                            _RemoveFileIfExists -Path $downloadLockPath
                        }
                        else {
                            $lockInfo = _ReadJsonFile -Path $downloadLockPath
                            $removeOwnLock = $false

                            if ($null -ne $lockInfo) {
                                try {
                                    $lockPid = [int]$lockInfo.Pid
                                    $lockStart = [string]$lockInfo.ProcessStartTimeUtc
                                    $myStart = _GetCurrentProcessStartTimeUtcText

                                    if ($lockPid -eq $PID -and $lockStart -eq $myStart) {
                                        $removeOwnLock = $true
                                    }
                                }
                                catch {
                                }
                            }

                            if ($removeOwnLock) {
                                _RemoveFileIfExists -Path $downloadLockPath
                            }
                        }
                    }
                }
            }
        }
    }
    finally {
        if ($skipCertificateCheckEnabled) {
            if ($null -eq $previousCertificateValidationCallback) {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback =
                    [System.Net.Security.RemoteCertificateValidationCallback]$null
            }
            else {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCertificateValidationCallback
            }
        }

        if ($securityProtocolChanged -and $null -ne $previousSecurityProtocol) {
            try {
                [System.Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
                Write-StandardMessage -Message ("[STATUS] Restored the previous process security protocol flags.") -Level INF
            }
            catch {
                Write-StandardMessage -Message ("[WRN] Failed to restore previous security protocol flags: {0}" -f $_) -Level WRN
            }
        }
    }
}

function Get-GitRepoFileMetadata {
    <#
    .SYNOPSIS
        Retrieves commit metadata for files in a Git repository and optionally constructs download URLs.

    .DESCRIPTION
        This function accepts a repository URL, branch name, and an optional download endpoint.
        It performs a partial clone (metadata only) to list files at the HEAD commit, retrieves each
        file's latest commit timestamp and message, and—if specified—generates a direct file
        download URL by injecting the endpoint segment.

    .PARAMETER RepoUrl
        The HTTP(S) URL of the remote Git repository (e.g., "https://huggingface.co/microsoft/phi-4").

    .PARAMETER BranchName
        The branch to inspect (e.g., "main").

    .PARAMETER DownloadEndpoint
        (Optional) The URL path segment to insert before the branch name for download links
        (e.g., 'resolve' or 'raw/refs/heads'). If omitted or empty, DownloadUrl for each file
        will be an empty string.

    .PARAMETER Filter
        (Optional) An array of wildcard patterns. Any file whose path matches *any* of these
        patterns will be **excluded** from the result set.
        Wildcards follow PowerShell’s `-like` semantics; for example:
        `-Filter 'onnx/*','filename*root.json'`

    .EXAMPLE
        # Exclude all files in the 'onnx' directory and any JSON ending in 'root.json'
        $info = Get-GitRepoFileMetadata `
            -RepoUrl "https://huggingface.co/microsoft/phi-4" `
            -BranchName "main" `
            -Filter 'onnx/*','*root.json'

    .OUTPUTS
        PSCustomObject with properties:
        - RepoUrl (string)
        - BranchName (string)
        - DownloadEndpoint (string, optional)
        - Files (hashtable of PSCustomObject with Filename, Timestamp, Comment, DownloadUrl)
    #>
    [CmdletBinding()]
    [alias('ggrfm')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoUrl,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BranchName,

        [Parameter()]
        [string]$DownloadEndpoint,

        [Parameter()]
        [string[]]$Filter
    )

    # Prepare partial clone directory
    $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    try {
        git clone --filter=blob:none --no-checkout -b $BranchName $RepoUrl $tempDir | Out-Null
        Push-Location $tempDir

        # List all files
        $files = git ls-tree -r HEAD --name-only | ForEach-Object { $_.Trim() } | Where-Object { $_ }

        # If a filter was provided, drop any matching path
        if ($PSBoundParameters.ContainsKey('Filter') -and $Filter) {
            $files = $files | Where-Object {
                $path = $_
                # exclude if ANY pattern matches
                -not ($Filter | ForEach-Object { $path -like $_ } | Where-Object { $_ })
            }
        }

        $fileData = @{}

        foreach ($file in $files) {
            # Get last commit date and message for this file
            $commit = git log -1 --pretty=format:"%ad|%s" --date=iso-strict -- $file
            if ($commit) {
                $parts = $commit -split '\|',2
                try { $ts  = [DateTimeOffset]::Parse($parts[0]).UtcDateTime } catch { $ts = $null }
                $msg = if ($parts.Length -gt 1) { $parts[1] } else { '' }
            } else {
                $ts  = $null
                $msg = ''
            }

            # Build download URL if endpoint given
            if ($PSBoundParameters.ContainsKey('DownloadEndpoint') -and $DownloadEndpoint) {
                $endpoint = $DownloadEndpoint.Trim('/')
                $base     = $RepoUrl.TrimEnd('/')
                $url      = "${base}/${endpoint}/${BranchName}/${file}"
            } else {
                $url = ''
            }

            $fileData[$file] = [PSCustomObject]@{
                Filename    = $file
                Timestamp   = $ts
                Comment     = $msg
                DownloadUrl = $url
            }
        }

        # Construct and return the result object
        $result = [ordered]@{
            RepoUrl    = $RepoUrl
            BranchName = $BranchName
            Files      = $fileData
        }
        if ($PSBoundParameters.ContainsKey('DownloadEndpoint') -and $DownloadEndpoint) {
            $result.DownloadEndpoint = $DownloadEndpoint
        }

        return [PSCustomObject]$result
    }
    catch {
        Write-Error "Error retrieving metadata: $_"
    }
    finally {
        Pop-Location
        Remove-Item -Path $tempDir -Recurse -Force
    }
}

function Sync-GitRepoFiles {
    <#
    .SYNOPSIS
        Mirrors files from a GitRepoFileMetadata object to a local folder based on DownloadUrl, showing progress.

    .DESCRIPTION
        Takes metadata from Get-GitRepoFileMetadata and a destination root. It first removes any files
        in the local target that are not present in the metadata (cleanup), then classifies files as:
        "matched" (timestamps equal), "missing" (not present) or "stale" (timestamp mismatch), logs a summary,
        processes downloads in order (missing first, then stale), and finally reports completion.

    .PARAMETER Metadata
        PSCustomObject returned by Get-GitRepoFileMetadata.

    .PARAMETER DestinationRoot
        The root directory under which to sync files (e.g., "C:\Downloads").

    .OUTPUTS
        None. Writes progress and summary to the host.
    #>
    [CmdletBinding()]
    [alias('sgrf')]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][PSCustomObject]$Metadata,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DestinationRoot
    )

    Write-Host "Starting sync for: $($Metadata.RepoUrl)"
    $uri = [Uri]$Metadata.RepoUrl
    $repoPath = $uri.AbsolutePath.Trim('/')
    $targetDir = Join-Path $DestinationRoot $repoPath
    if (-not (Test-Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }
    Write-Host "Destination: $targetDir`n"

    # Initial cleanup: remove any files not in metadata
    Write-Host "Performing initial cleanup of extraneous files..."
    $expectedPaths = $Metadata.Files.Keys | ForEach-Object { Join-Path $targetDir $_ }
    Get-ChildItem -Path $targetDir -Recurse -File | ForEach-Object {
        if ($expectedPaths -notcontains $_.FullName) {
            Write-Host "Removing extra file: $($_.FullName)"
            Remove-Item -Path $_.FullName -Force
        }
    }
    Write-Host "Initial cleanup complete.`n"

    # Classification phase
    $missing = New-Object System.Collections.Generic.List[string]
    $stale   = New-Object System.Collections.Generic.List[string]
    $matched = New-Object System.Collections.Generic.List[string]

    foreach ($kv in $Metadata.Files.GetEnumerator()) {
        $fileName = $kv.Key; $info = $kv.Value
        if ([string]::IsNullOrEmpty($info.DownloadUrl)) {
            Write-Host "Skipping (no URL): $fileName"
            continue
        }
        $localPath = Join-Path $targetDir $fileName
        if (-not (Test-Path $localPath)) {
            $missing.Add($fileName)
        } else {
            $localTime = (Get-Item $localPath).LastWriteTimeUtc
            if ($localTime -eq $info.Timestamp) {
                $matched.Add($fileName)
            } else {
                $stale.Add($fileName)
            }
        }
    }

    # Summary
    Write-Host "Summary: $($matched.Count) up-to-date, $($missing.Count) missing, $($stale.Count) stale files.`n"

    # Download missing files first
    foreach ($fileName in $missing) {
        $info = $Metadata.Files[$fileName]
        $localPath = Join-Path $targetDir $fileName
        $destDir = Split-Path $localPath -Parent
        if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
        Write-Host "File not present, will download: $fileName"
        Invoke-WebRequestEx -Uri $info.DownloadUrl -OutFile $localPath -UseBasicParsing
        [System.IO.File]::SetLastWriteTimeUtc($localPath, $info.Timestamp)
        Write-Host "Downloaded and timestamp set: $fileName`n"
    }

    # Then re-download stale files
    foreach ($fileName in $stale) {
        $info = $Metadata.Files[$fileName]
        $localPath = Join-Path $targetDir $fileName
        Write-Host "Out-of-date (timestamp mismatch), will re-download: $fileName"
        Invoke-WebRequestEx -Uri $info.DownloadUrl -OutFile $localPath -UseBasicParsing
        [System.IO.File]::SetLastWriteTimeUtc($localPath, $info.Timestamp)
        Write-Host "Downloaded and timestamp set: $fileName`n"
    }

    # Finally, report matched files
    foreach ($fileName in $matched) {
        Write-Host "Timestamps match, skipping: $fileName"
    }

    Write-Host "Sync complete for: $($Metadata.RepoUrl)"
}

function Mirror-GitRepoWithDownloadContent {
    <#
    .SYNOPSIS
        Retrieves metadata and mirrors a Git repository with download content in one step.

    .DESCRIPTION
        Combines Get-GitRepoFileMetadata and Sync-GitRepoFiles into a single command.
        Accepts an optional -Filter parameter to exclude files by wildcard patterns.

    .PARAMETER RepoUrl
        The URL of the remote Git repository.

    .PARAMETER BranchName
        The branch to sync (e.g., "main").

    .PARAMETER DownloadEndpoint
        The endpoint for download URLs (e.g., 'resolve').

    .PARAMETER DestinationRoot
        The local root folder to mirror content into (e.g., "C:\temp\test").

    .PARAMETER Filter
        (Optional) An array of wildcard patterns to exclude from metadata retrieval.
        Forwarded to Get-GitRepoFileMetadata’s -Filter parameter.

    .EXAMPLE
        # Mirror everything except 'onnx/*' and '*root.json'
        Mirror-GitRepoWithDownloadContent `
          -RepoUrl "https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct" `
          -BranchName "main" `
          -DownloadEndpoint "resolve" `
          -DestinationRoot "C:\temp\test" `
          -Filter 'onnx/*','runs/*'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
    [CmdletBinding()]
    [alias('mirror-grwdc')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RepoUrl,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BranchName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DownloadEndpoint,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DestinationRoot,
        [Parameter()][string[]]$Filter
    )

    # Build parameter splat for metadata retrieval
    $metaParams = @{
        RepoUrl        = $RepoUrl
        BranchName     = $BranchName
        DownloadEndpoint = $DownloadEndpoint
    }
    if ($PSBoundParameters.ContainsKey('Filter')) {
        $metaParams.Filter = $Filter
    }

    # Retrieve metadata (with optional filtering) and sync files
    $metadata = Get-GitRepoFileMetadata @metaParams
    Sync-GitRepoFiles -Metadata $metadata -DestinationRoot $DestinationRoot
}


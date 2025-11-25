function Invoke-WebRequestEx {
<#
.SYNOPSIS
    Quickly download a URI to a file by streaming in large buffers via .NET, avoiding PowerShell's 2GB memory limit.

.DESCRIPTION
    Invoke-WebRequestEx is a streaming-focused alternative to Invoke-WebRequest for large downloads on
    Windows PowerShell 5/5.1 and PowerShell 7+ (Windows, macOS, Linux).

    It uses the .NET WebRequest API and streams the HTTP response directly to disk in fixed-size chunks,
    avoiding large in-memory buffers. This makes it suitable for multi-gigabyte downloads that would
    otherwise hit PowerShell's historical 2GB memory limit on older hosts.

    The function performs up to three download attempts with a 5 second wait between failures.
    Progress is reported via low-noise log messages: approximately every 10 percent for known content
    length, or every 50 MB when the total size is unknown.

.PARAMETER Uri
    The HTTP or HTTPS URL to download.

.PARAMETER OutFile
    The full path where the content will be saved. The file is overwritten if it already exists.

.PARAMETER Method
    HTTP method to use (GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH). Defaults to GET.

.PARAMETER Headers
    Hashtable of HTTP headers to include in the request.

.PARAMETER TimeoutSec
    Timeout for the request in seconds. If zero or omitted, default .NET timeouts are used.

.PARAMETER Credential
    PSCredential for authenticated requests. Uses .NET WebRequest credentials handling.

.PARAMETER UseBasicParsing
    Switch reserved for compatibility with older Invoke-WebRequest usage. Parsed but not used.

.PARAMETER Body
    Byte array to send as the request body for POST/PUT/PATCH requests.

.PARAMETER Force
    Reserved switch for future use. Has no effect in the current implementation.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://example.com/large.zip' -OutFile 'C:\Temp\large.zip'

    Downloads a large ZIP file and streams it directly to disk on Windows PowerShell 5.1 or PowerShell 7+.

.EXAMPLE
    Invoke-WebRequestEx -Uri 'https://example.com/api/data' -OutFile './data.bin' -Headers @{
        'Authorization' = 'Bearer 123'
        'Accept'        = 'application/octet-stream'
    }

    Downloads binary API data with custom headers to a file in the current directory on any supported platform.

.EXAMPLE
    $payload = [System.Text.Encoding]::UTF8.GetBytes('{ "query": "value" }')
    Invoke-WebRequestEx -Uri 'https://example.com/api/export' -Method 'POST' -Body $payload -OutFile './export.json'

    Sends a JSON payload as a POST request and streams the response content to disk.

.EXAMPLE
    $cred = Get-Credential
    Invoke-WebRequestEx -Uri 'https://intranet.example.com/file.iso' -OutFile 'C:\Temp\file.iso' -TimeoutSec 600 -Credential $cred

    Downloads a large ISO from an authenticated intranet endpoint with an explicit timeout.

.NOTES
    - Compatible with Windows PowerShell 5/5.1 and PowerShell 7+ on Windows, macOS, and Linux.
    - Intended for HTTP and HTTPS URIs.
    - The target file is always overwritten; repeated runs converge to the same on-disk result if the remote resource is unchanged.
    - Maximum of 3 attempts, 5 seconds delay between attempts on failure.
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [string] $Uri,

        [Parameter(Mandatory=$true, Position=1)]
        [string] $OutFile,

        [Parameter()]
        [ValidateSet('GET','POST','PUT','DELETE','HEAD','OPTIONS','PATCH')]
        [string] $Method = 'GET',

        [Parameter()]
        [hashtable] $Headers,

        [Parameter()]
        [int] $TimeoutSec = 0,

        [Parameter()]
        [System.Management.Automation.PSCredential] $Credential,

        [Parameter()]
        [switch] $UseBasicParsing,

        [Parameter()]
        [byte[]] $Body,

        [Parameter()]
        [switch] $Force
    )

    function local:_Write-StandardMessage {
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
        $ts=[DateTime]::UtcNow.ToString('yy-MM-dd HH:mm:ss.ff')
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
        $suffix="] [$file] $Message"
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

    # Core single-attempt download with limited progress
    function local:_Invoke-WebRequestExSingleAttempt {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory=$true)][string] $AttemptUri,
            [Parameter(Mandatory=$true)][string] $AttemptOutFile,
            [Parameter(Mandatory=$true)][string] $AttemptMethod,
            [Parameter()][hashtable] $AttemptHeaders,
            [Parameter()][int] $AttemptTimeoutSec,
            [Parameter()][System.Management.Automation.PSCredential] $AttemptCredential,
            [Parameter()][byte[]] $AttemptBody
        )

        $request = [System.Net.WebRequest]::Create($AttemptUri)
        if ($null -eq $request) {
            _Write-StandardMessage -Message ("[ERR] Failed to create WebRequest for '{0}'." -f $AttemptUri) -Level ERR
            throw ("Failed to create WebRequest for '{0}'." -f $AttemptUri)
        }

        $request.Method = $AttemptMethod

        if ($AttemptTimeoutSec -gt 0) {
            $request.Timeout = $AttemptTimeoutSec * 1000
            try {
                $request.ReadWriteTimeout = $AttemptTimeoutSec * 1000
            }
            catch {
                _Write-StandardMessage -Message ("[WRN] ReadWriteTimeout not supported for '{0}'. Using default read/write timeout." -f $AttemptUri) -Level WRN
            }
        }

        if ($AttemptCredential) {
            $request.Credentials = $AttemptCredential
        }

        if ($AttemptHeaders) {
            foreach ($headerKey in $AttemptHeaders.Keys) {
                $headerValue = $AttemptHeaders[$headerKey]
                $request.Headers.Add($headerKey, $headerValue)
            }
        }

        if ($AttemptBody -and $AttemptMethod -in @('POST', 'PUT', 'PATCH')) {
            $request.ContentLength = $AttemptBody.Length
            $requestStream = $null
            try {
                $requestStream = $request.GetRequestStream()
                $requestStream.Write($AttemptBody, 0, $AttemptBody.Length)
            }
            finally {
                if ($null -ne $requestStream) {
                    $requestStream.Dispose()
                }
            }
        }

        $response = $null
        $responseStream = $null
        $fileStream = $null

        try {
            _Write-StandardMessage -Message ("[STATUS] Sending {0} request to '{1}'." -f $AttemptMethod, $AttemptUri) -Level INF

            $response = $request.GetResponse()
            $responseStream = $response.GetResponseStream()

            if ($null -eq $responseStream) {
                _Write-StandardMessage -Message ("[ERR] Response stream was null for '{0}'." -f $AttemptUri) -Level ERR
                throw ("The remote server returned an empty response stream for '{0}'." -f $AttemptUri)
            }

            $fileStream = [System.IO.File]::Open($AttemptOutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

            $bufferSize = 4MB
            $buffer = New-Object byte[] $bufferSize
            $totalBytes = 0L
            $contentLength = -1L

            $contentLengthProperty = $response.PSObject.Properties['ContentLength']
            if ($contentLengthProperty -and $null -ne $contentLengthProperty.Value) {
                $contentLength = [long]$contentLengthProperty.Value
            }

            $progressThresholdBytes = 0L
            if ($contentLength -gt 0) {
                $progressThresholdBytes = [long][Math]::Floor($contentLength / 10)
                if ($progressThresholdBytes -lt 1048576) {
                    $progressThresholdBytes = 1048576
                }
            }
            else {
                $progressThresholdBytes = 52428800
            }

            if ($progressThresholdBytes -le 0) {
                $progressThresholdBytes = 1048576
            }

            $nextProgressBytes = $progressThresholdBytes

            while ($true) {
                $bytesRead = $responseStream.Read($buffer, 0, $bufferSize)
                if ($bytesRead -le 0) {
                    break
                }

                $fileStream.Write($buffer, 0, $bytesRead)
                $totalBytes += [long]$bytesRead

                if ($totalBytes -ge $nextProgressBytes) {
                    if ($contentLength -gt 0) {
                        $percent = [Math]::Round(($totalBytes * 100.0) / $contentLength, 1)
                        _Write-StandardMessage -Message ("[PROGRESS] Downloaded {0} of {1} bytes ({2} percent) for '{3}'." -f $totalBytes, $contentLength, $percent, $AttemptUri) -Level INF
                    }
                    else {
                        $megaBytes = [Math]::Round($totalBytes / 1048576.0, 1)
                        _Write-StandardMessage -Message ("[PROGRESS] Downloaded approximately {0} MB from '{1}'." -f $megaBytes, $AttemptUri) -Level INF
                    }

                    $nextProgressBytes += $progressThresholdBytes
                }
            }

            _Write-StandardMessage -Message ("[OK] Downloaded {0} bytes from '{1}' to '{2}'." -f $totalBytes, $AttemptUri, $AttemptOutFile) -Level INF
        }
        catch {
            _Write-StandardMessage -Message ("[WRN] Single attempt failed for '{0}' to '{1}': {2}" -f $AttemptUri, $AttemptOutFile, $_.Exception.Message) -Level WRN
            throw
        }
        finally {
            if ($null -ne $responseStream) {
                $responseStream.Dispose()
            }

            if ($null -ne $fileStream) {
                $fileStream.Dispose()
            }

            if ($null -ne $response) {
                $response.Close()
            }
        }
    }

    # Title-style message, no tag as per your spec
    _Write-StandardMessage -Message "--- Invoke-WebRequestEx streaming download operation ---" -Level INF

    # Validate the output directory once, prior to attempts
    $outDirectory = [System.IO.Path]::GetDirectoryName($OutFile)
    if ($null -ne $outDirectory -and $outDirectory.Length -gt 0) {
        if (-not [System.IO.Directory]::Exists($outDirectory)) {
            _Write-StandardMessage -Message ("[ERR] Target directory '{0}' does not exist." -f $outDirectory) -Level ERR
            throw ("Target directory '{0}' does not exist. Create it before calling Invoke-WebRequestEx." -f $outDirectory)
        }
    }

    $maxAttempts = 3
    $attemptIndex = 0
    $lastError = $null

    while ($attemptIndex -lt $maxAttempts) {
        $attemptIndex += 1
        try {
            _Write-StandardMessage -Message ("[STATUS] Starting attempt {0} of {1} for '{2}'." -f $attemptIndex, $maxAttempts, $Uri) -Level INF

            _Invoke-WebRequestExSingleAttempt -AttemptUri $Uri -AttemptOutFile $OutFile -AttemptMethod $Method -AttemptHeaders $Headers -AttemptTimeoutSec $TimeoutSec -AttemptCredential $Credential -AttemptBody $Body

            _Write-StandardMessage -Message ("[OK] Download completed successfully on attempt {0} for '{1}'." -f $attemptIndex, $Uri) -Level INF
            $lastError = $null
            break
        }
        catch {
            $lastError = $_
            if ($attemptIndex -lt $maxAttempts) {
                _Write-StandardMessage -Message ("[RETRY] Attempt {0} of {1} failed for '{2}' to '{3}': {4}. Retrying in 5 seconds." -f $attemptIndex, $maxAttempts, $Uri, $OutFile, $lastError.Exception.Message) -Level WRN
                Start-Sleep -Seconds 5
            }
            else {
                _Write-StandardMessage -Message ("[ERR] All {0} attempts failed for '{1}' to '{2}'." -f $maxAttempts, $Uri, $OutFile) -Level ERR
                throw ("Download failed for '{0}' to '{1}' after {2} attempts: {3}" -f $Uri, $OutFile, $maxAttempts, $lastError.Exception.Message)
            }
        }
    }
}

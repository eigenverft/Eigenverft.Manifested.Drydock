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

            $fileStream = [System.IO.File]::Open(
                $AttemptOutFile,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )

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
                # Unknown length: log roughly every 50 MB
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
                        _Write-StandardMessage -Message (
                            "[PROGRESS] Downloaded {0} of {1} bytes ({2} percent) for '{3}'." -f $totalBytes, $contentLength, $percent, $AttemptUri
                        ) -Level INF
                    }
                    else {
                        $megaBytes = [Math]::Round($totalBytes / 1048576.0, 1)
                        _Write-StandardMessage -Message (
                            "[PROGRESS] Downloaded approximately {0} MB from '{1}'." -f $megaBytes, $AttemptUri
                        ) -Level INF
                    }

                    $nextProgressBytes += $progressThresholdBytes
                }
            }

            # Final progress line:
            # - If total size is known: always log a clean 100 percent.
            # - If total size is unknown: log a final "download complete" with total MB.
            if ($totalBytes -gt 0) {
                if ($contentLength -gt 0) {
                    $finalDownloaded = $totalBytes
                    if ($finalDownloaded -gt $contentLength) {
                        $finalDownloaded = $contentLength
                    }

                    $finalPercent = 100
                    _Write-StandardMessage -Message (
                        "[PROGRESS] Downloaded {0} of {1} bytes ({2} percent) for '{3}'." -f $finalDownloaded, $contentLength, $finalPercent, $AttemptUri
                    ) -Level INF
                }
                else {
                    $finalMb = [Math]::Round($totalBytes / 1048576.0, 1)
                    _Write-StandardMessage -Message (
                        "[PROGRESS] Download complete, total {0} MB from '{1}'." -f $finalMb, $AttemptUri
                    ) -Level INF
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

    # --- TLS: Ensure TLS 1.2 is enabled (additive; do not clear other explicit flags) ---
    # Note: In PS 5.1 / .NET Framework this affects WebRequest/ServicePoint-based traffic in this process.
    try {
        $tls12 = [Net.SecurityProtocolType]::Tls12

        # Only add TLS 1.2 if it isn't already present.
        if (([Net.ServicePointManager]::SecurityProtocol -band $tls12) -ne $tls12) {
            [Net.ServicePointManager]::SecurityProtocol = `
                ([Net.ServicePointManager]::SecurityProtocol -bor $tls12)
        }
    }
    catch {
        _Write-StandardMessage -Message ("[ERR] TLS set failed: {0}" -f $_.Exception.Message) -Level ERR
    }

    # --- Proxy: Ensure system proxy is used; ensure default credentials are applied ---
    # Note: This sets process-wide defaults for WebRequest-based networking.
    try {
        # Always refresh the default proxy from the system configuration (WPAD/PAC/WinINET).
        [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebRequest]::GetSystemWebProxy()

        $proxy = [System.Net.WebRequest]::DefaultWebProxy
        if ($proxy) {
            # Use integrated (domain) credentials for corporate proxy authentication.
            $proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        }
    }
    catch {
        _Write-StandardMessage -Message ("[ERR] Proxy set failed: {0}" -f $_.Exception.Message) -Level ERR
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


#Mirror-GitRepoWithDownloadContent -RepoUrl 'https://huggingface.co/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B' -BranchName 'main' -DownloadEndpoint 'resolve' -DestinationRoot 'C:\Artificial_Intelligence' -Filter 'onnx/*','runs/*','metal/*','original/*'
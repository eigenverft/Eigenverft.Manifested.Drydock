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

function Initialize-ProxyAccessProfile {
<#
.SYNOPSIS
Resolves a usable outbound proxy access profile on Windows, persists the
result to a CliXml profile file, and stores ready-to-use values in global
variables.

.DESCRIPTION
Resolution order:
1. Direct access
2. Environment proxy from process environment variables
3. Local relay proxy on loopback
4. System proxy with default credentials
5. Manual proxy

Behavior:
- A second call exits early unless -ForceRefresh is used.
- If no in-session globals exist yet, the function first tries to load the stored
  profile file, validates that persisted profile with a live probe, and only then
  rebuilds the global variables from it.
- Global variables are still populated for easy re-use inside the current shell.
- If manual proxy entry would be required in a non-interactive session, the function throws.
- TLS 1.2 is ensured for proxy validation and discovery probes.
- Certificate validation is skipped by default for proxy validation and discovery
  probes. Use -EnforceCertificateCheck to require normal server certificate validation.

This helper is primarily intended for Windows PowerShell 5.1 and PowerShell
7+ on Windows in corporate environments where direct access is not guaranteed.
#>
    [CmdletBinding()]
    param(
        [uri]$TestUri = 'https://www.powershellgallery.com/api/v2/',

        [ValidateRange(1,300)]
        [int]$TimeoutSec = 8,

        [string]$DefaultManualProxy = 'http://test.corp.com:8080',

        [string]$GlobalPrefix = 'ProxyParams',

        [string]$ProxyProfilePath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\ProxyAccessProfile\ProxyAccessProfile.clixml'),

        [switch]$SkipManualProxyPrompt,

        [switch]$SkipSessionPreparation,

        [switch]$SkipCertificateCheck,

        [switch]$EnforceCertificateCheck,

        [switch]$ForceRefresh
    )

    $isWindowsEnv = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if (-not $isWindowsEnv) {
        throw "Initialize-ProxyAccessProfile is intended for Windows PowerShell 5.1 and PowerShell 7+ on Windows. Current version: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
    }

    $nativeInvokeWebRequestCommand = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
    $nativeSupportsNoProxy =
        ($null -ne $nativeInvokeWebRequestCommand) -and
        $nativeInvokeWebRequestCommand.Parameters.ContainsKey('NoProxy')

    $initialized = Get-Variable -Scope Global -Name ($GlobalPrefix + 'Initialized') -ErrorAction SilentlyContinue
    if (-not $ForceRefresh -and $initialized -and $initialized.Value) {
        return
    }

    $explicitSkipCertificateCheckSupplied = $PSBoundParameters.ContainsKey('SkipCertificateCheck')
    $explicitEnforceCertificateCheckSupplied = $PSBoundParameters.ContainsKey('EnforceCertificateCheck')

    $effectiveSkipCertificateCheck = if ($explicitSkipCertificateCheckSupplied) {
        [bool]$SkipCertificateCheck
    }
    elseif ($explicitEnforceCertificateCheckSupplied) {
        -not [bool]$EnforceCertificateCheck
    }
    else {
        $true
    }

    function Set-ProxyGlobals {
        param(
            [ValidateSet('Direct','EnvironmentProxy','LocalRelayProxy','SystemProxyDefaultCredentials','ManualProxy','NoResolvedProxyProfile')]
            [string]$Mode,

            [hashtable]$InstallPackageProvider = @{},

            [hashtable]$InstallModule = @{},

            [hashtable]$InvokeWebRequest = @{},

            [scriptblock]$PrepareSession = $null,

            [uri]$Proxy = $null,

            [pscredential]$ProxyCredential = $null,

            [bool]$UseDefaultProxyCredentials = $false,

            [bool]$SessionPrepared = $false,

            [string[]]$Diagnostics = @(),

            [string]$ProfileSource = $null,

            [datetime]$LastRefresh = [datetime]::MinValue
        )

        Set-Variable -Scope Global -Name ($GlobalPrefix + 'InstallPackageProvider') -Value $InstallPackageProvider -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'InstallModule') -Value $InstallModule -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'InvokeWebRequest') -Value $InvokeWebRequest -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'PrepareSession') -Value $PrepareSession -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'Mode') -Value $Mode -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'TestUri') -Value $TestUri -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'Proxy') -Value $Proxy -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'ProxyCredential') -Value $ProxyCredential -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'UseDefaultProxyCredentials') -Value $UseDefaultProxyCredentials -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'SessionPrepared') -Value $SessionPrepared -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'Diagnostics') -Value $Diagnostics -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'ProfileSource') -Value $ProfileSource -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'ProfilePath') -Value $ProxyProfilePath -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'Initialized') -Value $true -Force

        if ($LastRefresh -eq [datetime]::MinValue) {
            Set-Variable -Scope Global -Name ($GlobalPrefix + 'LastRefresh') -Value (Get-Date) -Force
        }
        else {
            Set-Variable -Scope Global -Name ($GlobalPrefix + 'LastRefresh') -Value $LastRefresh -Force
        }
    }

    function Reset-ProxyGlobals {
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'InstallPackageProvider') -Value @{} -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'InstallModule') -Value @{} -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'InvokeWebRequest') -Value @{} -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'PrepareSession') -Value $null -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'Mode') -Value $null -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'TestUri') -Value $null -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'Proxy') -Value $null -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'ProxyCredential') -Value $null -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'UseDefaultProxyCredentials') -Value $false -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'SessionPrepared') -Value $false -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'Diagnostics') -Value @() -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'ProfileSource') -Value $null -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'ProfilePath') -Value $ProxyProfilePath -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'Initialized') -Value $false -Force
        Set-Variable -Scope Global -Name ($GlobalPrefix + 'LastRefresh') -Value $null -Force
    }

    function Ensure-ProfileDirectory {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProfilePath
        )

        $directory = [System.IO.Path]::GetDirectoryName($ProfilePath)
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not [System.IO.Directory]::Exists($directory)) {
            [void][System.IO.Directory]::CreateDirectory($directory)
        }
    }

    function Remove-PersistedProfile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProfilePath
        )

        if (Test-Path -LiteralPath $ProfilePath) {
            Remove-Item -LiteralPath $ProfilePath -Force -ErrorAction SilentlyContinue
        }
    }

    function Save-PersistedProfile {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$StoredProfile,

            [Parameter(Mandatory = $true)]
            [string]$ProfilePath
        )

        try {
            Ensure-ProfileDirectory -ProfilePath $ProfilePath
            Export-Clixml -InputObject $StoredProfile -LiteralPath $ProfilePath -Force -ErrorAction Stop

            if (-not (Test-Path -LiteralPath $ProfilePath)) {
                throw "The profile file could not be verified after export."
            }

            return $null
        }
        catch {
            return $_.Exception.Message
        }
    }

    function Load-PersistedProfile {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProfilePath
        )

        if (-not (Test-Path -LiteralPath $ProfilePath)) {
            return $null
        }

        try {
            $storedProfile = Import-Clixml -LiteralPath $ProfilePath -ErrorAction Stop
            if ($null -eq $storedProfile) {
                return $null
            }

            return $storedProfile
        }
        catch {
            Remove-PersistedProfile -ProfilePath $ProfilePath
            return $null
        }
    }

    function New-StoredProfile {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('Direct','EnvironmentProxy','LocalRelayProxy','SystemProxyDefaultCredentials','ManualProxy','NoResolvedProxyProfile')]
            [string]$Mode,

            [Parameter(Mandatory = $true)]
            [uri]$DetectedTestUri,

            [uri]$ProxyUri,

            [pscredential]$ProxyCredential,

            [bool]$UseDefaultProxyCredentials = $false,

            [string[]]$Diagnostics = @()
        )

        [pscustomobject]@{
            Version                    = 1
            Mode                       = $Mode
            TestUri                    = [string]$DetectedTestUri
            ProxyUri                   = if ($null -ne $ProxyUri) { [string]$ProxyUri } else { $null }
            ProxyCredential            = $ProxyCredential
            UseDefaultProxyCredentials = $UseDefaultProxyCredentials
            LastRefreshUtc             = [DateTime]::UtcNow.ToString('o')
            Diagnostics                = @($Diagnostics)
        }
    }

    function Apply-StoredProfileToGlobals {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$StoredProfile,

            [Parameter(Mandatory = $true)]
            [string]$ProfileSource
        )

        $mode = [string]$StoredProfile.Mode
        $proxy = if ($StoredProfile.ProxyUri) { [uri][string]$StoredProfile.ProxyUri } else { $null }
        $proxyCredential = $null
        $useDefaultProxyCredentials = [bool]$StoredProfile.UseDefaultProxyCredentials
        $prepareSession = $null
        $sessionPrepared = $false

        if ($StoredProfile.ProxyCredential -is [System.Management.Automation.PSCredential]) {
            $proxyCredential = $StoredProfile.ProxyCredential
        }

        $installPackageProvider = @{}
        $installModule = @{}
        $invokeWebRequest = @{}

        switch ($mode) {
            'ManualProxy' {
                if ($null -ne $proxy -and $null -ne $proxyCredential) {
                    $installPackageProvider = @{
                        Proxy           = $proxy
                        ProxyCredential = $proxyCredential
                    }

                    $installModule = @{
                        Proxy           = $proxy
                        ProxyCredential = $proxyCredential
                    }

                    $invokeWebRequest = @{
                        Proxy           = $proxy
                        ProxyCredential = $proxyCredential
                    }

                    $capturedProxy = $proxy
                    $capturedCredential = $proxyCredential

                    $prepareSession = {
                        $webProxy = New-Object System.Net.WebProxy($capturedProxy.AbsoluteUri, $true)
                        $webProxy.Credentials = $capturedCredential.GetNetworkCredential()
                        [System.Net.WebRequest]::DefaultWebProxy = $webProxy
                    }.GetNewClosure()
                }
            }

            'EnvironmentProxy' {
                if ($null -ne $proxy) {
                    if ($useDefaultProxyCredentials -and $null -eq $proxyCredential) {
                        # Package cmdlets do not expose ProxyUseDefaultCredentials,
                        # so session preparation is the compatibility path here.
                        $invokeWebRequest = @{
                            Proxy = $proxy
                            ProxyUseDefaultCredentials = $true
                        }

                        $capturedProxy = $proxy

                        $prepareSession = {
                            $webProxy = New-Object System.Net.WebProxy($capturedProxy.AbsoluteUri, $true)
                            $webProxy.UseDefaultCredentials = $true
                            [System.Net.WebRequest]::DefaultWebProxy = $webProxy
                        }.GetNewClosure()
                    }
                    else {
                        $installPackageProvider = @{
                            Proxy = $proxy
                        }

                        $installModule = @{
                            Proxy = $proxy
                        }

                        $invokeWebRequest = @{
                            Proxy = $proxy
                        }

                        if ($null -ne $proxyCredential) {
                            $installPackageProvider['ProxyCredential'] = $proxyCredential
                            $installModule['ProxyCredential'] = $proxyCredential
                            $invokeWebRequest['ProxyCredential'] = $proxyCredential

                            $capturedProxy = $proxy
                            $capturedCredential = $proxyCredential

                            $prepareSession = {
                                $webProxy = New-Object System.Net.WebProxy($capturedProxy.AbsoluteUri, $true)
                                $webProxy.Credentials = $capturedCredential.GetNetworkCredential()
                                [System.Net.WebRequest]::DefaultWebProxy = $webProxy
                            }.GetNewClosure()
                        }
                        else {
                            $capturedProxy = $proxy

                            $prepareSession = {
                                [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($capturedProxy.AbsoluteUri, $true)
                            }.GetNewClosure()
                        }
                    }
                }
            }

            'LocalRelayProxy' {
                if ($null -ne $proxy) {
                    $installPackageProvider = @{
                        Proxy = $proxy
                    }

                    $installModule = @{
                        Proxy = $proxy
                    }

                    $invokeWebRequest = @{
                        Proxy = $proxy
                    }

                    $capturedProxy = $proxy

                    $prepareSession = {
                        [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($capturedProxy.AbsoluteUri, $true)
                    }.GetNewClosure()
                }
            }

            'SystemProxyDefaultCredentials' {
                if ($null -ne $proxy) {
                    # Package cmdlets do not expose ProxyUseDefaultCredentials,
                    # so session preparation is the compatibility path here.
                    $invokeWebRequest = @{
                        Proxy                      = $proxy
                        ProxyUseDefaultCredentials = $true
                    }

                    $prepareSession = {
                        [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebRequest]::GetSystemWebProxy()
                        [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                    }.GetNewClosure()
                }
            }

            'Direct' {
                if ($nativeSupportsNoProxy) {
                    $invokeWebRequest = @{
                        NoProxy = $true
                    }
                }

                $prepareSession = {
                    [System.Net.WebRequest]::DefaultWebProxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
                }.GetNewClosure()
            }

            'NoResolvedProxyProfile' {
            }
        }

        if (-not $SkipSessionPreparation -and $null -ne $prepareSession) {
            & $prepareSession
            $sessionPrepared = $true
        }

        $lastRefresh = Get-Date
        if ($StoredProfile.LastRefreshUtc) {
            try {
                $lastRefresh = [datetime][string]$StoredProfile.LastRefreshUtc
            }
            catch {
            }
        }

        Set-ProxyGlobals `
            -Mode $mode `
            -InstallPackageProvider $installPackageProvider `
            -InstallModule $installModule `
            -InvokeWebRequest $invokeWebRequest `
            -PrepareSession $prepareSession `
            -Proxy $proxy `
            -ProxyCredential $proxyCredential `
            -UseDefaultProxyCredentials $useDefaultProxyCredentials `
            -SessionPrepared $sessionPrepared `
            -Diagnostics @($StoredProfile.Diagnostics) `
            -ProfileSource $ProfileSource `
            -LastRefresh $lastRefresh
    }

    function Test-Access {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$Uri,

            [Parameter(Mandatory = $true)]
            [int]$TimeoutSec,

            [Parameter(Mandatory = $true)]
            [System.Net.IWebProxy]$Proxy
        )

        $response = $null
        try {
            $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
            $request.Method = 'GET'
            $request.Timeout = $TimeoutSec * 1000
            $request.ReadWriteTimeout = $TimeoutSec * 1000
            $request.AllowAutoRedirect = $true
            $request.UserAgent = 'PowerShell Initialize-ProxyAccessProfile'
            # The caller controls whether this is a true direct test,
            # a loopback relay test, a system-proxy test, or a manual-proxy test.
            $request.Proxy = $Proxy

            $response = [System.Net.HttpWebResponse]$request.GetResponse()

            [pscustomobject]@{
                Success      = $true
                StatusCode   = [int]$response.StatusCode
                ErrorMessage = $null
            }
        }
        catch [System.Net.WebException] {
            $response = $null

            try {
                if ($_.Exception.Response -is [System.Net.HttpWebResponse]) {
                    $response = [System.Net.HttpWebResponse]$_.Exception.Response
                }
            }
            catch {
                $response = $null
            }

            if ($null -ne $response) {
                $statusCode = [int]$response.StatusCode
                $isProxyAuthenticationRequired =
                    $statusCode -eq [int][System.Net.HttpStatusCode]::ProxyAuthenticationRequired

                [pscustomobject]@{
                    Success      = -not $isProxyAuthenticationRequired
                    StatusCode   = $statusCode
                    ErrorMessage = if ($isProxyAuthenticationRequired) { $_.Exception.Message } else { $null }
                }
                return
            }

            [pscustomobject]@{
                Success      = $false
                StatusCode   = $null
                ErrorMessage = $_.Exception.Message
            }
        }
        catch {
            [pscustomobject]@{
                Success      = $false
                StatusCode   = $null
                ErrorMessage = $_.Exception.Message
            }
        }
        finally {
            if ($response) {
                $response.Close()
            }
        }
    }

    function Get-EnvironmentVariableSetting {
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$Names
        )

        foreach ($name in $Names) {
            $value = [System.Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                return [pscustomobject]@{
                    Name = $name
                    Value = [string]$value
                }
            }
        }

        return $null
    }

    function Get-NoProxyEntries {
        param(
            [string]$NoProxyValue
        )

        if ([string]::IsNullOrWhiteSpace($NoProxyValue)) {
            return @()
        }

        $entries = New-Object System.Collections.Generic.List[string]

        foreach ($rawEntry in ($NoProxyValue -split ',')) {
            $entry = [string]$rawEntry
            if (-not [string]::IsNullOrWhiteSpace($entry)) {
                [void]$entries.Add($entry.Trim())
            }
        }

        return @($entries.ToArray())
    }

    function Test-NoProxyEntryMatchesTarget {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Entry,

            [Parameter(Mandatory = $true)]
            [uri]$TargetUri
        )

        $entryText = [string]$Entry
        if ([string]::IsNullOrWhiteSpace($entryText)) {
            return $false
        }

        $entryText = $entryText.Trim()
        $targetHost = [string]$TargetUri.Host
        if ([string]::IsNullOrWhiteSpace($targetHost)) {
            return $false
        }

        $targetHostNormalized = $targetHost.Trim().Trim('.').ToLowerInvariant()
        $entryHostText = $entryText
        $entryPort = $null
        $entryHasLeadingDot = $entryText.StartsWith('.')

        if ($entryText -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
            try {
                $entryUri = [uri]$entryText
                $entryHostText = $entryUri.Host
                if (-not $entryUri.IsDefaultPort) {
                    $entryPort = [int]$entryUri.Port
                }
            }
            catch {
                return $false
            }
        }
        elseif ($entryText.StartsWith('[') -or $entryText -match '^[^:]+:\d+$') {
            try {
                $entryUri = [uri]("http://{0}" -f $entryText)
                $entryHostText = $entryUri.Host
                if (-not $entryUri.IsDefaultPort) {
                    $entryPort = [int]$entryUri.Port
                }
            }
            catch {
                return $false
            }
        }

        if ([string]::IsNullOrWhiteSpace($entryHostText)) {
            return $false
        }

        $entryHostNormalized = $entryHostText.Trim().Trim('.').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($entryHostNormalized)) {
            return $false
        }

        if ($null -ne $entryPort -and $TargetUri.Port -ne $entryPort) {
            return $false
        }

        if ($entryHasLeadingDot) {
            $entryHostNormalized = $entryHostNormalized.TrimStart('.')
            if ([string]::IsNullOrWhiteSpace($entryHostNormalized)) {
                return $false
            }

            return $targetHostNormalized.EndsWith(".{0}" -f $entryHostNormalized)
        }

        return $targetHostNormalized -eq $entryHostNormalized
    }

    function Resolve-EnvironmentProxySetting {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri
        )

        $diagnostics = New-Object System.Collections.Generic.List[string]

        $proxyVariableNames = switch ($TargetUri.Scheme.ToLowerInvariant()) {
            'https' { @('https_proxy','HTTPS_PROXY','all_proxy','ALL_PROXY') }
            'http' { @('http_proxy','HTTP_PROXY','all_proxy','ALL_PROXY') }
            default { @('all_proxy','ALL_PROXY') }
        }

        $proxyVariable = Get-EnvironmentVariableSetting -Names $proxyVariableNames
        if ($null -eq $proxyVariable) {
            [void]$diagnostics.Add('No applicable environment proxy variable was found for the current target URI.')
            return [pscustomobject]@{
                Resolved = $false
                ProxyUri = $null
                ProxyCredential = $null
                SourceVariableName = $null
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        $noProxyVariable = Get-EnvironmentVariableSetting -Names @('no_proxy','NO_PROXY')
        if ($null -ne $noProxyVariable) {
            foreach ($entry in (Get-NoProxyEntries -NoProxyValue $noProxyVariable.Value)) {
                if (Test-NoProxyEntryMatchesTarget -Entry $entry -TargetUri $TargetUri) {
                    [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' is bypassed for '$($TargetUri.Host)' by NO_PROXY entry '$entry'.")
                    return [pscustomobject]@{
                        Resolved = $false
                        ProxyUri = $null
                        ProxyCredential = $null
                        SourceVariableName = $proxyVariable.Name
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }
            }
        }

        $proxyLiteral = ([string]$proxyVariable.Value).Trim()
        if ($proxyLiteral -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
            $proxyLiteral = "http://{0}" -f $proxyLiteral
        }

        try {
            $parsedProxyUri = [uri]$proxyLiteral
        }
        catch {
            [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' is invalid: $($_.Exception.Message)")
            return [pscustomobject]@{
                Resolved = $false
                ProxyUri = $null
                ProxyCredential = $null
                SourceVariableName = $proxyVariable.Name
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        if (-not $parsedProxyUri.IsAbsoluteUri -or [string]::IsNullOrWhiteSpace($parsedProxyUri.Host)) {
            [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' does not contain a usable absolute proxy URI.")
            return [pscustomobject]@{
                Resolved = $false
                ProxyUri = $null
                ProxyCredential = $null
                SourceVariableName = $proxyVariable.Name
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        $proxyScheme = $parsedProxyUri.Scheme.ToLowerInvariant()
        if (@('http','https') -notcontains $proxyScheme) {
            [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' uses unsupported proxy scheme '$proxyScheme'.")
            return [pscustomobject]@{
                Resolved = $false
                ProxyUri = $null
                ProxyCredential = $null
                SourceVariableName = $proxyVariable.Name
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        if (($parsedProxyUri.AbsolutePath -ne '/') -or
            -not [string]::IsNullOrWhiteSpace($parsedProxyUri.Query) -or
            -not [string]::IsNullOrWhiteSpace($parsedProxyUri.Fragment)) {
            [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' contains unsupported path, query, or fragment text after the proxy host.")
            return [pscustomobject]@{
                Resolved = $false
                ProxyUri = $null
                ProxyCredential = $null
                SourceVariableName = $proxyVariable.Name
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        $builder = New-Object System.UriBuilder($parsedProxyUri)
        $proxyCredential = $null

        if (-not [string]::IsNullOrWhiteSpace([string]$builder.UserName) -or
            -not [string]::IsNullOrWhiteSpace([string]$builder.Password)) {
            if ([string]::IsNullOrWhiteSpace([string]$builder.UserName)) {
                [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' contains proxy credentials without a user name.")
                return [pscustomobject]@{
                    Resolved = $false
                    ProxyUri = $null
                    ProxyCredential = $null
                    SourceVariableName = $proxyVariable.Name
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            try {
                $userName = [System.Uri]::UnescapeDataString([string]$builder.UserName)
                $password = [System.Uri]::UnescapeDataString([string]$builder.Password)
                $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
                $proxyCredential = New-Object System.Management.Automation.PSCredential($userName, $securePassword)
            }
            catch {
                [void]$diagnostics.Add("Environment proxy credentials from '$($proxyVariable.Name)' could not be parsed: $($_.Exception.Message)")
                return [pscustomobject]@{
                    Resolved = $false
                    ProxyUri = $null
                    ProxyCredential = $null
                    SourceVariableName = $proxyVariable.Name
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            $builder.UserName = ''
            $builder.Password = ''
        }

        $proxyUri = $builder.Uri
        [void]$diagnostics.Add("Environment proxy settings were resolved from '$($proxyVariable.Name)' as '$($proxyUri.AbsoluteUri)'.")

        return [pscustomobject]@{
            Resolved = $true
            ProxyUri = $proxyUri
            ProxyCredential = $proxyCredential
            SourceVariableName = $proxyVariable.Name
            Diagnostics = @($diagnostics.ToArray())
        }
    }

    function Try-ResolveEnvironmentProxy {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)]
            [uri]$Uri,

            [Parameter(Mandatory = $true)]
            [int]$TimeoutSec
        )

        $environmentProxy = Resolve-EnvironmentProxySetting -TargetUri $Uri
        $diagnostics = New-Object System.Collections.Generic.List[string]

        foreach ($message in $environmentProxy.Diagnostics) {
            [void]$diagnostics.Add($message)
        }

        if (-not $environmentProxy.Resolved -or $null -eq $environmentProxy.ProxyUri) {
            return [pscustomobject]@{
                Success = $false
                ProxyUri = $null
                ProxyCredential = $null
                UseDefaultProxyCredentials = $false
                StatusCode = $null
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        try {
            $proxyObject = New-Object System.Net.WebProxy($environmentProxy.ProxyUri.AbsoluteUri, $true)
            if ($null -ne $environmentProxy.ProxyCredential) {
                $proxyObject.Credentials = $environmentProxy.ProxyCredential.GetNetworkCredential()
            }

            $result = Test-Access -Uri $Uri -TimeoutSec $TimeoutSec -Proxy $proxyObject

            if ($result.Success) {
                return [pscustomobject]@{
                    Success = $true
                    ProxyUri = $environmentProxy.ProxyUri
                    ProxyCredential = $environmentProxy.ProxyCredential
                    UseDefaultProxyCredentials = $false
                    StatusCode = $result.StatusCode
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            [void]$diagnostics.Add("Environment proxy '$($environmentProxy.ProxyUri.AbsoluteUri)' failed HTTP probe: $($result.ErrorMessage)")

            $canRetryWithDefaultProxyCredentials =
                ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) -and
                ($null -eq $environmentProxy.ProxyCredential)

            if ($canRetryWithDefaultProxyCredentials -and $result.StatusCode -eq [int][System.Net.HttpStatusCode]::ProxyAuthenticationRequired) {
                [void]$diagnostics.Add("Environment proxy '$($environmentProxy.ProxyUri.AbsoluteUri)' requested proxy authentication. Retrying once with default proxy credentials.")

                $defaultCredentialProxy = New-Object System.Net.WebProxy($environmentProxy.ProxyUri.AbsoluteUri, $true)
                $defaultCredentialProxy.UseDefaultCredentials = $true

                $defaultCredentialResult = Test-Access -Uri $Uri -TimeoutSec $TimeoutSec -Proxy $defaultCredentialProxy
                if ($defaultCredentialResult.Success) {
                    [void]$diagnostics.Add("Environment proxy '$($environmentProxy.ProxyUri.AbsoluteUri)' succeeded when retried with default proxy credentials.")
                    return [pscustomobject]@{
                        Success = $true
                        ProxyUri = $environmentProxy.ProxyUri
                        ProxyCredential = $null
                        UseDefaultProxyCredentials = $true
                        StatusCode = $defaultCredentialResult.StatusCode
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                [void]$diagnostics.Add("Environment proxy '$($environmentProxy.ProxyUri.AbsoluteUri)' still failed after retry with default proxy credentials: $($defaultCredentialResult.ErrorMessage)")
            }
        }
        catch {
            [void]$diagnostics.Add("Environment proxy '$($environmentProxy.ProxyUri.AbsoluteUri)' check failed: $($_.Exception.Message)")
        }

        return [pscustomobject]@{
            Success = $false
            ProxyUri = $environmentProxy.ProxyUri
            ProxyCredential = $environmentProxy.ProxyCredential
            UseDefaultProxyCredentials = $false
            StatusCode = $null
            Diagnostics = @($diagnostics.ToArray())
        }
    }

    function Get-LocalRelayProxyCandidates {
        return @(
            [uri]'http://127.0.0.1:3128',
            [uri]'http://localhost:3128'
        )
    }

    function Test-LoopbackPortOpen {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$ProxyUri,

            [ValidateRange(50,5000)]
            [int]$ConnectTimeoutMilliseconds = 400
        )

        $hostName = $ProxyUri.Host
        if (@('127.0.0.1', 'localhost', '::1') -notcontains $hostName) {
            return $false
        }

        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $client.BeginConnect($hostName, $ProxyUri.Port, $null, $null)

            if (-not $asyncResult.AsyncWaitHandle.WaitOne($ConnectTimeoutMilliseconds, $false)) {
                return $false
            }

            [void]$client.EndConnect($asyncResult)
            return $client.Connected
        }
        catch {
            return $false
        }
        finally {
            if ($client) {
                $client.Close()
            }
        }
    }

    function Try-ResolveLocalRelayProxy {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)]
            [uri]$Uri,

            [Parameter(Mandatory = $true)]
            [int]$TimeoutSec
        )

        $diagnostics = New-Object System.Collections.Generic.List[string]

        foreach ($candidate in (Get-LocalRelayProxyCandidates)) {
            if (-not (Test-LoopbackPortOpen -ProxyUri $candidate)) {
                [void]$diagnostics.Add("Local relay proxy candidate '$($candidate.AbsoluteUri)' is not listening on loopback.")
                continue
            }

            try {
                $proxyObject = New-Object System.Net.WebProxy($candidate.AbsoluteUri, $true)
                $result = Test-Access -Uri $Uri -TimeoutSec $TimeoutSec -Proxy $proxyObject

                if ($result.Success) {
                    return [pscustomobject]@{
                        Success     = $true
                        ProxyUri    = $candidate
                        StatusCode  = $result.StatusCode
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                [void]$diagnostics.Add("Local relay proxy candidate '$($candidate.AbsoluteUri)' failed HTTP probe: $($result.ErrorMessage)")
            }
            catch {
                [void]$diagnostics.Add("Local relay proxy candidate '$($candidate.AbsoluteUri)' check failed: $($_.Exception.Message)")
            }
        }

        return [pscustomobject]@{
            Success     = $false
            ProxyUri    = $null
            StatusCode  = $null
            Diagnostics = @($diagnostics.ToArray())
        }
    }

    function Test-PersistedProfile {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$StoredProfile,

            [Parameter(Mandatory = $true)]
            [uri]$ValidationUri,

            [Parameter(Mandatory = $true)]
            [int]$TimeoutSec
        )

        $diagnostics = New-Object System.Collections.Generic.List[string]
        $mode = [string]$StoredProfile.Mode

        switch ($mode) {
            'Direct' {
                $noProxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
                $direct = Test-Access -Uri $ValidationUri -TimeoutSec $TimeoutSec -Proxy $noProxy

                if ($direct.Success) {
                    [void]$diagnostics.Add("Persisted direct profile validation succeeded with status code $($direct.StatusCode).")
                    return [pscustomobject]@{
                        Success     = $true
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                [void]$diagnostics.Add("Persisted direct profile validation failed: $($direct.ErrorMessage)")
                return [pscustomobject]@{
                    Success     = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            'EnvironmentProxy' {
                if (-not $StoredProfile.ProxyUri) {
                    [void]$diagnostics.Add('Persisted environment proxy profile is missing ProxyUri.')
                    return [pscustomobject]@{
                        Success     = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                $proxyCredential = $null
                if ($StoredProfile.ProxyCredential -is [System.Management.Automation.PSCredential]) {
                    $proxyCredential = [System.Management.Automation.PSCredential]$StoredProfile.ProxyCredential
                }
                elseif ($null -ne $StoredProfile.ProxyUserName) {
                    try {
                        $securePassword = ConvertTo-SecureString ([string]$StoredProfile.ProxyPassword) -AsPlainText -Force
                        $proxyCredential = New-Object System.Management.Automation.PSCredential(
                            [string]$StoredProfile.ProxyUserName,
                            $securePassword
                        )
                    }
                    catch {
                        $proxyCredential = $null
                    }
                }

                try {
                    $proxyUri = [uri][string]$StoredProfile.ProxyUri
                    $environmentProxy = New-Object System.Net.WebProxy($proxyUri.AbsoluteUri, $true)
                    if ([bool]$StoredProfile.UseDefaultProxyCredentials -and $null -eq $proxyCredential) {
                        $environmentProxy.UseDefaultCredentials = $true
                    }
                    elseif ($null -ne $proxyCredential) {
                        $environmentProxy.Credentials = $proxyCredential.GetNetworkCredential()
                    }

                    $result = Test-Access -Uri $ValidationUri -TimeoutSec $TimeoutSec -Proxy $environmentProxy

                    if ($result.Success) {
                        [void]$diagnostics.Add("Persisted environment proxy validation succeeded with status code $($result.StatusCode) via '$($proxyUri.AbsoluteUri)'.")
                        return [pscustomobject]@{
                            Success     = $true
                            Diagnostics = @($diagnostics.ToArray())
                        }
                    }

                    [void]$diagnostics.Add("Persisted environment proxy validation failed: $($result.ErrorMessage)")
                }
                catch {
                    [void]$diagnostics.Add("Persisted environment proxy validation check failed: $($_.Exception.Message)")
                }

                return [pscustomobject]@{
                    Success     = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            'LocalRelayProxy' {
                if (-not $StoredProfile.ProxyUri) {
                    [void]$diagnostics.Add('Persisted local relay proxy profile is missing ProxyUri.')
                    return [pscustomobject]@{
                        Success     = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                try {
                    $proxyUri = [uri][string]$StoredProfile.ProxyUri
                }
                catch {
                    [void]$diagnostics.Add("Persisted local relay proxy URI could not be parsed: $($_.Exception.Message)")
                    return [pscustomobject]@{
                        Success     = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                if (-not (Test-LoopbackPortOpen -ProxyUri $proxyUri)) {
                    [void]$diagnostics.Add("Persisted local relay proxy '$($proxyUri.AbsoluteUri)' is not listening on loopback.")
                    return [pscustomobject]@{
                        Success     = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                try {
                    $proxyObject = New-Object System.Net.WebProxy($proxyUri.AbsoluteUri, $true)
                    $result = Test-Access -Uri $ValidationUri -TimeoutSec $TimeoutSec -Proxy $proxyObject

                    if ($result.Success) {
                        [void]$diagnostics.Add("Persisted local relay proxy validation succeeded with status code $($result.StatusCode) via '$($proxyUri.AbsoluteUri)'.")
                        return [pscustomobject]@{
                            Success     = $true
                            Diagnostics = @($diagnostics.ToArray())
                        }
                    }

                    [void]$diagnostics.Add("Persisted local relay proxy validation failed: $($result.ErrorMessage)")
                }
                catch {
                    [void]$diagnostics.Add("Persisted local relay proxy validation check failed: $($_.Exception.Message)")
                }

                return [pscustomobject]@{
                    Success     = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            'SystemProxyDefaultCredentials' {
                try {
                    $systemProxy = [System.Net.WebRequest]::GetSystemWebProxy()
                    $resolvedProxy = $systemProxy.GetProxy($ValidationUri)

                    if ($systemProxy.IsBypassed($ValidationUri) -or
                        -not $resolvedProxy -or
                        $resolvedProxy.AbsoluteUri -eq $ValidationUri.AbsoluteUri) {
                        [void]$diagnostics.Add('Persisted system proxy profile validation found no distinct system proxy for the current test URI.')
                        return [pscustomobject]@{
                            Success     = $false
                            Diagnostics = @($diagnostics.ToArray())
                        }
                    }

                    $systemProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                    $result = Test-Access -Uri $ValidationUri -TimeoutSec $TimeoutSec -Proxy $systemProxy

                    if ($result.Success) {
                        [void]$diagnostics.Add("Persisted system proxy validation succeeded with status code $($result.StatusCode) via '$($resolvedProxy.AbsoluteUri)'.")
                        return [pscustomobject]@{
                            Success     = $true
                            Diagnostics = @($diagnostics.ToArray())
                        }
                    }

                    [void]$diagnostics.Add("Persisted system proxy validation failed: $($result.ErrorMessage)")
                }
                catch {
                    [void]$diagnostics.Add("Persisted system proxy validation check failed: $($_.Exception.Message)")
                }

                return [pscustomobject]@{
                    Success     = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            'ManualProxy' {
                if (-not $StoredProfile.ProxyUri) {
                    [void]$diagnostics.Add('Persisted manual proxy profile is missing ProxyUri.')
                    return [pscustomobject]@{
                        Success     = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                if (-not ($StoredProfile.ProxyCredential -is [System.Management.Automation.PSCredential])) {
                    [void]$diagnostics.Add('Persisted manual proxy profile is missing a usable PSCredential.')
                    return [pscustomobject]@{
                        Success     = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                try {
                    $proxyUri = [uri][string]$StoredProfile.ProxyUri
                    $proxyCredential = [System.Management.Automation.PSCredential]$StoredProfile.ProxyCredential

                    $manualProxy = New-Object System.Net.WebProxy($proxyUri.AbsoluteUri, $true)
                    $manualProxy.Credentials = $proxyCredential.GetNetworkCredential()
                    $result = Test-Access -Uri $ValidationUri -TimeoutSec $TimeoutSec -Proxy $manualProxy

                    if ($result.Success) {
                        [void]$diagnostics.Add("Persisted manual proxy validation succeeded with status code $($result.StatusCode) via '$($proxyUri.AbsoluteUri)'.")
                        return [pscustomobject]@{
                            Success     = $true
                            Diagnostics = @($diagnostics.ToArray())
                        }
                    }

                    [void]$diagnostics.Add("Persisted manual proxy validation failed: $($result.ErrorMessage)")
                }
                catch {
                    [void]$diagnostics.Add("Persisted manual proxy validation check failed: $($_.Exception.Message)")
                }

                return [pscustomobject]@{
                    Success     = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            'NoResolvedProxyProfile' {
                [void]$diagnostics.Add('Persisted NoResolvedProxyProfile entries are not considered reusable.')
                return [pscustomobject]@{
                    Success     = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            default {
                [void]$diagnostics.Add("Persisted profile mode '$mode' is not supported.")
                return [pscustomobject]@{
                    Success     = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }
        }
    }

    function Get-ManualProxyEntry {
        param(
            [Parameter(Mandatory = $true)]
            [string]$DefaultProxy
        )

        Add-Type -AssemblyName System.Windows.Forms,System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Proxy settings'
        $form.StartPosition = 'CenterScreen'
        $form.TopMost = $true
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.ClientSize = New-Object System.Drawing.Size(400,170)
        $form.Font = New-Object System.Drawing.Font('Segoe UI',9)

        $lbl1 = New-Object System.Windows.Forms.Label
        $lbl1.Text = 'Proxy address'
        $lbl1.Location = New-Object System.Drawing.Point(15,21)
        $lbl1.AutoSize = $true
        [void]$form.Controls.Add($lbl1)

        $txtProxy = New-Object System.Windows.Forms.TextBox
        $txtProxy.Location = New-Object System.Drawing.Point(120,18)
        $txtProxy.Size = New-Object System.Drawing.Size(260,23)
        $txtProxy.Text = $DefaultProxy
        [void]$form.Controls.Add($txtProxy)

        $lbl2 = New-Object System.Windows.Forms.Label
        $lbl2.Text = 'Username'
        $lbl2.Location = New-Object System.Drawing.Point(15,55)
        $lbl2.AutoSize = $true
        [void]$form.Controls.Add($lbl2)

        $txtUser = New-Object System.Windows.Forms.TextBox
        $txtUser.Location = New-Object System.Drawing.Point(120,52)
        $txtUser.Size = New-Object System.Drawing.Size(260,23)
        [void]$form.Controls.Add($txtUser)

        $lbl3 = New-Object System.Windows.Forms.Label
        $lbl3.Text = 'Password'
        $lbl3.Location = New-Object System.Drawing.Point(15,89)
        $lbl3.AutoSize = $true
        [void]$form.Controls.Add($lbl3)

        $txtPass = New-Object System.Windows.Forms.TextBox
        $txtPass.Location = New-Object System.Drawing.Point(120,86)
        $txtPass.Size = New-Object System.Drawing.Size(260,23)
        $txtPass.UseSystemPasswordChar = $true
        [void]$form.Controls.Add($txtPass)

        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = 'OK'
        $ok.Location = New-Object System.Drawing.Point(224,124)
        $ok.Size = New-Object System.Drawing.Size(75,28)
        $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
        [void]$form.Controls.Add($ok)

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = 'Cancel'
        $cancel.Location = New-Object System.Drawing.Point(305,124)
        $cancel.Size = New-Object System.Drawing.Size(75,28)
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        [void]$form.Controls.Add($cancel)

        $form.AcceptButton = $ok
        $form.CancelButton = $cancel

        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            return $null
        }

        [pscustomobject]@{
            ProxyUri = [uri]$txtProxy.Text
            ProxyCredential = New-Object System.Management.Automation.PSCredential(
                $txtUser.Text,
                (ConvertTo-SecureString $txtPass.Text -AsPlainText -Force)
            )
        }
    }

    $previousCertificateValidationCallback = $null
    $skipCertificateCheckEnabled = $false
    $persistedProfileValidationDiagnostics = @()

    try {
        try {
            $tls12 = [System.Net.SecurityProtocolType]::Tls12
            $currentProtocols = [System.Net.ServicePointManager]::SecurityProtocol

            if (($currentProtocols -band $tls12) -ne $tls12) {
                [System.Net.ServicePointManager]::SecurityProtocol = $currentProtocols -bor $tls12
            }
        }
        catch {
        }

        if ($effectiveSkipCertificateCheck) {
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

        if (-not $ForceRefresh) {
            $storedProfile = Load-PersistedProfile -ProfilePath $ProxyProfilePath
            if ($null -ne $storedProfile) {
                $persistedValidation = Test-PersistedProfile `
                    -StoredProfile $storedProfile `
                    -ValidationUri $TestUri `
                    -TimeoutSec $TimeoutSec

                if ($persistedValidation.Success) {
                    Reset-ProxyGlobals
                    Apply-StoredProfileToGlobals -StoredProfile $storedProfile -ProfileSource 'ProfileFile'
                    return
                }

                $persistedProfileValidationDiagnostics = @($persistedValidation.Diagnostics)
                Remove-PersistedProfile -ProfilePath $ProxyProfilePath
            }
        }

        Reset-ProxyGlobals

        $diagnostics = New-Object System.Collections.Generic.List[string]
        foreach ($message in $persistedProfileValidationDiagnostics) {
            [void]$diagnostics.Add($message)
        }

        $isInteractive = [System.Environment]::UserInteractive

        # True direct test: use an empty proxy so the probe cannot silently fall back
        # to system proxy settings behind our back.
        $noProxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
        $direct = Test-Access -Uri $TestUri -TimeoutSec $TimeoutSec -Proxy $noProxy

        if ($direct.Success) {
            $stored = New-StoredProfile `
                -Mode 'Direct' `
                -DetectedTestUri $TestUri `
                -Diagnostics @(
                    $diagnostics.ToArray() +
                    "Direct probe succeeded with status code $($direct.StatusCode)."
                )

            $saveError = Save-PersistedProfile -StoredProfile $stored -ProfilePath $ProxyProfilePath
            if ($saveError) {
                $stored.Diagnostics = @($stored.Diagnostics + "Profile file save failed: $saveError")
            }

            Apply-StoredProfileToGlobals -StoredProfile $stored -ProfileSource 'FreshDetection'
            return
        }

        [void]$diagnostics.Add("Direct probe failed: $($direct.ErrorMessage)")

        # Try process-environment proxy settings before heuristic local or system proxy discovery.
        $environmentProxy = Try-ResolveEnvironmentProxy -Uri $TestUri -TimeoutSec $TimeoutSec

        foreach ($message in $environmentProxy.Diagnostics) {
            [void]$diagnostics.Add($message)
        }

        if ($environmentProxy.Success -and $null -ne $environmentProxy.ProxyUri) {
            $stored = New-StoredProfile `
                -Mode 'EnvironmentProxy' `
                -DetectedTestUri $TestUri `
                -ProxyUri $environmentProxy.ProxyUri `
                -ProxyCredential $environmentProxy.ProxyCredential `
                -UseDefaultProxyCredentials $environmentProxy.UseDefaultProxyCredentials `
                -Diagnostics @(
                    $diagnostics.ToArray() +
                    "Environment proxy probe succeeded with status code $($environmentProxy.StatusCode) via '$($environmentProxy.ProxyUri.AbsoluteUri)'."
                )

            $saveError = Save-PersistedProfile -StoredProfile $stored -ProfilePath $ProxyProfilePath
            if ($saveError) {
                $stored.Diagnostics = @($stored.Diagnostics + "Profile file save failed: $saveError")
            }

            Apply-StoredProfileToGlobals -StoredProfile $stored -ProfileSource 'FreshDetection'
            return
        }

        # Try a local loopback relay before system proxy. This is useful when users
        # run tools like px or similar local proxy helpers.
        $localRelay = Try-ResolveLocalRelayProxy -Uri $TestUri -TimeoutSec $TimeoutSec

        foreach ($message in $localRelay.Diagnostics) {
            [void]$diagnostics.Add($message)
        }

        if ($localRelay.Success -and $null -ne $localRelay.ProxyUri) {
            $stored = New-StoredProfile `
                -Mode 'LocalRelayProxy' `
                -DetectedTestUri $TestUri `
                -ProxyUri $localRelay.ProxyUri `
                -Diagnostics @(
                    $diagnostics.ToArray() +
                    "Local relay proxy probe succeeded with status code $($localRelay.StatusCode) via '$($localRelay.ProxyUri.AbsoluteUri)'."
                )

            $saveError = Save-PersistedProfile -StoredProfile $stored -ProfilePath $ProxyProfilePath
            if ($saveError) {
                $stored.Diagnostics = @($stored.Diagnostics + "Profile file save failed: $saveError")
            }

            Apply-StoredProfileToGlobals -StoredProfile $stored -ProfileSource 'FreshDetection'
            return
        }

        $systemProxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $resolvedProxy = $systemProxy.GetProxy($TestUri)

        if (-not $systemProxy.IsBypassed($TestUri) -and
            $resolvedProxy -and
            $resolvedProxy.AbsoluteUri -ne $TestUri.AbsoluteUri) {

            # In system-proxy mode we try integrated auth with the current Windows user.
            $systemProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
            $system = Test-Access -Uri $TestUri -TimeoutSec $TimeoutSec -Proxy $systemProxy

            if ($system.Success) {
                $stored = New-StoredProfile `
                    -Mode 'SystemProxyDefaultCredentials' `
                    -DetectedTestUri $TestUri `
                    -ProxyUri $resolvedProxy `
                    -UseDefaultProxyCredentials $true `
                    -Diagnostics @(
                        $diagnostics.ToArray() +
                        "System proxy probe succeeded with status code $($system.StatusCode)."
                    )

                $saveError = Save-PersistedProfile -StoredProfile $stored -ProfilePath $ProxyProfilePath
                if ($saveError) {
                    $stored.Diagnostics = @($stored.Diagnostics + "Profile file save failed: $saveError")
                }

                Apply-StoredProfileToGlobals -StoredProfile $stored -ProfileSource 'FreshDetection'
                return
            }

            [void]$diagnostics.Add("System proxy probe failed: $($system.ErrorMessage)")
        }
        else {
            [void]$diagnostics.Add('No distinct system proxy was resolved for the test URI.')
        }

        if (-not $SkipManualProxyPrompt) {
            if (-not $isInteractive) {
                Remove-PersistedProfile -ProfilePath $ProxyProfilePath
                throw "Manual proxy entry is required for '$($TestUri.AbsoluteUri)', but the current session is non-interactive. Provide proxy parameters explicitly or pre-stage a usable proxy profile file."
            }

            try {
                $manual = Get-ManualProxyEntry -DefaultProxy $DefaultManualProxy
            }
            catch {
                $manual = $null
                [void]$diagnostics.Add("Manual proxy prompt failed: $($_.Exception.Message)")
            }

            if ($manual) {
                $manualProxy = New-Object System.Net.WebProxy($manual.ProxyUri.AbsoluteUri, $true)
                $manualProxy.Credentials = $manual.ProxyCredential.GetNetworkCredential()
                $manualTest = Test-Access -Uri $TestUri -TimeoutSec $TimeoutSec -Proxy $manualProxy

                if ($manualTest.Success) {
                    $stored = New-StoredProfile `
                        -Mode 'ManualProxy' `
                        -DetectedTestUri $TestUri `
                        -ProxyUri $manual.ProxyUri `
                        -ProxyCredential $manual.ProxyCredential `
                        -Diagnostics @(
                            $diagnostics.ToArray() +
                            "Manual proxy probe succeeded with status code $($manualTest.StatusCode)."
                        )

                    $saveError = Save-PersistedProfile -StoredProfile $stored -ProfilePath $ProxyProfilePath
                    if ($saveError) {
                        $stored.Diagnostics = @($stored.Diagnostics + "Profile file save failed: $saveError")
                    }

                    Apply-StoredProfileToGlobals -StoredProfile $stored -ProfileSource 'FreshDetection'
                    return
                }

                [void]$diagnostics.Add("Manual proxy probe failed: $($manualTest.ErrorMessage)")
            }
            else {
                [void]$diagnostics.Add('Manual proxy entry was cancelled.')
            }
        }
        else {
            [void]$diagnostics.Add('Manual proxy prompt was skipped by caller.')
        }

        # We do not persist a NoResolvedProxyProfile state. That avoids carrying a bad result
        # across sessions after a temporary network problem.
        Remove-PersistedProfile -ProfilePath $ProxyProfilePath

        Set-ProxyGlobals `
            -Mode 'NoResolvedProxyProfile' `
            -Diagnostics $diagnostics.ToArray() `
            -ProfileSource 'FreshDetection'
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
    }
}

function Invoke-WebRequestEx10 {
<#
.SYNOPSIS
    Invokes a web request with Windows-focused compatibility improvements,
    retry logic, persisted proxy-profile handling, proxy/TLS handling,
    resilient streaming downloads, resume support, and optional final hash verification.

.DESCRIPTION
    Invoke-WebRequestEx10 is intended for Windows PowerShell 5.1 and
    PowerShell 7+ on Windows where outbound access may depend on proxy
    discovery and where large or long-running downloads need stronger
    operational behavior.

    The function supports general web requests and extends them with additional
    behavior that is useful for automation, infrastructure scripts, artifact
    downloads, and resumable file transfer scenarios.

    Added behavior includes:
    - TLS 1.2 enablement when not already active
    - OutFile parent directory creation
    - Persisted proxy-profile resolution when the caller did not explicitly provide proxy settings
    - Environment-defined proxy discovery from HTTPS_PROXY / HTTP_PROXY / ALL_PROXY with NO_PROXY handling
    - Live validation of persisted proxy profiles before reuse
    - Retry handling for all HTTP methods
    - Optional total retry budget across attempts
    - Optional streaming download engine for compatible GET + OutFile requests
    - Automatic resume for compatible streaming downloads unless disabled
    - Resume metadata validation using persisted ETag / Last-Modified sidecar state
    - Cooperative lock file handling to reduce concurrent download collisions for the same target
    - Optional final required hash verification for streaming downloads
    - Optional partial-file cleanup on terminal streaming failure
    - Optional automatic retry with UseDefaultCredentials after an initial 401 challenge
      when the target appears intranet-like and the caller did not explicitly provide credentials
    - One-time persisted manual-proxy profile invalidation and re-resolution on likely proxy-authentication failure

    Proxy resolution uses a persisted proxy-profile resolver that tries:

    1. Direct access
    2. Environment proxy from process environment variables
    3. Local relay proxy on loopback
    4. System proxy with default credentials
    5. Manual proxy

    The resolved profile is cached in-process and also persisted as a CliXml file
    in the current user's profile.

    Persisted proxy profiles are validated with a live probe before reuse. If the
    stored profile is stale or no longer works, it is cleared and fresh detection
    continues automatically.

    The persisted profile format and default file location are aligned with
    Initialize-ProxyAccessProfile, but this function remains fully independent and
    does not rely on that helper.

    Request engine behavior:
    - Native Invoke-WebRequest remains the default engine for general requests
    - The streaming engine is only used for compatible GET + OutFile requests
    - Proxy-profile handling is skipped when the caller explicitly supplies proxy settings
    - Resume and final hash validation are function-managed features intended for the streaming path
    - Future runtimes with native -SkipCertificateCheck support should still keep
      compatible streaming downloads on the function-managed streaming path

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

    Certificate behavior:
    - If neither -SkipCertificateCheck nor -EnforceCertificateCheck is supplied,
      certificate bypass is enabled by default for compatibility with the
      proxy-resolution workflow
    - -EnforceCertificateCheck restores normal TLS server certificate validation
    - When the active native request path does not expose a clean per-call
      certificate-bypass switch, bypass still relies on temporary process-level
      callback changes in that path when enabled

    If the caller manually supplies proxy-related parameters, the persisted proxy
    profile logic is skipped entirely and the caller's settings win.

    If a persisted ManualProxy profile later fails with likely proxy-authentication
    errors, the stored profile is cleared automatically and proxy resolution is
    re-run once during the current call.

    If manual proxy entry would be required in a non-interactive session, the
    function throws instead of attempting to prompt.

.PARAMETER Uri
    The request URI.

.PARAMETER UseBasicParsing
    Forwards UseBasicParsing to native Invoke-WebRequest when supported by the
    active runtime. This parameter is not used by the streaming download path.

.PARAMETER WebSession
    Existing web session object to reuse with the native Invoke-WebRequest path.
    Supplying this parameter makes the request stay on the native path.

.PARAMETER SessionVariable
    Name of a session variable to populate from the native Invoke-WebRequest path.
    Supplying this parameter makes the request stay on the native path.

.PARAMETER Credential
    Explicit request credentials.
    Used directly on the native path and converted to NetworkCredential on the streaming path.

.PARAMETER UseDefaultCredentials
    Explicitly uses the current Windows credentials for request authentication.
    When supplied, this overrides the function's automatic intranet-style credential upgrade decision.

.PARAMETER CertificateThumbprint
    Client certificate thumbprint for the native Invoke-WebRequest path.
    Supplying this parameter makes the request stay on the native path.

.PARAMETER Certificate
    Client certificate instance for the native Invoke-WebRequest path.
    Supplying this parameter makes the request stay on the native path.

.PARAMETER UserAgent
    User-Agent string for the request.

.PARAMETER DisableKeepAlive
    Disables HTTP keep-alive for the underlying request where supported.

.PARAMETER TimeoutSec
    Per-attempt request timeout in seconds.
    Proxy probing uses 8 seconds when no positive timeout is supplied.

.PARAMETER Headers
    Optional request headers.
    Some headers such as Cookie, Date, or Range make the request stay on the native path.

.PARAMETER MaximumRedirection
    Maximum number of automatic redirects to follow.
    A value less than or equal to 0 disables automatic redirection.

.PARAMETER Method
    HTTP method to use.
    The streaming download path only supports GET.

.PARAMETER Proxy
    Explicit proxy URI for the request.
    Supplying any explicit proxy-related parameter skips persisted proxy-profile resolution.

.PARAMETER ProxyCredential
    Credential for the explicit proxy specified by -Proxy.

.PARAMETER ProxyUseDefaultCredentials
    Uses the current Windows credentials for the explicit proxy specified by -Proxy.

.PARAMETER Body
    Request body content.
    Supplying this parameter makes the request stay on the native path.

.PARAMETER ContentType
    Request content type.
    Supplying this parameter makes the request stay on the native path.

.PARAMETER TransferEncoding
    Request transfer encoding.
    Supplying this parameter makes the request stay on the native path.

.PARAMETER InFile
    Path to a request body file for upload scenarios.
    Supplying this parameter makes the request stay on the native path.

.PARAMETER OutFile
    Target path for response content.
    The parent directory is created automatically when needed.

.PARAMETER PassThru
    Requests pass-through output from the native Invoke-WebRequest path.
    Supplying this parameter makes the request stay on the native path.

.PARAMETER SkipCertificateCheck
    Explicitly enables TLS server certificate validation bypass.
    If neither this parameter nor -EnforceCertificateCheck is supplied, bypass is enabled by default.

.PARAMETER EnforceCertificateCheck
    Explicitly requires normal TLS server certificate validation.
    Use this to opt out of the function's default certificate-bypass behavior.

.PARAMETER DisableAutoUseDefaultCredentials
    Disables the automatic retry with UseDefaultCredentials after an initial 401
    challenge when the target appears intranet-like and the caller did not explicitly provide credentials.

.PARAMETER RetryCount
    Maximum number of request attempts.
    Applies to both native and streaming paths.

.PARAMETER RetryDelayMilliseconds
    Delay between retry attempts in milliseconds.

.PARAMETER TotalTimeoutSec
    Optional total retry budget in seconds across all attempts.
    A value of 0 disables total-budget enforcement.

.PARAMETER BufferSizeBytes
    Buffer size used by the streaming download engine.
    The default is 4 MB.

.PARAMETER ProgressIntervalPercent
    Progress reporting interval, in percent, when the total content length is known.

.PARAMETER ProgressIntervalBytes
    Progress reporting interval, in bytes, when the total content length is unknown.

.PARAMETER UseStreamingDownload
    Prefers the streaming download engine when the request is compatible with it.
    Compatible GET + OutFile requests may also use the streaming engine automatically.

.PARAMETER DisableResumeStreamingDownload
    Disables automatic resume behavior for the streaming download path.
    When set, streaming retries restart from byte 0 instead of resuming.

.PARAMETER DeletePartialStreamingDownloadOnFailure
    Deletes the target file on terminal streaming failure when the file was created
    by the current invocation and the operation did not complete successfully.

.PARAMETER RequiredStreamingHashType
    Required final hash algorithm for streaming download verification.
    Must be supplied together with -RequiredStreamingHash.

.PARAMETER RequiredStreamingHash
    Required final hash value for streaming download verification.
    Must be supplied together with -RequiredStreamingHashType.

.PARAMETER ProxyProfilePath
    Path to the persisted proxy profile file.
    This is only used when the caller did not explicitly provide proxy parameters.

.PARAMETER DefaultManualProxy
    Default proxy URI shown in the interactive manual proxy prompt.

.PARAMETER SkipProxyManualPrompt
    Prevents the interactive manual proxy prompt during proxy-profile resolution.
    If direct, environment proxy, local relay, and system proxy resolution all fail,
    the resolved mode becomes NoResolvedProxyProfile instead of prompting.

.PARAMETER SkipProxySessionPreparation
    Reserved compatibility switch for session-level proxy preparation.
    Version 10 applies resolved proxy settings per request and typically does not require extra session preparation.

.PARAMETER ForceRefreshProxyProfile
    Ignores any in-process or persisted proxy-profile cache and performs fresh proxy detection.

.PARAMETER ClearProxyProfile
    Deletes the persisted proxy-profile file before proxy resolution starts.

.EXAMPLE
    Invoke-WebRequestEx10 -Uri 'https://example.org'

    Performs a general web request using the native request path when
    no function-managed download path is needed.

.EXAMPLE
    Invoke-WebRequestEx10 -Uri 'https://example.org/file.zip' -OutFile 'C:\Temp\file.zip'

    Downloads a file. For compatible GET + OutFile requests, the function may use
    the streaming download engine automatically.

.EXAMPLE
    Invoke-WebRequestEx10 -Uri 'https://example.org/file.iso' -OutFile 'C:\Temp\file.iso' -UseStreamingDownload -RetryCount 10 -RetryDelayMilliseconds 5000

    Explicitly prefers the streaming path and retries the download up to 10 times
    with a 5 second delay between attempts.

.EXAMPLE
    Invoke-WebRequestEx10 -Uri 'https://intranet-app/api/status' -EnforceCertificateCheck

    Performs a request with normal TLS certificate validation enabled instead of
    the function's default certificate-bypass behavior.

.EXAMPLE
    Invoke-WebRequestEx10 -Uri 'https://artifact.example.corp/file.zip' -OutFile 'C:\Temp\file.zip' -ForceRefreshProxyProfile

    Forces fresh persisted proxy-profile detection before the request.

.EXAMPLE
    Invoke-WebRequestEx10 -Uri 'https://example.org/file.iso' -OutFile 'C:\Temp\file.iso' -RequiredStreamingHashType SHA256 -RequiredStreamingHash '570CE2BBC92545CFFBCB01DF43CBA59D86093DADC34C25DA9F554D256BC70B91'

    Downloads an artifact and verifies the final file against the required SHA256
    before success is reported.

.NOTES
    Intended as the replacement path for older Invoke-WebRequestEx variants in
    this repository.

    Active runtime gate: Windows PowerShell 5.1 and PowerShell 7+ on Windows.

    Explicit proxy parameters bypass proxy-profile resolution and win.

    If no managed proxy profile is resolved, the request falls back to
    normal/default behavior instead of failing resolution as a hard network
    error.

    Proxy-profile caching is tuned for the common corporate outbound-access
    case.
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
        [object]$Method,

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
        [switch]$SkipCertificateCheck,

        [Parameter()]
        [switch]$EnforceCertificateCheck,

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
        [switch]$UseStreamingDownload,

        [Parameter()]
        [switch]$DisableResumeStreamingDownload,

        [Parameter()]
        [Alias('DeleteStreamingFragmentsOnFailure')]
        [switch]$DeletePartialStreamingDownloadOnFailure,

        [Parameter()]
        [ValidateSet('SHA256')]
        [string]$RequiredStreamingHashType,

        [Parameter()]
        [string]$RequiredStreamingHash,

        # Persisted proxy profile controls.
        [Parameter()]
        [string]$ProxyProfilePath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\ProxyAccessProfile\ProxyAccessProfile.clixml'),

        [Parameter()]
        [string]$DefaultManualProxy = 'http://test.corp.com:8080',

        [Parameter()]
        [switch]$SkipProxyManualPrompt,

        [Parameter()]
        [switch]$SkipProxySessionPreparation,

        [Parameter()]
        [switch]$ForceRefreshProxyProfile,

        [Parameter()]
        [switch]$ClearProxyProfile
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

    function local:_UriDisplayShortener {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri
        )

        $originalText = [string]$TargetUri
        if ([string]::IsNullOrWhiteSpace($originalText)) {
            return $originalText
        }

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
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.ErrorRecord]$ErrorRecord
        )

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
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.ErrorRecord]$ErrorRecord
        )

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
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.ErrorRecord]$ErrorRecord
        )

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

    function local:_TestIsLikelyProxyAuthenticationFailure {
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.ErrorRecord]$ErrorRecord,

            [Parameter()]
            $StatusCode
        )

        if ($StatusCode -eq 407) {
            return $true
        }

        $response = _GetResponseFromErrorRecord -ErrorRecord $ErrorRecord
        if ($null -ne $response) {
            try {
                $headers = $response.Headers
                if ($null -ne $headers) {
                    $proxyAuthenticateValue = $headers['Proxy-Authenticate']
                    if (-not [string]::IsNullOrWhiteSpace([string]$proxyAuthenticateValue)) {
                        return $true
                    }
                }
            }
            catch {
            }
        }

        foreach ($candidate in @($ErrorRecord.Exception, $ErrorRecord.Exception.InnerException)) {
            if ($null -eq $candidate) { continue }

            $message = [string]$candidate.Message
            if ([string]::IsNullOrWhiteSpace($message)) { continue }

            if ($message -match '(?i)\b407\b') { return $true }
            if ($message -match '(?i)proxy.+auth') { return $true }
            if ($message -match '(?i)proxy.+credential') { return $true }
            if ($message -match '(?i)proxy server requires authentication') { return $true }
            if ($message -match '(?i)proxy authentication required') { return $true }
        }

        return $false
    }

    function local:_TestIsPrivateOrIntranetAddress {
        param(
            [Parameter(Mandatory = $true)]
            [System.Net.IPAddress]$Address
        )

        if ([System.Net.IPAddress]::IsLoopback($Address)) {
            return $true
        }

        if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
            if ($Address.IsIPv4MappedToIPv6) {
                try {
                    return _TestIsPrivateOrIntranetAddress -Address $Address.MapToIPv4()
                }
                catch {
                    return $false
                }
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
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri
        )

        $signals = New-Object System.Collections.Generic.List[string]
        $resolvedAddresses = New-Object System.Collections.Generic.List[string]

        $hostname = if (-not [string]::IsNullOrWhiteSpace($TargetUri.DnsSafeHost)) {
            $TargetUri.DnsSafeHost
        }
        else {
            $TargetUri.Host
        }

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
            IsIntranetLike = ($signals.Count -gt 0)
            Signals = @($signals.ToArray())
            ResolvedAddresses = @($resolvedAddresses.ToArray())
        }
    }

    function local:_GetProcessProxyProfileCacheTable {
        if (-not $global:InvokeWebRequestEx10ProxyProfileProcessCache -or
            $global:InvokeWebRequestEx10ProxyProfileProcessCache -isnot [hashtable]) {
            $global:InvokeWebRequestEx10ProxyProfileProcessCache = @{}
        }

        return $global:InvokeWebRequestEx10ProxyProfileProcessCache
    }

    function local:_EnsurePersistedProxyProfileDirectory {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProfilePath
        )

        $directory = [System.IO.Path]::GetDirectoryName($ProfilePath)
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not [System.IO.Directory]::Exists($directory)) {
            [void][System.IO.Directory]::CreateDirectory($directory)
        }
    }

    function local:_RemovePersistedProxyProfile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProfilePath
        )

        if (Test-Path -LiteralPath $ProfilePath) {
            Remove-Item -LiteralPath $ProfilePath -Force -ErrorAction SilentlyContinue
        }

        $cacheTable = _GetProcessProxyProfileCacheTable
        if ($cacheTable.ContainsKey($ProfilePath)) {
            [void]$cacheTable.Remove($ProfilePath)
        }
    }

    function local:_SavePersistedProxyProfile {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$StoredProfile,

            [Parameter(Mandatory = $true)]
            [string]$ProfilePath
        )

        try {
            _EnsurePersistedProxyProfileDirectory -ProfilePath $ProfilePath
            Export-Clixml -InputObject $StoredProfile -LiteralPath $ProfilePath -Force -ErrorAction Stop

            if (-not (Test-Path -LiteralPath $ProfilePath)) {
                throw "The proxy profile file could not be verified after export."
            }

            _Write-StandardMessage -Message (
                "[STATUS] Persisted proxy profile to '{0}'." -f $ProfilePath
            ) -Level INF
        }
        catch {
            _Write-StandardMessage -Message (
                "[WRN] Failed to persist proxy profile to '{0}': {1}" -f
                $ProfilePath, $_.Exception.Message
            ) -Level WRN
            return
        }
    }

    function local:_LoadPersistedProxyProfile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProfilePath
        )

        if (-not (Test-Path -LiteralPath $ProfilePath)) {
            return $null
        }

        try {
            $storedProfile = Import-Clixml -LiteralPath $ProfilePath -ErrorAction Stop
            if ($null -eq $storedProfile) {
                return $null
            }

            return $storedProfile
        }
        catch {
            _Write-StandardMessage -Message (
                "[WRN] Failed to load persisted proxy profile from '{0}': {1}. The stored profile will be cleared." -f
                $ProfilePath, $_.Exception.Message
            ) -Level WRN

            _RemovePersistedProxyProfile -ProfilePath $ProfilePath
            return $null
        }
    }

    function local:_BuildRuntimeProxyProfileState {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$StoredProfile,

            [Parameter(Mandatory = $true)]
            [string]$ProfileSource
        )

        $mode = [string]$StoredProfile.Mode
        $testUri = if ($StoredProfile.TestUri) { [uri][string]$StoredProfile.TestUri } else { $null }
        $proxyUri = if ($StoredProfile.ProxyUri) { [uri][string]$StoredProfile.ProxyUri } else { $null }
        $useDefaultProxyCredentials = [bool]$StoredProfile.UseDefaultProxyCredentials

        $proxyCredential = $null
        if ($StoredProfile.ProxyCredential -is [System.Management.Automation.PSCredential]) {
            $proxyCredential = $StoredProfile.ProxyCredential
        }
        elseif ($null -ne $StoredProfile.ProxyUserName) {
            $securePassword = ConvertTo-SecureString ([string]$StoredProfile.ProxyPassword) -AsPlainText -Force
            $proxyCredential = New-Object System.Management.Automation.PSCredential(
                [string]$StoredProfile.ProxyUserName,
                $securePassword
            )
        }

        $installPackageProvider = @{}
        $installModule = @{}
        $invokeWebRequest = @{}
        $prepareSession = $null

        switch ($mode) {
            'ManualProxy' {
                if ($null -ne $proxyUri -and $null -ne $proxyCredential) {
                    $installPackageProvider = @{
                        Proxy = $proxyUri
                        ProxyCredential = $proxyCredential
                    }

                    $installModule = @{
                        Proxy = $proxyUri
                        ProxyCredential = $proxyCredential
                    }

                    $invokeWebRequest = @{
                        Proxy = $proxyUri
                        ProxyCredential = $proxyCredential
                    }
                }
            }

            'EnvironmentProxy' {
                if ($null -ne $proxyUri) {
                    if ($useDefaultProxyCredentials -and $null -eq $proxyCredential) {
                        $invokeWebRequest = @{
                            Proxy = $proxyUri
                            ProxyUseDefaultCredentials = $true
                        }
                    }
                    else {
                        $installPackageProvider = @{
                            Proxy = $proxyUri
                        }

                        $installModule = @{
                            Proxy = $proxyUri
                        }

                        $invokeWebRequest = @{
                            Proxy = $proxyUri
                        }
                    }

                    if (-not $useDefaultProxyCredentials -and $null -ne $proxyCredential) {
                        $installPackageProvider['ProxyCredential'] = $proxyCredential
                        $installModule['ProxyCredential'] = $proxyCredential
                        $invokeWebRequest['ProxyCredential'] = $proxyCredential
                    }
                }
            }

            'LocalRelayProxy' {
                if ($null -ne $proxyUri) {
                    $installPackageProvider = @{
                        Proxy = $proxyUri
                    }

                    $installModule = @{
                        Proxy = $proxyUri
                    }

                    $invokeWebRequest = @{
                        Proxy = $proxyUri
                    }
                }
            }

            'SystemProxyDefaultCredentials' {
                if ($null -ne $proxyUri) {
                    $invokeWebRequest = @{
                        Proxy = $proxyUri
                        ProxyUseDefaultCredentials = $true
                    }
                }
            }

            'Direct' {
                if ($nativeSupportsNoProxy) {
                    $invokeWebRequest = @{
                        NoProxy = $true
                    }
                }
            }

            'NoResolvedProxyProfile' {
            }
        }

        [pscustomobject]@{
            Version = if ($StoredProfile.Version) { [int]$StoredProfile.Version } else { 1 }
            Mode = $mode
            TestUri = $testUri
            Proxy = $proxyUri
            ProxyCredential = $proxyCredential
            UseDefaultProxyCredentials = $useDefaultProxyCredentials
            InstallPackageProvider = $installPackageProvider
            InstallModule = $installModule
            InvokeWebRequest = $invokeWebRequest
            PrepareSession = $prepareSession
            Diagnostics = @($StoredProfile.Diagnostics)
            LastRefreshUtc = [string]$StoredProfile.LastRefreshUtc
            Persisted = $true
            ProfileSource = $ProfileSource
            SessionPrepared = $false
        }
    }

    function local:_SetProcessProxyProfileState {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProfilePath,

            [Parameter(Mandatory = $true)]
            [pscustomobject]$RuntimeState
        )

        $cacheTable = _GetProcessProxyProfileCacheTable
        $cacheTable[$ProfilePath] = $RuntimeState
    }

    function local:_GetProcessProxyProfileState {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProfilePath
        )

        $cacheTable = _GetProcessProxyProfileCacheTable

        if ($cacheTable.ContainsKey($ProfilePath)) {
            return $cacheTable[$ProfilePath]
        }

        return $null
    }

    function local:_EnsurePreparedRuntimeProxyProfileState {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$RuntimeState,

            [switch]$SkipSessionPreparation
        )

        if (-not $SkipSessionPreparation -and
            -not $RuntimeState.SessionPrepared -and
            $null -ne $RuntimeState.PrepareSession) {
            & $RuntimeState.PrepareSession
            $RuntimeState.SessionPrepared = $true
        }

        return $RuntimeState
    }

    function local:_NewStoredProxyProfile {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('Direct','EnvironmentProxy','LocalRelayProxy','SystemProxyDefaultCredentials','ManualProxy','NoResolvedProxyProfile')]
            [string]$Mode,

            [Parameter(Mandatory = $true)]
            [uri]$TestUri,

            [uri]$ProxyUri,

            [pscredential]$ProxyCredential,

            [bool]$UseDefaultProxyCredentials = $false,

            [string[]]$Diagnostics = @()
        )

        [pscustomobject]@{
            Version = 1
            Mode = $Mode
            TestUri = [string]$TestUri
            ProxyUri = if ($null -ne $ProxyUri) { [string]$ProxyUri } else { $null }
            ProxyCredential = $ProxyCredential
            UseDefaultProxyCredentials = $UseDefaultProxyCredentials
            LastRefreshUtc = [DateTime]::UtcNow.ToString('o')
            Diagnostics = @($Diagnostics)
        }
    }

    function local:_TestProxyProfileAccess {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri,

            [Parameter(Mandatory = $true)]
            [int]$ProbeTimeoutSec,

            [Parameter(Mandatory = $true)]
            [System.Net.IWebProxy]$ProxyObject
        )

        $response = $null

        try {
            $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($TargetUri)
            $request.Method = 'GET'
            $request.Timeout = $ProbeTimeoutSec * 1000
            $request.ReadWriteTimeout = $ProbeTimeoutSec * 1000
            $request.AllowAutoRedirect = $true
            $request.Proxy = $ProxyObject
            $request.UserAgent = 'PowerShell Invoke-WebRequestEx10 ProxyProfileProbe'

            $response = [System.Net.HttpWebResponse]$request.GetResponse()

            [pscustomobject]@{
                Success = $true
                StatusCode = [int]$response.StatusCode
                ErrorMessage = $null
            }
        }
        catch [System.Net.WebException] {
            $response = $null

            try {
                if ($_.Exception.Response -is [System.Net.HttpWebResponse]) {
                    $response = [System.Net.HttpWebResponse]$_.Exception.Response
                }
            }
            catch {
                $response = $null
            }

            if ($null -ne $response) {
                $statusCode = [int]$response.StatusCode
                $isProxyAuthenticationRequired =
                    $statusCode -eq [int][System.Net.HttpStatusCode]::ProxyAuthenticationRequired

                [pscustomobject]@{
                    Success = -not $isProxyAuthenticationRequired
                    StatusCode = $statusCode
                    ErrorMessage = if ($isProxyAuthenticationRequired) { $_.Exception.Message } else { $null }
                }
                return
            }

            [pscustomobject]@{
                Success = $false
                StatusCode = $null
                ErrorMessage = $_.Exception.Message
            }
        }
        catch {
            [pscustomobject]@{
                Success = $false
                StatusCode = $null
                ErrorMessage = $_.Exception.Message
            }
        }
        finally {
            if ($response) {
                $response.Close()
            }
        }
    }

    function local:_GetEnvironmentVariableSetting {
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$Names
        )

        foreach ($name in $Names) {
            $value = [System.Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                return [pscustomobject]@{
                    Name = $name
                    Value = [string]$value
                }
            }
        }

        return $null
    }

    function local:_GetNoProxyEntries {
        param(
            [string]$NoProxyValue
        )

        if ([string]::IsNullOrWhiteSpace($NoProxyValue)) {
            return @()
        }

        $entries = New-Object System.Collections.Generic.List[string]

        foreach ($rawEntry in ($NoProxyValue -split ',')) {
            $entry = [string]$rawEntry
            if (-not [string]::IsNullOrWhiteSpace($entry)) {
                [void]$entries.Add($entry.Trim())
            }
        }

        return @($entries.ToArray())
    }

    function local:_TestNoProxyEntryMatchesTarget {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Entry,

            [Parameter(Mandatory = $true)]
            [uri]$TargetUri
        )

        $entryText = [string]$Entry
        if ([string]::IsNullOrWhiteSpace($entryText)) {
            return $false
        }

        $entryText = $entryText.Trim()
        $targetHost = [string]$TargetUri.Host
        if ([string]::IsNullOrWhiteSpace($targetHost)) {
            return $false
        }

        $targetHostNormalized = $targetHost.Trim().Trim('.').ToLowerInvariant()
        $entryHostText = $entryText
        $entryPort = $null
        $entryHasLeadingDot = $entryText.StartsWith('.')

        if ($entryText -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
            try {
                $entryUri = [uri]$entryText
                $entryHostText = $entryUri.Host
                if (-not $entryUri.IsDefaultPort) {
                    $entryPort = [int]$entryUri.Port
                }
            }
            catch {
                return $false
            }
        }
        elseif ($entryText.StartsWith('[') -or $entryText -match '^[^:]+:\d+$') {
            try {
                $entryUri = [uri]("http://{0}" -f $entryText)
                $entryHostText = $entryUri.Host
                if (-not $entryUri.IsDefaultPort) {
                    $entryPort = [int]$entryUri.Port
                }
            }
            catch {
                return $false
            }
        }

        if ([string]::IsNullOrWhiteSpace($entryHostText)) {
            return $false
        }

        $entryHostNormalized = $entryHostText.Trim().Trim('.').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($entryHostNormalized)) {
            return $false
        }

        if ($null -ne $entryPort -and $TargetUri.Port -ne $entryPort) {
            return $false
        }

        if ($entryHasLeadingDot) {
            $entryHostNormalized = $entryHostNormalized.TrimStart('.')
            if ([string]::IsNullOrWhiteSpace($entryHostNormalized)) {
                return $false
            }

            return $targetHostNormalized.EndsWith(".{0}" -f $entryHostNormalized)
        }

        return $targetHostNormalized -eq $entryHostNormalized
    }

    function local:_ResolveEnvironmentProxySetting {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri
        )

        $diagnostics = New-Object System.Collections.Generic.List[string]

        $proxyVariableNames = switch ($TargetUri.Scheme.ToLowerInvariant()) {
            'https' { @('https_proxy','HTTPS_PROXY','all_proxy','ALL_PROXY') }
            'http' { @('http_proxy','HTTP_PROXY','all_proxy','ALL_PROXY') }
            default { @('all_proxy','ALL_PROXY') }
        }

        $proxyVariable = _GetEnvironmentVariableSetting -Names $proxyVariableNames
        if ($null -eq $proxyVariable) {
            [void]$diagnostics.Add('No applicable environment proxy variable was found for the current target URI.')
            return [pscustomobject]@{
                Resolved = $false
                ProxyUri = $null
                ProxyCredential = $null
                SourceVariableName = $null
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        $noProxyVariable = _GetEnvironmentVariableSetting -Names @('no_proxy','NO_PROXY')
        if ($null -ne $noProxyVariable) {
            foreach ($entry in (_GetNoProxyEntries -NoProxyValue $noProxyVariable.Value)) {
                if (_TestNoProxyEntryMatchesTarget -Entry $entry -TargetUri $TargetUri) {
                    [void]$diagnostics.Add(
                        "Environment proxy variable '$($proxyVariable.Name)' is bypassed for '$($TargetUri.Host)' by NO_PROXY entry '$entry'."
                    )
                    return [pscustomobject]@{
                        Resolved = $false
                        ProxyUri = $null
                        ProxyCredential = $null
                        SourceVariableName = $proxyVariable.Name
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }
            }
        }

        $proxyLiteral = ([string]$proxyVariable.Value).Trim()
        if ($proxyLiteral -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
            $proxyLiteral = "http://{0}" -f $proxyLiteral
        }

        try {
            $parsedProxyUri = [uri]$proxyLiteral
        }
        catch {
            [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' is invalid: $($_.Exception.Message)")
            return [pscustomobject]@{
                Resolved = $false
                ProxyUri = $null
                ProxyCredential = $null
                SourceVariableName = $proxyVariable.Name
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        if (-not $parsedProxyUri.IsAbsoluteUri -or [string]::IsNullOrWhiteSpace($parsedProxyUri.Host)) {
            [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' does not contain a usable absolute proxy URI.")
            return [pscustomobject]@{
                Resolved = $false
                ProxyUri = $null
                ProxyCredential = $null
                SourceVariableName = $proxyVariable.Name
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        $proxyScheme = $parsedProxyUri.Scheme.ToLowerInvariant()
        if (@('http','https') -notcontains $proxyScheme) {
            [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' uses unsupported proxy scheme '$proxyScheme'.")
            return [pscustomobject]@{
                Resolved = $false
                ProxyUri = $null
                ProxyCredential = $null
                SourceVariableName = $proxyVariable.Name
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        if (($parsedProxyUri.AbsolutePath -ne '/') -or
            -not [string]::IsNullOrWhiteSpace($parsedProxyUri.Query) -or
            -not [string]::IsNullOrWhiteSpace($parsedProxyUri.Fragment)) {
            [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' contains unsupported path, query, or fragment text after the proxy host.")
            return [pscustomobject]@{
                Resolved = $false
                ProxyUri = $null
                ProxyCredential = $null
                SourceVariableName = $proxyVariable.Name
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        $builder = New-Object System.UriBuilder($parsedProxyUri)
        $proxyCredential = $null

        if (-not [string]::IsNullOrWhiteSpace([string]$builder.UserName) -or
            -not [string]::IsNullOrWhiteSpace([string]$builder.Password)) {
            if ([string]::IsNullOrWhiteSpace([string]$builder.UserName)) {
                [void]$diagnostics.Add("Environment proxy variable '$($proxyVariable.Name)' contains proxy credentials without a user name.")
                return [pscustomobject]@{
                    Resolved = $false
                    ProxyUri = $null
                    ProxyCredential = $null
                    SourceVariableName = $proxyVariable.Name
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            try {
                $userName = [System.Uri]::UnescapeDataString([string]$builder.UserName)
                $password = [System.Uri]::UnescapeDataString([string]$builder.Password)
                $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
                $proxyCredential = New-Object System.Management.Automation.PSCredential($userName, $securePassword)
            }
            catch {
                [void]$diagnostics.Add("Environment proxy credentials from '$($proxyVariable.Name)' could not be parsed: $($_.Exception.Message)")
                return [pscustomobject]@{
                    Resolved = $false
                    ProxyUri = $null
                    ProxyCredential = $null
                    SourceVariableName = $proxyVariable.Name
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            $builder.UserName = ''
            $builder.Password = ''
        }

        $proxyUri = $builder.Uri
        [void]$diagnostics.Add("Environment proxy settings were resolved from '$($proxyVariable.Name)' as '$($proxyUri.AbsoluteUri)'.")

        return [pscustomobject]@{
            Resolved = $true
            ProxyUri = $proxyUri
            ProxyCredential = $proxyCredential
            SourceVariableName = $proxyVariable.Name
            Diagnostics = @($diagnostics.ToArray())
        }
    }

    function local:_TryResolveEnvironmentProxy {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri,

            [Parameter(Mandatory = $true)]
            [int]$ProbeTimeoutSec
        )

        $environmentProxy = _ResolveEnvironmentProxySetting -TargetUri $TargetUri
        $diagnostics = New-Object System.Collections.Generic.List[string]

        foreach ($message in $environmentProxy.Diagnostics) {
            [void]$diagnostics.Add($message)
        }

        if (-not $environmentProxy.Resolved -or $null -eq $environmentProxy.ProxyUri) {
            return [pscustomobject]@{
                Success = $false
                ProxyUri = $null
                ProxyCredential = $null
                UseDefaultProxyCredentials = $false
                StatusCode = $null
                Diagnostics = @($diagnostics.ToArray())
            }
        }

        try {
            $proxyObject = New-Object System.Net.WebProxy($environmentProxy.ProxyUri.AbsoluteUri, $true)
            if ($null -ne $environmentProxy.ProxyCredential) {
                $proxyObject.Credentials = $environmentProxy.ProxyCredential.GetNetworkCredential()
            }

            $proxyTest = _TestProxyProfileAccess -TargetUri $TargetUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $proxyObject

            if ($proxyTest.Success) {
                return [pscustomobject]@{
                    Success = $true
                    ProxyUri = $environmentProxy.ProxyUri
                    ProxyCredential = $environmentProxy.ProxyCredential
                    UseDefaultProxyCredentials = $false
                    StatusCode = $proxyTest.StatusCode
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            [void]$diagnostics.Add("Environment proxy '$($environmentProxy.ProxyUri.AbsoluteUri)' failed HTTP probe: $($proxyTest.ErrorMessage)")

            $canRetryWithDefaultProxyCredentials =
                ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) -and
                ($null -eq $environmentProxy.ProxyCredential)

            if ($canRetryWithDefaultProxyCredentials -and $proxyTest.StatusCode -eq [int][System.Net.HttpStatusCode]::ProxyAuthenticationRequired) {
                [void]$diagnostics.Add("Environment proxy '$($environmentProxy.ProxyUri.AbsoluteUri)' requested proxy authentication. Retrying once with default proxy credentials.")

                $defaultCredentialProxy = New-Object System.Net.WebProxy($environmentProxy.ProxyUri.AbsoluteUri, $true)
                $defaultCredentialProxy.UseDefaultCredentials = $true

                $defaultCredentialResult = _TestProxyProfileAccess -TargetUri $TargetUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $defaultCredentialProxy
                if ($defaultCredentialResult.Success) {
                    [void]$diagnostics.Add("Environment proxy '$($environmentProxy.ProxyUri.AbsoluteUri)' succeeded when retried with default proxy credentials.")
                    return [pscustomobject]@{
                        Success = $true
                        ProxyUri = $environmentProxy.ProxyUri
                        ProxyCredential = $null
                        UseDefaultProxyCredentials = $true
                        StatusCode = $defaultCredentialResult.StatusCode
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                [void]$diagnostics.Add("Environment proxy '$($environmentProxy.ProxyUri.AbsoluteUri)' still failed after retry with default proxy credentials: $($defaultCredentialResult.ErrorMessage)")
            }
        }
        catch {
            [void]$diagnostics.Add("Environment proxy '$($environmentProxy.ProxyUri.AbsoluteUri)' check failed: $($_.Exception.Message)")
        }

        return [pscustomobject]@{
            Success = $false
            ProxyUri = $environmentProxy.ProxyUri
            ProxyCredential = $environmentProxy.ProxyCredential
            UseDefaultProxyCredentials = $false
            StatusCode = $null
            Diagnostics = @($diagnostics.ToArray())
        }
    }

    function local:_GetLocalRelayProxyCandidates {
        return @(
            [uri]'http://localhost:3128',
            [uri]'http://127.0.0.1:3128'
        )
    }

    function local:_TestLoopbackPortOpen {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$ProxyUri,

            [Parameter()]
            [ValidateRange(50, 5000)]
            [int]$ConnectTimeoutMilliseconds = 400
        )

        $hostName = $ProxyUri.Host
        if (@('127.0.0.1', 'localhost', '::1') -notcontains $hostName) {
            return $false
        }

        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $client.BeginConnect($hostName, $ProxyUri.Port, $null, $null)

            if (-not $asyncResult.AsyncWaitHandle.WaitOne($ConnectTimeoutMilliseconds, $false)) {
                return $false
            }

            [void]$client.EndConnect($asyncResult)
            return $client.Connected
        }
        catch {
            return $false
        }
        finally {
            if ($client) {
                $client.Close()
            }
        }
    }

    function local:_TryResolveLocalRelayProxy {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri,

            [Parameter(Mandatory = $true)]
            [int]$ProbeTimeoutSec
        )

        $diagnostics = New-Object System.Collections.Generic.List[string]

        foreach ($candidate in (_GetLocalRelayProxyCandidates)) {
            if (-not (_TestLoopbackPortOpen -ProxyUri $candidate)) {
                [void]$diagnostics.Add("Local relay proxy candidate '$($candidate.AbsoluteUri)' is not listening on loopback.")
                continue
            }

            try {
                $proxyObject = New-Object System.Net.WebProxy($candidate.AbsoluteUri, $true)
                $proxyTest = _TestProxyProfileAccess -TargetUri $TargetUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $proxyObject

                if ($proxyTest.Success) {
                    return [pscustomobject]@{
                        Success = $true
                        ProxyUri = $candidate
                        StatusCode = $proxyTest.StatusCode
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                [void]$diagnostics.Add("Local relay proxy candidate '$($candidate.AbsoluteUri)' failed HTTP probe: $($proxyTest.ErrorMessage)")
            }
            catch {
                [void]$diagnostics.Add("Local relay proxy candidate '$($candidate.AbsoluteUri)' check failed: $($_.Exception.Message)")
            }
        }

        return [pscustomobject]@{
            Success = $false
            ProxyUri = $null
            StatusCode = $null
            Diagnostics = @($diagnostics.ToArray())
        }
    }

    function local:_TestPersistedProxyProfile {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$StoredProfile,

            [Parameter(Mandatory = $true)]
            [uri]$ValidationUri,

            [Parameter(Mandatory = $true)]
            [int]$ProbeTimeoutSec
        )

        $diagnostics = New-Object System.Collections.Generic.List[string]
        $mode = [string]$StoredProfile.Mode

        switch ($mode) {
            'Direct' {
                $noProxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
                $direct = _TestProxyProfileAccess -TargetUri $ValidationUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $noProxy

                if ($direct.Success) {
                    [void]$diagnostics.Add("Persisted direct profile validation succeeded with status code $($direct.StatusCode).")
                    return [pscustomobject]@{
                        Success = $true
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                [void]$diagnostics.Add("Persisted direct profile validation failed: $($direct.ErrorMessage)")
                return [pscustomobject]@{
                    Success = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            'EnvironmentProxy' {
                if (-not $StoredProfile.ProxyUri) {
                    [void]$diagnostics.Add('Persisted environment proxy profile is missing ProxyUri.')
                    return [pscustomobject]@{
                        Success = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                $proxyCredential = $null
                if ($StoredProfile.ProxyCredential -is [System.Management.Automation.PSCredential]) {
                    $proxyCredential = [System.Management.Automation.PSCredential]$StoredProfile.ProxyCredential
                }
                elseif ($null -ne $StoredProfile.ProxyUserName) {
                    try {
                        $securePassword = ConvertTo-SecureString ([string]$StoredProfile.ProxyPassword) -AsPlainText -Force
                        $proxyCredential = New-Object System.Management.Automation.PSCredential(
                            [string]$StoredProfile.ProxyUserName,
                            $securePassword
                        )
                    }
                    catch {
                        $proxyCredential = $null
                    }
                }

                try {
                    $proxyUri = [uri][string]$StoredProfile.ProxyUri
                    $environmentProxy = New-Object System.Net.WebProxy($proxyUri.AbsoluteUri, $true)
                    if ([bool]$StoredProfile.UseDefaultProxyCredentials -and $null -eq $proxyCredential) {
                        $environmentProxy.UseDefaultCredentials = $true
                    }
                    elseif ($null -ne $proxyCredential) {
                        $environmentProxy.Credentials = $proxyCredential.GetNetworkCredential()
                    }

                    $result = _TestProxyProfileAccess -TargetUri $ValidationUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $environmentProxy

                    if ($result.Success) {
                        [void]$diagnostics.Add("Persisted environment proxy validation succeeded with status code $($result.StatusCode) via '$($proxyUri.AbsoluteUri)'.")
                        return [pscustomobject]@{
                            Success = $true
                            Diagnostics = @($diagnostics.ToArray())
                        }
                    }

                    [void]$diagnostics.Add("Persisted environment proxy validation failed: $($result.ErrorMessage)")
                }
                catch {
                    [void]$diagnostics.Add("Persisted environment proxy validation check failed: $($_.Exception.Message)")
                }

                return [pscustomobject]@{
                    Success = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            'LocalRelayProxy' {
                if (-not $StoredProfile.ProxyUri) {
                    [void]$diagnostics.Add('Persisted local relay proxy profile is missing ProxyUri.')
                    return [pscustomobject]@{
                        Success = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                try {
                    $proxyUri = [uri][string]$StoredProfile.ProxyUri
                }
                catch {
                    [void]$diagnostics.Add("Persisted local relay proxy URI could not be parsed: $($_.Exception.Message)")
                    return [pscustomobject]@{
                        Success = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                if (-not (_TestLoopbackPortOpen -ProxyUri $proxyUri)) {
                    [void]$diagnostics.Add("Persisted local relay proxy '$($proxyUri.AbsoluteUri)' is not listening on loopback.")
                    return [pscustomobject]@{
                        Success = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                try {
                    $proxyObject = New-Object System.Net.WebProxy($proxyUri.AbsoluteUri, $true)
                    $result = _TestProxyProfileAccess -TargetUri $ValidationUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $proxyObject

                    if ($result.Success) {
                        [void]$diagnostics.Add("Persisted local relay proxy validation succeeded with status code $($result.StatusCode) via '$($proxyUri.AbsoluteUri)'.")
                        return [pscustomobject]@{
                            Success = $true
                            Diagnostics = @($diagnostics.ToArray())
                        }
                    }

                    [void]$diagnostics.Add("Persisted local relay proxy validation failed: $($result.ErrorMessage)")
                }
                catch {
                    [void]$diagnostics.Add("Persisted local relay proxy validation check failed: $($_.Exception.Message)")
                }

                return [pscustomobject]@{
                    Success = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            'SystemProxyDefaultCredentials' {
                try {
                    $systemProxy = [System.Net.WebRequest]::GetSystemWebProxy()
                    $resolvedProxy = $systemProxy.GetProxy($ValidationUri)

                    if ($systemProxy.IsBypassed($ValidationUri) -or
                        -not $resolvedProxy -or
                        $resolvedProxy.AbsoluteUri -eq $ValidationUri.AbsoluteUri) {
                        [void]$diagnostics.Add('Persisted system proxy profile validation found no distinct system proxy for the current test URI.')
                        return [pscustomobject]@{
                            Success = $false
                            Diagnostics = @($diagnostics.ToArray())
                        }
                    }

                    $systemProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                    $result = _TestProxyProfileAccess -TargetUri $ValidationUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $systemProxy

                    if ($result.Success) {
                        [void]$diagnostics.Add("Persisted system proxy validation succeeded with status code $($result.StatusCode) via '$($resolvedProxy.AbsoluteUri)'.")
                        return [pscustomobject]@{
                            Success = $true
                            Diagnostics = @($diagnostics.ToArray())
                        }
                    }

                    [void]$diagnostics.Add("Persisted system proxy validation failed: $($result.ErrorMessage)")
                }
                catch {
                    [void]$diagnostics.Add("Persisted system proxy validation check failed: $($_.Exception.Message)")
                }

                return [pscustomobject]@{
                    Success = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            'ManualProxy' {
                if (-not $StoredProfile.ProxyUri) {
                    [void]$diagnostics.Add('Persisted manual proxy profile is missing ProxyUri.')
                    return [pscustomobject]@{
                        Success = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                $proxyCredential = $null
                if ($StoredProfile.ProxyCredential -is [System.Management.Automation.PSCredential]) {
                    $proxyCredential = [System.Management.Automation.PSCredential]$StoredProfile.ProxyCredential
                }
                elseif ($null -ne $StoredProfile.ProxyUserName) {
                    try {
                        $securePassword = ConvertTo-SecureString ([string]$StoredProfile.ProxyPassword) -AsPlainText -Force
                        $proxyCredential = New-Object System.Management.Automation.PSCredential(
                            [string]$StoredProfile.ProxyUserName,
                            $securePassword
                        )
                    }
                    catch {
                        $proxyCredential = $null
                    }
                }

                if ($null -eq $proxyCredential) {
                    [void]$diagnostics.Add('Persisted manual proxy profile is missing a usable PSCredential.')
                    return [pscustomobject]@{
                        Success = $false
                        Diagnostics = @($diagnostics.ToArray())
                    }
                }

                try {
                    $proxyUri = [uri][string]$StoredProfile.ProxyUri
                    $manualProxy = New-Object System.Net.WebProxy($proxyUri.AbsoluteUri, $true)
                    $manualProxy.Credentials = $proxyCredential.GetNetworkCredential()

                    $result = _TestProxyProfileAccess -TargetUri $ValidationUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $manualProxy

                    if ($result.Success) {
                        [void]$diagnostics.Add("Persisted manual proxy validation succeeded with status code $($result.StatusCode) via '$($proxyUri.AbsoluteUri)'.")
                        return [pscustomobject]@{
                            Success = $true
                            Diagnostics = @($diagnostics.ToArray())
                        }
                    }

                    [void]$diagnostics.Add("Persisted manual proxy validation failed: $($result.ErrorMessage)")
                }
                catch {
                    [void]$diagnostics.Add("Persisted manual proxy validation check failed: $($_.Exception.Message)")
                }

                return [pscustomobject]@{
                    Success = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            'NoResolvedProxyProfile' {
                [void]$diagnostics.Add('Persisted NoResolvedProxyProfile entries are not considered reusable.')
                return [pscustomobject]@{
                    Success = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }

            default {
                [void]$diagnostics.Add("Persisted profile mode '$mode' is not supported.")
                return [pscustomobject]@{
                    Success = $false
                    Diagnostics = @($diagnostics.ToArray())
                }
            }
        }
    }

    function local:_GetManualProxyEntry {
        param(
            [string]$DefaultProxy
        )

        Add-Type -AssemblyName System.Windows.Forms,System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Proxy settings'
        $form.StartPosition = 'CenterScreen'
        $form.TopMost = $true
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.ClientSize = New-Object System.Drawing.Size(400,170)
        $form.Font = New-Object System.Drawing.Font('Segoe UI',9)

        $lbl1 = New-Object System.Windows.Forms.Label
        $lbl1.Text = 'Proxy address'
        $lbl1.Location = New-Object System.Drawing.Point(15,21)
        $lbl1.AutoSize = $true
        [void]$form.Controls.Add($lbl1)

        $txtProxy = New-Object System.Windows.Forms.TextBox
        $txtProxy.Location = New-Object System.Drawing.Point(120,18)
        $txtProxy.Size = New-Object System.Drawing.Size(260,23)
        $txtProxy.Text = $DefaultProxy
        [void]$form.Controls.Add($txtProxy)

        $lbl2 = New-Object System.Windows.Forms.Label
        $lbl2.Text = 'Username'
        $lbl2.Location = New-Object System.Drawing.Point(15,55)
        $lbl2.AutoSize = $true
        [void]$form.Controls.Add($lbl2)

        $txtUser = New-Object System.Windows.Forms.TextBox
        $txtUser.Location = New-Object System.Drawing.Point(120,52)
        $txtUser.Size = New-Object System.Drawing.Size(260,23)
        [void]$form.Controls.Add($txtUser)

        $lbl3 = New-Object System.Windows.Forms.Label
        $lbl3.Text = 'Password'
        $lbl3.Location = New-Object System.Drawing.Point(15,89)
        $lbl3.AutoSize = $true
        [void]$form.Controls.Add($lbl3)

        $txtPass = New-Object System.Windows.Forms.TextBox
        $txtPass.Location = New-Object System.Drawing.Point(120,86)
        $txtPass.Size = New-Object System.Drawing.Size(260,23)
        $txtPass.UseSystemPasswordChar = $true
        [void]$form.Controls.Add($txtPass)

        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = 'OK'
        $ok.Location = New-Object System.Drawing.Point(224,124)
        $ok.Size = New-Object System.Drawing.Size(75,28)
        $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
        [void]$form.Controls.Add($ok)

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = 'Cancel'
        $cancel.Location = New-Object System.Drawing.Point(305,124)
        $cancel.Size = New-Object System.Drawing.Size(75,28)
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        [void]$form.Controls.Add($cancel)

        $form.AcceptButton = $ok
        $form.CancelButton = $cancel

        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            return $null
        }

        [pscustomobject]@{
            ProxyUri = [uri]$txtProxy.Text
            ProxyCredential = New-Object System.Management.Automation.PSCredential(
                $txtUser.Text,
                (ConvertTo-SecureString $txtPass.Text -AsPlainText -Force)
            )
        }
    }

    function local:_GetDownloadLocalState {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

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
        param(
            [Parameter(Mandatory = $true)]
            [System.Net.HttpWebResponse]$Response
        )

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
            StatusCode = $statusCode
            ContentLength = $contentLength
            AcceptRanges = $acceptRanges
            ETag = $etag
            LastModified = $lastModified
            ContentRange = $contentRange
            ContentRangeStart = $contentRangeStart
            ContentRangeTotalLength = $contentRangeTotalLength
        }
    }

    function local:_OpenDownloadFileStream {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,

            [Parameter()]
            [System.IO.FileMode]$FileMode = [System.IO.FileMode]::Create
        )

        return [System.IO.File]::Open(
            $Path,
            $FileMode,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    }

    function local:_GetResolvedDownloadPath {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

        try {
            return [System.IO.Path]::GetFullPath($Path)
        }
        catch {
            return $Path
        }
    }

    function local:_GetDownloadSidecarHash {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri,

            [Parameter(Mandatory = $true)]
            [string]$OutFilePath
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
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri,

            [Parameter(Mandatory = $true)]
            [string]$OutFilePath
        )

        $hash = _GetDownloadSidecarHash -TargetUri $TargetUri -OutFilePath $OutFilePath
        return ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("InvokeWebRequestEx_{0}.lock" -f $hash)))
    }

    function local:_GetResumeMetadataPath {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri,

            [Parameter(Mandatory = $true)]
            [string]$OutFilePath
        )

        $hash = _GetDownloadSidecarHash -TargetUri $TargetUri -OutFilePath $OutFilePath
        return ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("InvokeWebRequestEx_{0}.resume" -f $hash)))
    }

    function local:_ReadJsonFile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

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
            [Parameter(Mandatory = $true)]
            [string]$Path,

            [Parameter(Mandatory = $true)]
            [object]$Data
        )

        $json = $Data | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
    }

    function local:_RemoveFileIfExists {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

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
        param(
            [Parameter(Mandatory = $true)]
            [string]$LockPath
        )

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
            [Parameter(Mandatory = $true)]
            [string]$Path,

            [Parameter(Mandatory = $true)]
            [ValidateSet('SHA256')]
            [string]$Algorithm
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

    function local:_ResolveCorporateProxyProfile {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri,

            [Parameter(Mandatory = $true)]
            [int]$ProbeTimeoutSec,

            [Parameter(Mandatory = $true)]
            [string]$ProfilePath,

            [Parameter(Mandatory = $true)]
            [string]$ManualProxyDefault,

            [switch]$SkipManualPrompt,

            [switch]$SkipSessionPreparation,

            [switch]$ForceRefresh,

            [switch]$ClearProfile
        )

        $probePreviousCertificateValidationCallback = $null
        $probeSkipCertificateCheckEnabled = $false

        try {
            try {
                $tls12 = [System.Net.SecurityProtocolType]::Tls12
                $currentProtocols = [System.Net.ServicePointManager]::SecurityProtocol

                if (($currentProtocols -band $tls12) -ne $tls12) {
                    [System.Net.ServicePointManager]::SecurityProtocol = $currentProtocols -bor $tls12
                }
            }
            catch {
            }

            if ($effectiveSkipCertificateCheck) {
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

                $probePreviousCertificateValidationCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $acceptAllCallback
                $probeSkipCertificateCheckEnabled = $true
            }

            $isInteractive = [System.Environment]::UserInteractive

            if ($ClearProfile) {
                _RemovePersistedProxyProfile -ProfilePath $ProfilePath
            }

            $persistedProfileValidationDiagnostics = @()

            if (-not $ForceRefresh) {
                $processCached = _GetProcessProxyProfileState -ProfilePath $ProfilePath
                if ($null -ne $processCached) {
                    $processCached = _EnsurePreparedRuntimeProxyProfileState -RuntimeState $processCached -SkipSessionPreparation:$SkipSessionPreparation
                    return $processCached
                }

                $storedProfile = _LoadPersistedProxyProfile -ProfilePath $ProfilePath
                if ($null -ne $storedProfile) {
                    $persistedValidation = _TestPersistedProxyProfile `
                        -StoredProfile $storedProfile `
                        -ValidationUri $TargetUri `
                        -ProbeTimeoutSec $ProbeTimeoutSec

                    if ($persistedValidation.Success) {
                        $runtimeState = _BuildRuntimeProxyProfileState -StoredProfile $storedProfile -ProfileSource 'ProfileFile'
                        $runtimeState = _EnsurePreparedRuntimeProxyProfileState -RuntimeState $runtimeState -SkipSessionPreparation:$SkipSessionPreparation
                        _SetProcessProxyProfileState -ProfilePath $ProfilePath -RuntimeState $runtimeState
                        return $runtimeState
                    }

                    $persistedProfileValidationDiagnostics = @($persistedValidation.Diagnostics)

                    foreach ($message in $persistedProfileValidationDiagnostics) {
                        _Write-StandardMessage -Message (
                            "[WRN] {0}" -f $message
                        ) -Level WRN
                    }

                    _Write-StandardMessage -Message (
                        "[WRN] Persisted proxy profile from '{0}' failed validation and will be cleared before fresh detection." -f $ProfilePath
                    ) -Level WRN

                    _RemovePersistedProxyProfile -ProfilePath $ProfilePath
                }
            }

            $diagnostics = New-Object System.Collections.Generic.List[string]
            foreach ($message in $persistedProfileValidationDiagnostics) {
                [void]$diagnostics.Add($message)
            }

            # 1) True direct probe.
            $noProxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
            $directTest = _TestProxyProfileAccess -TargetUri $TargetUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $noProxy

            if ($directTest.Success) {
                $stored = _NewStoredProxyProfile `
                    -Mode 'Direct' `
                    -TestUri $TargetUri `
                    -Diagnostics @(
                        $diagnostics.ToArray() +
                        "Direct probe succeeded with status code $($directTest.StatusCode)."
                    )

                _SavePersistedProxyProfile -StoredProfile $stored -ProfilePath $ProfilePath

                $runtimeState = _BuildRuntimeProxyProfileState -StoredProfile $stored -ProfileSource 'FreshDetection'
                $runtimeState = _EnsurePreparedRuntimeProxyProfileState -RuntimeState $runtimeState -SkipSessionPreparation:$SkipSessionPreparation
                _SetProcessProxyProfileState -ProfilePath $ProfilePath -RuntimeState $runtimeState
                return $runtimeState
            }

            [void]$diagnostics.Add("Direct probe failed: $($directTest.ErrorMessage)")

            # 2) Environment proxy from process environment variables.
            $environmentProxyResult = _TryResolveEnvironmentProxy -TargetUri $TargetUri -ProbeTimeoutSec $ProbeTimeoutSec

            foreach ($message in $environmentProxyResult.Diagnostics) {
                [void]$diagnostics.Add($message)
            }

            if ($environmentProxyResult.Success -and $null -ne $environmentProxyResult.ProxyUri) {
                $stored = _NewStoredProxyProfile `
                    -Mode 'EnvironmentProxy' `
                    -TestUri $TargetUri `
                    -ProxyUri $environmentProxyResult.ProxyUri `
                    -ProxyCredential $environmentProxyResult.ProxyCredential `
                    -UseDefaultProxyCredentials $environmentProxyResult.UseDefaultProxyCredentials `
                    -Diagnostics @(
                        $diagnostics.ToArray() +
                        "Environment proxy probe succeeded with status code $($environmentProxyResult.StatusCode) via '$($environmentProxyResult.ProxyUri.AbsoluteUri)'."
                    )

                _SavePersistedProxyProfile -StoredProfile $stored -ProfilePath $ProfilePath

                $runtimeState = _BuildRuntimeProxyProfileState -StoredProfile $stored -ProfileSource 'FreshDetection'
                $runtimeState = _EnsurePreparedRuntimeProxyProfileState -RuntimeState $runtimeState -SkipSessionPreparation:$SkipSessionPreparation
                _SetProcessProxyProfileState -ProfilePath $ProfilePath -RuntimeState $runtimeState
                return $runtimeState
            }

            # 3) Local relay proxy on loopback.
            $localRelayResult = _TryResolveLocalRelayProxy -TargetUri $TargetUri -ProbeTimeoutSec $ProbeTimeoutSec

            foreach ($message in $localRelayResult.Diagnostics) {
                [void]$diagnostics.Add($message)
            }

            if ($localRelayResult.Success -and $null -ne $localRelayResult.ProxyUri) {
                $stored = _NewStoredProxyProfile `
                    -Mode 'LocalRelayProxy' `
                    -TestUri $TargetUri `
                    -ProxyUri $localRelayResult.ProxyUri `
                    -Diagnostics @(
                        $diagnostics.ToArray() +
                        "Local relay proxy probe succeeded with status code $($localRelayResult.StatusCode) via '$($localRelayResult.ProxyUri.AbsoluteUri)'."
                    )

                _SavePersistedProxyProfile -StoredProfile $stored -ProfilePath $ProfilePath

                $runtimeState = _BuildRuntimeProxyProfileState -StoredProfile $stored -ProfileSource 'FreshDetection'
                $runtimeState = _EnsurePreparedRuntimeProxyProfileState -RuntimeState $runtimeState -SkipSessionPreparation:$SkipSessionPreparation
                _SetProcessProxyProfileState -ProfilePath $ProfilePath -RuntimeState $runtimeState
                return $runtimeState
            }

            # 4) System proxy + default credentials.
            try {
                $systemProxy = [System.Net.WebRequest]::GetSystemWebProxy()
                $resolvedProxy = $systemProxy.GetProxy($TargetUri)

                if (-not $systemProxy.IsBypassed($TargetUri) -and
                    $null -ne $resolvedProxy -and
                    $resolvedProxy.AbsoluteUri -ne $TargetUri.AbsoluteUri) {

                    $systemProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                    $systemTest = _TestProxyProfileAccess -TargetUri $TargetUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $systemProxy

                    if ($systemTest.Success) {
                        $stored = _NewStoredProxyProfile `
                            -Mode 'SystemProxyDefaultCredentials' `
                            -TestUri $TargetUri `
                            -ProxyUri $resolvedProxy `
                            -UseDefaultProxyCredentials $true `
                            -Diagnostics @(
                                $diagnostics.ToArray() +
                                "System proxy probe succeeded with status code $($systemTest.StatusCode)."
                            )

                        _SavePersistedProxyProfile -StoredProfile $stored -ProfilePath $ProfilePath

                        $runtimeState = _BuildRuntimeProxyProfileState -StoredProfile $stored -ProfileSource 'FreshDetection'
                        $runtimeState = _EnsurePreparedRuntimeProxyProfileState -RuntimeState $runtimeState -SkipSessionPreparation:$SkipSessionPreparation
                        _SetProcessProxyProfileState -ProfilePath $ProfilePath -RuntimeState $runtimeState
                        return $runtimeState
                    }

                    [void]$diagnostics.Add("System proxy probe failed: $($systemTest.ErrorMessage)")
                }
                else {
                    [void]$diagnostics.Add('No distinct system proxy was resolved for the test URI.')
                }
            }
            catch {
                [void]$diagnostics.Add("System proxy discovery failed: $($_.Exception.Message)")
            }

            # 5) Manual proxy prompt.
            if (-not $SkipManualPrompt) {
                if (-not $isInteractive) {
                    [void]$diagnostics.Add('Manual proxy entry is required, but the current session is non-interactive.')
                    _RemovePersistedProxyProfile -ProfilePath $ProfilePath

                    throw "Manual proxy entry is required for '$($TargetUri.AbsoluteUri)', but the current session is non-interactive. Provide proxy parameters explicitly or pre-stage a usable persisted proxy profile file."
                }

                try {
                    $manual = _GetManualProxyEntry -DefaultProxy $ManualProxyDefault
                }
                catch {
                    $manual = $null
                    [void]$diagnostics.Add("Manual proxy prompt failed: $($_.Exception.Message)")
                }

                if ($manual) {
                    try {
                        $manualProxy = New-Object System.Net.WebProxy($manual.ProxyUri.AbsoluteUri, $true)
                        $manualProxy.Credentials = $manual.ProxyCredential.GetNetworkCredential()

                        $manualTest = _TestProxyProfileAccess -TargetUri $TargetUri -ProbeTimeoutSec $ProbeTimeoutSec -ProxyObject $manualProxy

                        if ($manualTest.Success) {
                            $stored = _NewStoredProxyProfile `
                                -Mode 'ManualProxy' `
                                -TestUri $TargetUri `
                                -ProxyUri $manual.ProxyUri `
                                -ProxyCredential $manual.ProxyCredential `
                                -Diagnostics @(
                                    $diagnostics.ToArray() +
                                    "Manual proxy probe succeeded with status code $($manualTest.StatusCode)."
                                )

                            _SavePersistedProxyProfile -StoredProfile $stored -ProfilePath $ProfilePath

                            $runtimeState = _BuildRuntimeProxyProfileState -StoredProfile $stored -ProfileSource 'FreshDetection'
                            $runtimeState = _EnsurePreparedRuntimeProxyProfileState -RuntimeState $runtimeState -SkipSessionPreparation:$SkipSessionPreparation
                            _SetProcessProxyProfileState -ProfilePath $ProfilePath -RuntimeState $runtimeState
                            return $runtimeState
                        }

                        [void]$diagnostics.Add("Manual proxy probe failed: $($manualTest.ErrorMessage)")
                    }
                    catch {
                        [void]$diagnostics.Add("Manual proxy handling failed: $($_.Exception.Message)")
                    }
                }
                else {
                    [void]$diagnostics.Add('Manual proxy entry was cancelled.')
                }
            }
            else {
                [void]$diagnostics.Add('Manual proxy prompt was skipped by caller.')
            }

            _RemovePersistedProxyProfile -ProfilePath $ProfilePath

            $noResolvedProxyProfileStored = _NewStoredProxyProfile `
                -Mode 'NoResolvedProxyProfile' `
                -TestUri $TargetUri `
                -Diagnostics $diagnostics.ToArray()

            $noResolvedProxyProfileState = _BuildRuntimeProxyProfileState -StoredProfile $noResolvedProxyProfileStored -ProfileSource 'FreshDetection'
            $noResolvedProxyProfileState.Persisted = $false
            _SetProcessProxyProfileState -ProfilePath $ProfilePath -RuntimeState $noResolvedProxyProfileState

            return $noResolvedProxyProfileState
        }
        finally {
            if ($probeSkipCertificateCheckEnabled) {
                if ($null -eq $probePreviousCertificateValidationCallback) {
                    [System.Net.ServicePointManager]::ServerCertificateValidationCallback =
                        [System.Net.Security.RemoteCertificateValidationCallback]$null
                }
                else {
                    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $probePreviousCertificateValidationCallback
                }
            }
        }
    }

    function local:_ApplyProxyProfileToCallParams {
        param(
            [Parameter(Mandatory = $true)]
            [hashtable]$CallParams,

            [Parameter(Mandatory = $true)]
            [pscustomobject]$ProxyProfile
        )

        foreach ($key in @('Proxy', 'ProxyCredential', 'ProxyUseDefaultCredentials', 'NoProxy')) {
            if ($CallParams.ContainsKey($key)) {
                [void]$CallParams.Remove($key)
            }
        }

        foreach ($entry in $ProxyProfile.InvokeWebRequest.GetEnumerator()) {
            $CallParams[$entry.Key] = $entry.Value
        }
    }

    $isWindowsEnv = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if (-not $isWindowsEnv) {
        throw "Invoke-WebRequestEx10 is intended for Windows PowerShell 5.1 and PowerShell 7+ on Windows."
    }

    $uriDisplay = _UriDisplayShortener -TargetUri $Uri

    _Write-StandardMessage -Message ("[STATUS] Initializing Invoke-WebRequestEx10 for '{0}'." -f $uriDisplay) -Level INF

    $effectiveMethod = if ($PSBoundParameters.ContainsKey('Method') -and $null -ne $Method) {
        $Method.ToString().ToUpperInvariant()
    }
    else {
        'GET'
    }

    $nativeInvokeWebRequestCommand = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
    $nativeSupportsSkipCertificateCheck =
        ($null -ne $nativeInvokeWebRequestCommand) -and
        $nativeInvokeWebRequestCommand.Parameters.ContainsKey('SkipCertificateCheck')
    $nativeSupportsNoProxy =
        ($null -ne $nativeInvokeWebRequestCommand) -and
        $nativeInvokeWebRequestCommand.Parameters.ContainsKey('NoProxy')
    $explicitSkipCertificateCheckSupplied = $PSBoundParameters.ContainsKey('SkipCertificateCheck')
    $explicitEnforceCertificateCheckSupplied = $PSBoundParameters.ContainsKey('EnforceCertificateCheck')

    $effectiveSkipCertificateCheck = if ($explicitSkipCertificateCheckSupplied) {
        [bool]$SkipCertificateCheck
    }
    elseif ($explicitEnforceCertificateCheckSupplied) {
        -not [bool]$EnforceCertificateCheck
    }
    else {
        $true
    }

    $explicitCredentialSupplied = $PSBoundParameters.ContainsKey('Credential') -and $null -ne $Credential
    $explicitUseDefaultCredentialsSupplied = $PSBoundParameters.ContainsKey('UseDefaultCredentials')
    $autoUseDefaultCredentialsAllowed =
        (-not $DisableAutoUseDefaultCredentials) -and
        (-not $explicitCredentialSupplied) -and
        (-not $explicitUseDefaultCredentialsSupplied)

    $autoUpgradedToDefaultCredentials = $false
    $autoUseDefaultCredentialsGuardInfo = $null
    $autoUseDefaultCredentialsGuardInfoResolved = $false
    $manualProxyProfileAutoRefreshAttempted = $false

    $callParams = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        switch ($entry.Key) {
            'SkipCertificateCheck' { continue }
            'EnforceCertificateCheck' { continue }
            'DisableAutoUseDefaultCredentials' { continue }
            'RetryCount' { continue }
            'RetryDelayMilliseconds' { continue }
            'TotalTimeoutSec' { continue }
            'BufferSizeBytes' { continue }
            'ProgressIntervalPercent' { continue }
            'ProgressIntervalBytes' { continue }
            'UseStreamingDownload' { continue }
            'DisableResumeStreamingDownload' { continue }
            'DeletePartialStreamingDownloadOnFailure' { continue }
            'DeleteStreamingFragmentsOnFailure' { continue }
            'RequiredStreamingHashType' { continue }
            'RequiredStreamingHash' { continue }
            'ProxyProfilePath' { continue }
            'DefaultManualProxy' { continue }
            'SkipProxyManualPrompt' { continue }
            'SkipProxySessionPreparation' { continue }
            'ForceRefreshProxyProfile' { continue }
            'ClearProxyProfile' { continue }
            default { $callParams[$entry.Key] = $entry.Value }
        }
    }

    if ($nativeSupportsSkipCertificateCheck -and $effectiveSkipCertificateCheck) {
        $callParams['SkipCertificateCheck'] = $true
    }

    $streamingHashValidationRequested =
        $PSBoundParameters.ContainsKey('RequiredStreamingHashType') -or
        $PSBoundParameters.ContainsKey('RequiredStreamingHash')

    if ($streamingHashValidationRequested) {
        if (-not $PSBoundParameters.ContainsKey('RequiredStreamingHashType') -or [string]::IsNullOrWhiteSpace($RequiredStreamingHashType)) {
            _Write-StandardMessage -Message ("[ERR] Parameter 'RequiredStreamingHashType' is required when 'RequiredStreamingHash' is supplied.") -Level ERR
            throw "RequiredStreamingHashType is required when RequiredStreamingHash is supplied."
        }

        if (-not $PSBoundParameters.ContainsKey('RequiredStreamingHash') -or [string]::IsNullOrWhiteSpace($RequiredStreamingHash)) {
            _Write-StandardMessage -Message ("[ERR] Parameter 'RequiredStreamingHash' is required when 'RequiredStreamingHashType' is supplied.") -Level ERR
            throw "RequiredStreamingHash is required when RequiredStreamingHashType is supplied."
        }

        $RequiredStreamingHash = $RequiredStreamingHash.Trim().ToUpperInvariant()
    }

    try {
        $tls12 = [System.Net.SecurityProtocolType]::Tls12
        $currentProtocols = [System.Net.ServicePointManager]::SecurityProtocol

        if (($currentProtocols -band $tls12) -ne $tls12) {
            [System.Net.ServicePointManager]::SecurityProtocol = $currentProtocols -bor $tls12
            _Write-StandardMessage -Message "[STATUS] Added TLS 1.2 to the current process security protocol flags." -Level INF
        }
    }
    catch {
        _Write-StandardMessage -Message ("[WRN] Failed to ensure TLS 1.2: {0}" -f $_.Exception.Message) -Level WRN
    }

    if ($PSBoundParameters.ContainsKey('OutFile')) {
        try {
            $directory = [System.IO.Path]::GetDirectoryName($OutFile)

            if (-not [string]::IsNullOrWhiteSpace($directory)) {
                if (-not [System.IO.Directory]::Exists($directory)) {
                    [void][System.IO.Directory]::CreateDirectory($directory)
                    _Write-StandardMessage -Message ("[STATUS] Created output directory '{0}'." -f $directory) -Level INF
                }
            }
        }
        catch {
            _Write-StandardMessage -Message ("[ERR] Failed to prepare output directory for '{0}': {1}" -f $OutFile, $_.Exception.Message) -Level ERR
            throw
        }
    }

    $callerHandledProxy =
        $PSBoundParameters.ContainsKey('Proxy') -or
        $PSBoundParameters.ContainsKey('ProxyCredential') -or
        $PSBoundParameters.ContainsKey('ProxyUseDefaultCredentials')

    $probeTimeout = if ($TimeoutSec -gt 0) { $TimeoutSec } else { 8 }
    $proxyProfile = $null

    if (-not $callerHandledProxy) {
        $proxyProfile = _ResolveCorporateProxyProfile `
            -TargetUri $Uri `
            -ProbeTimeoutSec ([Math]::Max(1, $probeTimeout)) `
            -ProfilePath $ProxyProfilePath `
            -ManualProxyDefault $DefaultManualProxy `
            -SkipManualPrompt:$SkipProxyManualPrompt `
            -SkipSessionPreparation:$SkipProxySessionPreparation `
            -ForceRefresh:$ForceRefreshProxyProfile `
            -ClearProfile:$ClearProxyProfile

        _Write-StandardMessage -Message (
            "[STATUS] Proxy profile resolved mode '{0}' from '{1}' for '{2}'." -f
            $proxyProfile.Mode, $proxyProfile.ProfileSource, $uriDisplay
        ) -Level INF

        _ApplyProxyProfileToCallParams -CallParams $callParams -ProxyProfile $proxyProfile
    }
    else {
        _Write-StandardMessage -Message ("[STATUS] Caller supplied proxy-related parameters for '{0}'. Persisted proxy profile is skipped." -f $uriDisplay) -Level INF
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
            _Write-StandardMessage -Message (
                "[WRN] Streaming download was requested, but the current parameter combination is not safely compatible. Falling back to native Invoke-WebRequest for '{0}'." -f $uriDisplay
            ) -Level WRN
        }
    }

    if ($streamingHashValidationRequested -and -not $useStreamingEngine) {
        _Write-StandardMessage -Message ("[ERR] Required streaming hash validation is only supported for the streaming download path (GET + OutFile compatible requests).") -Level ERR
        throw "Required streaming hash validation is only supported for the streaming download path."
    }

    if ($effectiveSkipCertificateCheck) {
        if ($useStreamingEngine) {
            if ($nativeSupportsSkipCertificateCheck) {
                _Write-StandardMessage -Message (
                    "[STATUS] PowerShell {0} supports native -SkipCertificateCheck, and the compatible streaming path remains enabled for '{1}' to preserve function-managed download behavior." -f
                    $PSVersionTable.PSVersion, $uriDisplay
                ) -Level INF
            }
            else {
                _Write-StandardMessage -Message (
                    "[STATUS] The streaming download path will apply certificate validation bypass per request for '{0}'." -f $uriDisplay
                ) -Level INF
            }
        }
        elseif ($nativeSupportsSkipCertificateCheck) {
            _Write-StandardMessage -Message (
                "[STATUS] PowerShell {0} will pass -SkipCertificateCheck directly to native Invoke-WebRequest for '{1}'." -f
                $PSVersionTable.PSVersion, $uriDisplay
            ) -Level INF
        }
    }
    else {
        _Write-StandardMessage -Message ("[STATUS] TLS server certificate validation remains enabled for '{0}'." -f $uriDisplay) -Level INF
    }

    if ($useStreamingEngine) {
        _Write-StandardMessage -Message ("[STATUS] Using the streaming download path for '{0}'." -f $uriDisplay) -Level INF
    }
    else {
        _Write-StandardMessage -Message ("[STATUS] Using the native Invoke-WebRequest path for '{0}'." -f $uriDisplay) -Level INF
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
    $acceptAllCallback = $null

    try {
        if ($effectiveSkipCertificateCheck) {
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

            if (-not $useStreamingEngine -and -not $nativeSupportsSkipCertificateCheck) {
                _Write-StandardMessage -Message ("[STATUS] Enabling temporary certificate validation bypass for '{0}'." -f $uriDisplay) -Level INF
                $previousCertificateValidationCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $acceptAllCallback
                $skipCertificateCheckEnabled = $true
            }
        }

        $retryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        for ($attemptIndex = 1; $attemptIndex -le $RetryCount; $attemptIndex++) {
            $requestUseDefaultCredentials =
                ($autoUpgradedToDefaultCredentials) -or
                ($explicitUseDefaultCredentialsSupplied -and [bool]$UseDefaultCredentials)
            $resolvedProfileForcesNoProxy =
                (-not $callerHandledProxy) -and
                ($null -ne $proxyProfile) -and
                ([string]$proxyProfile.Mode -eq 'Direct')

            if (-not $requestUseDefaultCredentials -and $callParams.ContainsKey('UseDefaultCredentials') -and -not $explicitUseDefaultCredentialsSupplied) {
                [void]$callParams.Remove('UseDefaultCredentials')
            }

            if ($requestUseDefaultCredentials -and -not $useStreamingEngine) {
                $callParams['UseDefaultCredentials'] = $true
            }

            if ($attemptIndex -gt 1) {
                _Write-StandardMessage -Message (
                    "[STATUS] Starting attempt {0} of {1} for {2} {3}." -f $attemptIndex, $RetryCount, $effectiveMethod, $uriDisplay
                ) -Level INF
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
                                                Pid = $PID
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
                                            _Write-StandardMessage -Message ("[STATUS] Removing stale download lock '{0}'." -f $downloadLockPath) -Level WRN
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

                                        _Write-StandardMessage -Message ("[STATUS] Another process is downloading '{0}'. Waiting for lock '{1}' to clear." -f $uriDisplay, $downloadLockPath) -Level INF

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
                                FileExistedBeforeAttempt = $false
                                ExistingFileLength = 0L
                                StartingOffset = 0L
                                ResumeRequested = $false
                                ResumeApplied = $false
                                BytesDownloadedThisAttempt = 0L
                                TotalBytesOnDisk = 0L
                                ResponseStatusCode = $null
                                RemoteContentLength = $null
                                RemoteAcceptRanges = $null
                                RemoteETag = $null
                                RemoteLastModified = $null
                                RemoteContentRange = $null
                                RemoteContentRangeStart = $null
                                RemoteTotalLength = $null
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

                                    _Write-StandardMessage -Message ("[STATUS] Attempting resume for '{0}' from byte {1}." -f $uriDisplay, $downloadState.StartingOffset) -Level INF
                                }
                                else {
                                    $downloadState.StartingOffset = 0L
                                    $downloadState.TotalBytesOnDisk = 0L
                                }

                                $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
                                if ($null -eq $request) {
                                    throw ("Failed to create HttpWebRequest for '{0}'." -f $uriDisplay)
                                }

                                if ($effectiveSkipCertificateCheck -and $null -ne $acceptAllCallback) {
                                    $request.ServerCertificateValidationCallback = $acceptAllCallback
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
                                    $request.Credentials = $Credential.GetNetworkCredential()
                                }
                                elseif ($requestUseDefaultCredentials) {
                                    $request.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                                }

                                if ($callParams.ContainsKey('Proxy') -and $null -ne $callParams['Proxy']) {
                                    $webProxy = New-Object System.Net.WebProxy(([uri]$callParams['Proxy']).AbsoluteUri, $true)

                                    if ($PSBoundParameters.ContainsKey('ProxyCredential') -and $null -ne $ProxyCredential) {
                                        $webProxy.Credentials = $ProxyCredential.GetNetworkCredential()
                                    }
                                    elseif ($callParams.ContainsKey('ProxyCredential') -and $null -ne $callParams['ProxyCredential']) {
                                        $webProxy.Credentials = $callParams['ProxyCredential'].GetNetworkCredential()
                                    }
                                    elseif ($callParams.ContainsKey('ProxyUseDefaultCredentials') -and [bool]$callParams['ProxyUseDefaultCredentials']) {
                                        $webProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                                    }

                                    $request.Proxy = $webProxy
                                }
                                elseif ($resolvedProfileForcesNoProxy) {
                                    $request.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
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

                                _Write-StandardMessage -Message ("[STATUS] Sending streaming GET request to '{0}'." -f $uriDisplay) -Level INF

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
                                            _Write-StandardMessage -Message ("[WRN] Resume metadata for '{0}' is missing or does not match the current remote object. Restarting from byte 0." -f $uriDisplay) -Level WRN

                                            if ($null -ne $responseStream) { $responseStream.Dispose(); $responseStream = $null }
                                            if ($null -ne $response) { $response.Close(); $response = $null }

                                            $forceFreshDownload = $true
                                            continue
                                        }

                                        $downloadState.ResumeApplied = $true
                                        _Write-StandardMessage -Message ("[STATUS] Resume accepted by the server for '{0}' at byte {1}." -f $uriDisplay, $downloadState.StartingOffset) -Level INF
                                    }
                                    elseif ($downloadState.ResponseStatusCode -eq 200) {
                                        _Write-StandardMessage -Message ("[WRN] The server ignored the resume range for '{0}'. Restarting the download from byte 0." -f $uriDisplay) -Level WRN

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
                                        Uri = [string]$Uri.AbsoluteUri
                                        ETag = if ($null -ne $downloadState.RemoteETag) { [string]$downloadState.RemoteETag } else { $null }
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

                                                _Write-StandardMessage -Message ("[DL] {0} MB of {1} MB ({2} %) for '{3}'." -f $downloadedMbText, $contentLengthMbText, $percentText, $uriDisplay) -Level INF
                                            }
                                            else {
                                                $percentText = $percent.ToString().PadLeft(3)
                                                _Write-StandardMessage -Message ("[DL] {0} of {1} bytes ({2} %) for '{3}'." -f $downloadState.TotalBytesOnDisk, $contentLength, $percentText, $uriDisplay) -Level INF
                                            }
                                        }
                                        else {
                                            $megaBytesText = ([int64][Math]::Round($downloadState.TotalBytesOnDisk / 1048576.0, 0)).ToString()
                                            _Write-StandardMessage -Message ("[DL] ~{0} MB from '{1}'." -f $megaBytesText, $uriDisplay) -Level INF
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

                                            _Write-StandardMessage -Message ("[DL] {0} MB of {1} MB (100 %) for '{2}'." -f $totalMbText, $contentLengthMbText, $uriDisplay) -Level INF
                                        }
                                        else {
                                            _Write-StandardMessage -Message ("[DL] {0} of {1} bytes (100 %) for '{2}'." -f $downloadState.TotalBytesOnDisk, $contentLength, $uriDisplay) -Level INF
                                        }
                                    }
                                }
                                else {
                                    $finalMbText = ([int64][Math]::Round($downloadState.TotalBytesOnDisk / 1048576.0, 0)).ToString()
                                    _Write-StandardMessage -Message ("[DL] Complete, total {0} MB from '{1}'." -f $finalMbText, $uriDisplay) -Level INF
                                }

                                if ($streamingHashValidationRequested) {
                                    _Write-StandardMessage -Message ("[STATUS] Verifying {0} for '{1}'." -f $RequiredStreamingHashType, $OutFile) -Level INF
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

                                    _Write-StandardMessage -Message ("[OK] Required {0} matched for '{1}'." -f $RequiredStreamingHashType, $OutFile) -Level INF
                                }

                                if (-not [string]::IsNullOrWhiteSpace($resumeMetadataPath)) {
                                    _RemoveFileIfExists -Path $resumeMetadataPath
                                }

                                _Write-StandardMessage -Message ("[OK] Wrote {0} bytes from '{1}' to '{2}' on attempt {3} of {4}. File size is now {5} bytes." -f $downloadState.BytesDownloadedThisAttempt, $uriDisplay, $OutFile, $attemptIndex, $RetryCount, $downloadState.TotalBytesOnDisk) -Level INF
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
                        $previousDefaultWebProxy = $null
                        $defaultWebProxyOverridden = $false

                        try {
                            if ($resolvedProfileForcesNoProxy -and -not $nativeSupportsNoProxy) {
                                $previousDefaultWebProxy = [System.Net.WebRequest]::DefaultWebProxy
                                [System.Net.WebRequest]::DefaultWebProxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
                                $defaultWebProxyOverridden = $true
                            }

                            $result = Invoke-WebRequest @callParams
                        }
                        finally {
                            if ($defaultWebProxyOverridden) {
                                [System.Net.WebRequest]::DefaultWebProxy = $previousDefaultWebProxy
                            }
                        }

                        _Write-StandardMessage -Message (
                            "[OK] Request completed successfully on attempt {0} of {1} for {2} {3}." -f
                            $attemptIndex, $RetryCount, $effectiveMethod, $uriDisplay
                        ) -Level INF

                        return $result
                    }
                }
                catch {
                    $caughtError = $_
                    $statusCode = _GetHttpStatusCodeFromErrorRecord -ErrorRecord $caughtError
                    $wwwAuthenticateValues = _GetWwwAuthenticateValuesFromErrorRecord -ErrorRecord $caughtError
                    $hasWwwAuthenticateChallenge = $wwwAuthenticateValues.Count -gt 0
                    $isLikelyProxyAuthenticationFailure = _TestIsLikelyProxyAuthenticationFailure -ErrorRecord $caughtError -StatusCode $statusCode

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
                                            _Write-StandardMessage -Message ("[STATUS] Verifying {0} for '{1}'." -f $RequiredStreamingHashType, $OutFile) -Level INF
                                            $actualStreamingHashOn416 = _GetFileHashHex -Path $OutFile -Algorithm $RequiredStreamingHashType
                                            if ($actualStreamingHashOn416 -ne $RequiredStreamingHash) {
                                                try { [System.IO.File]::Delete($OutFile) } catch {}
                                                throw ("Required {0} mismatch for '{1}'. Expected '{2}', actual '{3}'." -f $RequiredStreamingHashType, $OutFile, $RequiredStreamingHash, $actualStreamingHashOn416)
                                            }

                                            _Write-StandardMessage -Message ("[OK] Required {0} matched for '{1}'." -f $RequiredStreamingHashType, $OutFile) -Level INF
                                        }

                                        _Write-StandardMessage -Message ("[OK] The existing file '{0}' already matches the remote content length ({1} bytes). No download was necessary." -f $OutFile, $localStateOn416.Length) -Level INF
                                        return
                                    }
                                }
                            }
                        }
                        catch {
                            $caughtError = $_
                            $statusCode = _GetHttpStatusCodeFromErrorRecord -ErrorRecord $caughtError
                            $wwwAuthenticateValues = _GetWwwAuthenticateValuesFromErrorRecord -ErrorRecord $caughtError
                            $hasWwwAuthenticateChallenge = $wwwAuthenticateValues.Count -gt 0
                            $isLikelyProxyAuthenticationFailure = _TestIsLikelyProxyAuthenticationFailure -ErrorRecord $caughtError -StatusCode $statusCode
                        }
                    }

                    $shouldInvalidateManualProxyProfile =
                        (-not $callerHandledProxy) -and
                        (-not $manualProxyProfileAutoRefreshAttempted) -and
                        ($null -ne $proxyProfile) -and
                        ($proxyProfile.Mode -eq 'ManualProxy') -and
                        $isLikelyProxyAuthenticationFailure

                    if ($shouldInvalidateManualProxyProfile) {
                        _Write-StandardMessage -Message (
                            "[WRN] Stored manual proxy profile for '{0}' appears invalid or expired. Clearing stored proxy data and re-resolving proxy access." -f
                            $uriDisplay
                        ) -Level WRN

                        $manualProxyProfileAutoRefreshAttempted = $true

                        try {
                            _RemovePersistedProxyProfile -ProfilePath $ProxyProfilePath

                            $proxyProfile = _ResolveCorporateProxyProfile `
                                -TargetUri $Uri `
                                -ProbeTimeoutSec ([Math]::Max(1, $probeTimeout)) `
                                -ProfilePath $ProxyProfilePath `
                                -ManualProxyDefault $DefaultManualProxy `
                                -SkipManualPrompt:$SkipProxyManualPrompt `
                                -SkipSessionPreparation:$SkipProxySessionPreparation `
                                -ForceRefresh `
                                -ClearProfile

                            _Write-StandardMessage -Message (
                                "[STATUS] Proxy profile re-resolved mode '{0}' from '{1}' for '{2}' after manual proxy invalidation." -f
                                $proxyProfile.Mode, $proxyProfile.ProfileSource, $uriDisplay
                            ) -Level INF

                            if ($proxyProfile.Mode -eq 'NoResolvedProxyProfile') {
                                throw "Stored manual proxy profile was cleared after proxy authentication failure, but no replacement proxy profile could be resolved."
                            }

                            _ApplyProxyProfileToCallParams -CallParams $callParams -ProxyProfile $proxyProfile
                            continue
                        }
                        catch {
                            _Write-StandardMessage -Message (
                                "[WRN] Failed to re-resolve proxy profile after manual proxy invalidation for '{0}': {1}" -f
                                $uriDisplay, $_.Exception.Message
                            ) -Level WRN
                            throw
                        }
                    }

                    $hasAutoUpgradeTrigger =
                        $autoUseDefaultCredentialsAllowed -and
                        (-not $requestUseDefaultCredentials) -and
                        ($statusCode -eq 401) -and
                        $hasWwwAuthenticateChallenge

                    if ($hasAutoUpgradeTrigger -and -not $autoUseDefaultCredentialsGuardInfoResolved) {
                        $autoUseDefaultCredentialsGuardInfo = _GetAutoUseDefaultCredentialsGuardInfo -TargetUri $Uri
                        $autoUseDefaultCredentialsGuardInfoResolved = $true

                        if ($autoUseDefaultCredentialsGuardInfo.IsIntranetLike) {
                            _Write-StandardMessage -Message (
                                "[STATUS] Automatic default-credentials guard passed for '{0}'. Signal(s): {1}" -f
                                $uriDisplay, ($autoUseDefaultCredentialsGuardInfo.Signals -join '; ')
                            ) -Level INF
                        }
                        else {
                            $resolvedAddressText = if ($autoUseDefaultCredentialsGuardInfo.ResolvedAddresses.Count -gt 0) {
                                $autoUseDefaultCredentialsGuardInfo.ResolvedAddresses -join ', '
                            }
                            else {
                                'none'
                            }

                            _Write-StandardMessage -Message (
                                "[STATUS] Automatic default-credentials guard blocked upgrade for '{0}'. No intranet-like signals were found. Resolved address(es): {1}" -f
                                $uriDisplay, $resolvedAddressText
                            ) -Level INF
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

                        _Write-StandardMessage -Message (
                            "[STATUS] Received 401 with WWW-Authenticate challenge for '{0}'. Retrying the current attempt with default credentials. Challenge(s): {1}" -f
                            $uriDisplay, ($wwwAuthenticateValues -join ', ')
                        ) -Level WRN

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
                                        _Write-StandardMessage -Message ("[STATUS] Streaming download failed, but '{0}' existed before this invocation and will be left in place." -f $OutFile) -Level INF
                                    }
                                }
                            }
                            catch {
                                _Write-StandardMessage -Message ("[WRN] Failed to delete the partial streaming download '{0}': {1}" -f $OutFile, $_.Exception.Message) -Level WRN
                            }
                        }

                        if ($retryBudgetExpired) {
                            _Write-StandardMessage -Message (
                                "[ERR] Retry budget expired after {0} ms while processing {1} {2}: {3}" -f
                                $retryStopwatch.ElapsedMilliseconds, $effectiveMethod, $uriDisplay, $caughtError.Exception.Message
                            ) -Level ERR
                        }
                        else {
                            _Write-StandardMessage -Message (
                                "[ERR] Attempt {0} of {1} failed and no retries remain for {2} {3}: {4}" -f
                                $attemptIndex, $RetryCount, $effectiveMethod, $uriDisplay, $caughtError.Exception.Message
                            ) -Level ERR
                        }

                        throw
                    }

                    $sleepMilliseconds = $RetryDelayMilliseconds
                    if ($TotalTimeoutSec -gt 0 -and $sleepMilliseconds -gt $remainingMilliseconds) {
                        $sleepMilliseconds = $remainingMilliseconds
                    }

                    if ($sleepMilliseconds -lt 0) {
                        $sleepMilliseconds = 0
                    }

                    _Write-StandardMessage -Message (
                        "[RETRY] Attempt {0} of {1} failed for {2} {3}: {4}. Retrying in {5} ms." -f
                        $attemptIndex, $RetryCount, $effectiveMethod, $uriDisplay, $caughtError.Exception.Message, $sleepMilliseconds
                    ) -Level WRN

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
    }
}

<#
Set-Alias -Name 'Invoke-WebRequest-IStoppedAskingWhy'       -Value 'Invoke-WebRequestEx10'
Set-Alias -Name 'Invoke-WebRequest-IJustNeedTheFile'        -Value 'Invoke-WebRequestEx10'
Set-Alias -Name 'Invoke-WebRequest-TemporaryBecamePermanent' -Value 'Invoke-WebRequestEx10'
Set-Alias -Name 'Invoke-WebRequest-LetsNeverSpeakOfThisAgain' -Value 'Invoke-WebRequestEx10'
Set-Alias -Name 'Invoke-WebRequest-GetItDoneAnyway'         -Value 'Invoke-WebRequestEx10'
#>
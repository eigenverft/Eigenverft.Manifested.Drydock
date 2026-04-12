function Initialize-ProxyAccessProfile {
<#
.SYNOPSIS
Resolves a usable outbound proxy access profile for Windows PowerShell 5.1,
persists the result to a CliXml profile file, and stores ready-to-use values
in global variables.

.DESCRIPTION
Resolution order:
1. Direct access
2. Local relay proxy on loopback
3. System proxy with default credentials
4. Manual proxy

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

This helper is primarily intended for Windows PowerShell 5.1 in corporate
environments where direct access is not guaranteed.
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

    # This helper is intentionally written for Windows PowerShell 5.1.
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or
        $PSVersionTable.PSVersion.Major -ne 5 -or
        $PSVersionTable.PSVersion.Minor -ne 1) {
        throw "Initialize-ProxyAccessProfile is intended for Windows PowerShell 5.1. Current version: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
    }

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
            [ValidateSet('Direct','LocalRelayProxy','SystemProxyDefaultCredentials','ManualProxy','Unavailable')]
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
            [ValidateSet('Direct','LocalRelayProxy','SystemProxyDefaultCredentials','ManualProxy','Unavailable')]
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
            }

            'Unavailable' {
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
            $request.UserAgent = 'WindowsPowerShell/5.1 Initialize-ProxyAccessProfile'
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

            'Unavailable' {
                [void]$diagnostics.Add('Persisted unavailable profiles are not considered reusable.')
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

        # We do not persist an unavailable state. That avoids carrying a bad result
        # across sessions after a temporary network problem.
        Remove-PersistedProfile -ProfilePath $ProxyProfilePath

        Set-ProxyGlobals `
            -Mode 'Unavailable' `
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
    Invokes a web request with retries, proxy/TLS handling, optional streaming downloads,
    persisted corporate proxy profile handling, resume support, resume metadata validation,
    cooperative lock handling, optional partial-file cleanup, and optional final hash verification.

.DESCRIPTION
    This is a corporate variant of Invoke-WebRequestEx.

    It keeps the original request behavior intact, but replaces the simple proxy
    auto-discovery block with a persisted proxy-profile resolver that tries:

    1. Direct access
    2. Local relay proxy on loopback
    3. System proxy with default credentials
    4. Manual proxy

    The resolved profile is cached in-process and also persisted as a CliXml file
    in the current user's profile.

    Persisted proxy profiles are validated with a live probe before reuse. If the
    stored profile is stale or no longer works, it is cleared and fresh detection
    continues automatically.

    The persisted profile format and default file location are aligned with
    Initialize-ProxyAccessProfile, but this function remains fully independent and
    does not rely on that helper.

    The same -SkipCertificateCheck / -EnforceCertificateCheck behavior is applied
    to both the proxy-profile probe path and the actual request path.

    If the caller manually supplies proxy-related parameters, the persisted proxy
    profile logic is skipped entirely and the caller's settings win.

    If a persisted ManualProxy profile later fails with likely proxy-authentication
    errors, the stored profile is cleared automatically and proxy resolution is
    re-run once during the current call.

    If manual proxy entry would be required in a non-interactive session, the
    function throws instead of attempting to prompt.

    Added streaming-download features include:
    - Resume support for compatible streaming downloads
    - Resume metadata validation using persisted ETag / Last-Modified sidecar state
    - Cooperative lock file handling to reduce concurrent download collisions
    - Optional final required hash verification
    - Optional partial-file cleanup on terminal failure
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

    function _UriDisplayShortener {
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

    function _GetResponseFromErrorRecord {
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

    function _GetHttpStatusCodeFromErrorRecord {
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

    function _GetWwwAuthenticateValuesFromErrorRecord {
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

    function _TestIsLikelyProxyAuthenticationFailure {
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

    function _TestIsPrivateOrIntranetAddress {
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

    function _GetAutoUseDefaultCredentialsGuardInfo {
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

    function _GetProcessProxyProfileCacheTable {
        if (-not $global:InvokeWebRequestEx10ProxyProfileProcessCache -or
            $global:InvokeWebRequestEx10ProxyProfileProcessCache -isnot [hashtable]) {
            $global:InvokeWebRequestEx10ProxyProfileProcessCache = @{}
        }

        return $global:InvokeWebRequestEx10ProxyProfileProcessCache
    }

    function _EnsurePersistedProxyProfileDirectory {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProfilePath
        )

        $directory = [System.IO.Path]::GetDirectoryName($ProfilePath)
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not [System.IO.Directory]::Exists($directory)) {
            [void][System.IO.Directory]::CreateDirectory($directory)
        }
    }

    function _RemovePersistedProxyProfile {
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

    function _SavePersistedProxyProfile {
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

            Write-StandardMessage -Message (
                "[STATUS] Persisted proxy profile to '{0}'." -f $ProfilePath
            ) -Level INF
        }
        catch {
            Write-StandardMessage -Message (
                "[WRN] Failed to persist proxy profile to '{0}': {1}" -f
                $ProfilePath, $_.Exception.Message
            ) -Level WRN
            throw
        }
    }

    function _LoadPersistedProxyProfile {
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
            Write-StandardMessage -Message (
                "[WRN] Failed to load persisted proxy profile from '{0}': {1}. The stored profile will be cleared." -f
                $ProfilePath, $_.Exception.Message
            ) -Level WRN

            _RemovePersistedProxyProfile -ProfilePath $ProfilePath
            return $null
        }
    }

    function _BuildRuntimeProxyProfileState {
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

                    $capturedProxyUri = $proxyUri
                    $capturedProxyCredential = $proxyCredential

                    $prepareSession = {
                        $webProxy = New-Object System.Net.WebProxy($capturedProxyUri.AbsoluteUri, $true)
                        $webProxy.Credentials = $capturedProxyCredential.GetNetworkCredential()
                        [System.Net.WebRequest]::DefaultWebProxy = $webProxy
                    }.GetNewClosure()
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

                    $capturedProxyUri = $proxyUri

                    $prepareSession = {
                        [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($capturedProxyUri.AbsoluteUri, $true)
                    }.GetNewClosure()
                }
            }

            'SystemProxyDefaultCredentials' {
                if ($null -ne $proxyUri) {
                    $invokeWebRequest = @{
                        Proxy = $proxyUri
                        ProxyUseDefaultCredentials = $true
                    }

                    $prepareSession = {
                        [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebRequest]::GetSystemWebProxy()
                        [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
                    }.GetNewClosure()
                }
            }

            'Direct' {
            }

            'Unavailable' {
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

    function _SetProcessProxyProfileState {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProfilePath,

            [Parameter(Mandatory = $true)]
            [pscustomobject]$RuntimeState
        )

        $cacheTable = _GetProcessProxyProfileCacheTable
        $cacheTable[$ProfilePath] = $RuntimeState
    }

    function _GetProcessProxyProfileState {
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

    function _EnsurePreparedRuntimeProxyProfileState {
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

    function _NewStoredProxyProfile {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('Direct','LocalRelayProxy','SystemProxyDefaultCredentials','ManualProxy','Unavailable')]
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

    function _TestProxyProfileAccess {
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
            $request.UserAgent = 'WindowsPowerShell Invoke-WebRequestEx10 ProxyProfileProbe'

            $response = [System.Net.HttpWebResponse]$request.GetResponse()

            [pscustomobject]@{
                Success = $true
                StatusCode = [int]$response.StatusCode
                ErrorMessage = $null
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

    function _GetLocalRelayProxyCandidates {
        return @(
            [uri]'http://127.0.0.1:3128',
            [uri]'http://localhost:3128'
        )
    }

    function _TestLoopbackPortOpen {
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

    function _TryResolveLocalRelayProxy {
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

    function _TestPersistedProxyProfile {
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

            'Unavailable' {
                [void]$diagnostics.Add('Persisted unavailable profiles are not considered reusable.')
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

    function _GetManualProxyEntry {
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

    function _GetDownloadLocalState {
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

    function _GetDownloadResponseInfo {
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

    function _OpenDownloadFileStream {
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

    function _GetResolvedDownloadPath {
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

    function _GetDownloadSidecarHash {
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

    function _GetDownloadLockPath {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri,

            [Parameter(Mandatory = $true)]
            [string]$OutFilePath
        )

        $hash = _GetDownloadSidecarHash -TargetUri $TargetUri -OutFilePath $OutFilePath
        return ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("InvokeWebRequestEx_{0}.lock" -f $hash)))
    }

    function _GetResumeMetadataPath {
        param(
            [Parameter(Mandatory = $true)]
            [uri]$TargetUri,

            [Parameter(Mandatory = $true)]
            [string]$OutFilePath
        )

        $hash = _GetDownloadSidecarHash -TargetUri $TargetUri -OutFilePath $OutFilePath
        return ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("InvokeWebRequestEx_{0}.resume" -f $hash)))
    }

    function _ReadJsonFile {
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

    function _WriteJsonFile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,

            [Parameter(Mandatory = $true)]
            [object]$Data
        )

        $json = $Data | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
    }

    function _RemoveFileIfExists {
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

    function _GetCurrentProcessStartTimeUtcText {
        try {
            return ([System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o'))
        }
        catch {
            return $null
        }
    }

    function _TestDownloadLockIsStale {
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

    function _GetFileHashHex {
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

    function _ResolveCorporateProxyProfile {
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
                        Write-StandardMessage -Message (
                            "[WRN] {0}" -f $message
                        ) -Level WRN
                    }

                    Write-StandardMessage -Message (
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

            # 2) Local relay proxy on loopback.
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

            # 3) System proxy + default credentials.
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

            # 4) Manual proxy prompt.
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

            $unavailableStored = _NewStoredProxyProfile `
                -Mode 'Unavailable' `
                -TestUri $TargetUri `
                -Diagnostics $diagnostics.ToArray()

            $unavailableState = _BuildRuntimeProxyProfileState -StoredProfile $unavailableStored -ProfileSource 'FreshDetection'
            $unavailableState.Persisted = $false
            _SetProcessProxyProfileState -ProfilePath $ProfilePath -RuntimeState $unavailableState

            return $unavailableState
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

    function _ApplyProxyProfileToCallParams {
        param(
            [Parameter(Mandatory = $true)]
            [hashtable]$CallParams,

            [Parameter(Mandatory = $true)]
            [pscustomobject]$ProxyProfile
        )

        foreach ($key in @('Proxy', 'ProxyCredential', 'ProxyUseDefaultCredentials')) {
            if ($CallParams.ContainsKey($key)) {
                [void]$CallParams.Remove($key)
            }
        }

        foreach ($entry in $ProxyProfile.InvokeWebRequest.GetEnumerator()) {
            $CallParams[$entry.Key] = $entry.Value
        }
    }

    if ($PSVersionTable.PSEdition -ne 'Desktop' -or
        $PSVersionTable.PSVersion.Major -ne 5 -or
        $PSVersionTable.PSVersion.Minor -ne 1) {
        throw "Invoke-WebRequestEx10 is intended for Windows PowerShell 5.1."
    }

    $uriDisplay = _UriDisplayShortener -TargetUri $Uri

    Write-StandardMessage -Message ("[STATUS] Initializing Invoke-WebRequestEx10 for '{0}'." -f $uriDisplay) -Level INF

    $effectiveMethod = if ($PSBoundParameters.ContainsKey('Method') -and $null -ne $Method) {
        $Method.ToString().ToUpperInvariant()
    }
    else {
        'GET'
    }

    $runningOnPwsh = $PSVersionTable.PSEdition -eq 'Core'
    $nativeSupportsSkipCertificateCheck = $runningOnPwsh -and $PSVersionTable.PSVersion -ge [version]'7.0'
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
            Write-StandardMessage -Message ("[ERR] Parameter 'RequiredStreamingHashType' is required when 'RequiredStreamingHash' is supplied.") -Level ERR
            throw "RequiredStreamingHashType is required when RequiredStreamingHash is supplied."
        }

        if (-not $PSBoundParameters.ContainsKey('RequiredStreamingHash') -or [string]::IsNullOrWhiteSpace($RequiredStreamingHash)) {
            Write-StandardMessage -Message ("[ERR] Parameter 'RequiredStreamingHash' is required when 'RequiredStreamingHashType' is supplied.") -Level ERR
            throw "RequiredStreamingHash is required when RequiredStreamingHashType is supplied."
        }

        $RequiredStreamingHash = $RequiredStreamingHash.Trim().ToUpperInvariant()
    }

    try {
        $tls12 = [System.Net.SecurityProtocolType]::Tls12
        $currentProtocols = [System.Net.ServicePointManager]::SecurityProtocol

        if (($currentProtocols -band $tls12) -ne $tls12) {
            [System.Net.ServicePointManager]::SecurityProtocol = $currentProtocols -bor $tls12
            Write-StandardMessage -Message "[STATUS] Added TLS 1.2 to the current process security protocol flags." -Level INF
        }
    }
    catch {
        Write-StandardMessage -Message ("[WRN] Failed to ensure TLS 1.2: {0}" -f $_.Exception.Message) -Level WRN
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
            Write-StandardMessage -Message ("[ERR] Failed to prepare output directory for '{0}': {1}" -f $OutFile, $_.Exception.Message) -Level ERR
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

        Write-StandardMessage -Message (
            "[STATUS] Corporate proxy profile resolved mode '{0}' from '{1}' for '{2}'." -f
            $proxyProfile.Mode, $proxyProfile.ProfileSource, $uriDisplay
        ) -Level INF

        _ApplyProxyProfileToCallParams -CallParams $callParams -ProxyProfile $proxyProfile
    }
    else {
        Write-StandardMessage -Message ("[STATUS] Caller supplied proxy-related parameters for '{0}'. Persisted corporate proxy profile is skipped." -f $uriDisplay) -Level INF
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
            Write-StandardMessage -Message (
                "[WRN] Streaming download was requested, but the current parameter combination is not safely compatible. Falling back to native Invoke-WebRequest for '{0}'." -f $uriDisplay
            ) -Level WRN
        }
    }

    if ($streamingHashValidationRequested -and -not $useStreamingEngine) {
        Write-StandardMessage -Message ("[ERR] Required streaming hash validation is only supported for the streaming download path (GET + OutFile compatible requests).") -Level ERR
        throw "Required streaming hash validation is only supported for the streaming download path."
    }

    if ($nativeSupportsSkipCertificateCheck -and $effectiveSkipCertificateCheck) {
        $useStreamingEngine = $false
        Write-StandardMessage -Message (
            "[STATUS] PowerShell {0} will pass -SkipCertificateCheck directly to native Invoke-WebRequest. Streaming path is disabled for '{1}'." -f
            $PSVersionTable.PSVersion, $uriDisplay
        ) -Level INF
    }
    elseif (-not $effectiveSkipCertificateCheck) {
        Write-StandardMessage -Message ("[STATUS] TLS server certificate validation remains enabled for '{0}'." -f $uriDisplay) -Level INF
    }

    if ($streamingHashValidationRequested -and -not $useStreamingEngine) {
        Write-StandardMessage -Message ("[ERR] Required streaming hash validation is only supported for the streaming download path in the effective request configuration.") -Level ERR
        throw "Required streaming hash validation is only supported for the effective streaming download path."
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
        if ($effectiveSkipCertificateCheck -and -not $nativeSupportsSkipCertificateCheck) {
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
                Write-StandardMessage -Message (
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
                                    elseif ($callParams.ContainsKey('ProxyCredential') -and $null -ne $callParams['ProxyCredential']) {
                                        $webProxy.Credentials = $callParams['ProxyCredential']
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

                        Write-StandardMessage -Message (
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
                        Write-StandardMessage -Message (
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

                            Write-StandardMessage -Message (
                                "[STATUS] Corporate proxy profile re-resolved mode '{0}' from '{1}' for '{2}' after manual proxy invalidation." -f
                                $proxyProfile.Mode, $proxyProfile.ProfileSource, $uriDisplay
                            ) -Level INF

                            if ($proxyProfile.Mode -eq 'Unavailable') {
                                throw "Stored manual proxy profile was cleared after proxy authentication failure, but no replacement proxy profile could be resolved."
                            }

                            _ApplyProxyProfileToCallParams -CallParams $callParams -ProxyProfile $proxyProfile
                            continue
                        }
                        catch {
                            Write-StandardMessage -Message (
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
                            Write-StandardMessage -Message (
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

                            Write-StandardMessage -Message (
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

                        Write-StandardMessage -Message (
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
                                        Write-StandardMessage -Message ("[STATUS] Streaming download failed, but '{0}' existed before this invocation and will be left in place." -f $OutFile) -Level INF
                                    }
                                }
                            }
                            catch {
                                Write-StandardMessage -Message ("[WRN] Failed to delete the partial streaming download '{0}': {1}" -f $OutFile, $_.Exception.Message) -Level WRN
                            }
                        }

                        if ($retryBudgetExpired) {
                            Write-StandardMessage -Message (
                                "[ERR] Retry budget expired after {0} ms while processing {1} {2}: {3}" -f
                                $retryStopwatch.ElapsedMilliseconds, $effectiveMethod, $uriDisplay, $caughtError.Exception.Message
                            ) -Level ERR
                        }
                        else {
                            Write-StandardMessage -Message (
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

                    Write-StandardMessage -Message (
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
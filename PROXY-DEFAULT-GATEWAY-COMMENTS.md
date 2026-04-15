# Proxy Default Gateway Comments

## Comment

- Comment request only, not a code change request.
- In virtual proxy or corporate uplift environments, the active IPv4 default gateway can be considered as an extra PX-style proxy candidate on port `3128`.
- The default gateway can be read with `(Get-NetIPConfiguration).IPv4DefaultGateway.NextHop`.
- The default gateway may also be a router or network component, so `port 3128 open` alone is not reliable proof of an HTTP proxy.
- A direct HTTP response on `http://<gateway>:3128` is a useful first signal, but it is still not proof of forward-proxy behavior.
- Use a separate proxied URI access check after the direct HTTP endpoint check.
- Keep the sample PowerShell 5.1 compatible.
- Intended integration targets:
  - `source/Eigenverft.Manifested.Drydock/Eigenverft.Manifested.Drydock.ProxyAware.ps1`
  - `source/Eigenverft.Manifested.Drydock/Eigenverft.Manifested.Drydock.WebRequest.ps1`

## Code Sample Integration

```powershell
function Get-DefaultGatewayProxyCandidate {
    try {
        $gateway = Get-NetIPConfiguration |
            Where-Object { $_.IPv4DefaultGateway -and $_.IPv4DefaultGateway.NextHop } |
            Select-Object -First 1 -ExpandProperty IPv4DefaultGateway |
            Select-Object -ExpandProperty NextHop

        if ($gateway) {
            return [uri]("http://{0}:3128" -f $gateway)
        }
    }
    catch {
    }

    $null
}
```

```powershell
function Test-HttpEndpoint {
    param([uri]$Uri, [int]$TimeoutMilliseconds = 2000)

    if (-not $Uri) { return $false }

    try {
        $request = [System.Net.HttpWebRequest]([System.Net.WebRequest]::Create($Uri))
        $request.Timeout = $TimeoutMilliseconds

        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        try { return $true } finally { $response.Close() }
    }
    catch {
        return $false
    }
}
```

```powershell
function Test-UriAccessViaProxy {
    param([uri]$Uri, [uri]$ProxyUri, [int]$TimeoutMilliseconds = 5000)

    if (-not $Uri -or -not $ProxyUri) { return $false }

    try {
        $request = [System.Net.HttpWebRequest]([System.Net.WebRequest]::Create($Uri))
        $request.Proxy = New-Object System.Net.WebProxy($ProxyUri.AbsoluteUri, $true)
        $request.Timeout = $TimeoutMilliseconds

        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $response.Close()
        $true
    }
    catch {
        $false
    }
}
```

```powershell
$gatewayProxy = Get-DefaultGatewayProxyCandidate

if ($gatewayProxy) {
    if (Test-HttpEndpoint -Uri $gatewayProxy -TimeoutMilliseconds 2000) {
        if (Test-UriAccessViaProxy -Uri $TestUri -ProxyUri $gatewayProxy -TimeoutMilliseconds 5000) {
            $gatewayProxy
        }
    }
}
```

## Integration Notes

- Keep existing loopback candidates first.
- Treat the default-gateway candidate as low confidence until both checks pass.
- First check: direct HTTP endpoint responds on `http://<gateway>:3128`.
- Second check: the same endpoint can access the probe URI as a proxy.
- Do not accept the default-gateway candidate based only on `Test-NetConnection` or raw TCP reachability.

# Get-ConfigValue: optional printable-ASCII validation

## Problem

Package publishing API keys can be stored with invisible transport artifacts or other non-ASCII characters. The value can pass the existing null-or-empty checks but later fail during an HTTP request with an indirect error such as:

```text
Request headers must contain only ASCII characters.
```

Consumers should not normalize or silently alter secret values after calling `Get-ConfigValue`. Validation belongs in the configuration helper so invalid input fails at its source.

## Proposed change

Add an optional parameter to `Get-ConfigValue` that requires the resolved value to contain only printable, non-space ASCII characters.

The validation expression is:

```powershell
[^\x21-\x7E]
```

When the resolved value matches this expression, `Get-ConfigValue` must fail with a clear error without including the secret value in the message or logs.

Without the new parameter, existing `Get-ConfigValue` behavior must remain unchanged.

## Intended usage

```powershell
$SECRET_NUGET_APIKEY = Get-ConfigValue `
    -Check $SECRET_NUGET_APIKEY `
    -FilePath (Join-Path $PSScriptRoot 'cicd.secrets.json') `
    -Property 'SECRET_NUGET_APIKEY' `
    -RequirePrintableAscii
```

The same validation can be enabled for other package publishing API keys:

```powershell
$SECRET_INTTESTNUGET_APIKEY = Get-ConfigValue `
    -Check $SECRET_INTTESTNUGET_APIKEY `
    -FilePath (Join-Path $PSScriptRoot 'cicd.secrets.json') `
    -Property 'SECRET_INTTESTNUGET_APIKEY' `
    -RequirePrintableAscii

$SECRET_POWERSHELLGALLERY_APIKEY = Get-ConfigValue `
    -Check $SECRET_POWERSHELLGALLERY_APIKEY `
    -FilePath (Join-Path $PSScriptRoot 'cicd.secrets.json') `
    -Property 'SECRET_POWERSHELLGALLERY_APIKEY' `
    -RequirePrintableAscii
```

## Acceptance criteria

- The validation is optional and implemented by `Get-ConfigValue`.
- Characters outside `0x21` through `0x7E` cause an immediate failure when validation is enabled.
- CR, LF, NUL, BOM, spaces, tabs, and non-ASCII Unicode characters are rejected.
- The invalid value is never written to logs or included in the exception message.
- No trimming, replacement, or other mutation of the resolved value occurs.
- Existing callers remain compatible when the new parameter is omitted.
- Tests cover valid printable ASCII and each rejected character category.

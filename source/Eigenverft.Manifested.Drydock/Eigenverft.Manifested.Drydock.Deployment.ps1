function Convert-BranchToDeploymentInfo {
<#
.SYNOPSIS
Validate a Git branch, resolve its deployment channel, and create prefix/suffix tokens.
Segments keep ORIGINAL case; all comparisons/mappings are case-insensitive. Branch section exposes path-sanitized segments.

.DESCRIPTION
One entrypoint that:
1) Validates & splits the branch name (subset of Git ref rules), optional path-sanitization helper (non-destructive).
   - Keeps input segment casing as-is.
   - Always emits Branch.PathSegmentsSanitized (safe for filesystem paths).
2) Resolves a deployment channel from the FIRST segment (case-insensitive); defaults cover GitFlow + conventional prefixes.
3) Builds label/prefix/suffix tokens (Short/Long styles) for artifact names or SemVer prereleases.

Return is sectioned for clarity:
- .Branch  -> Segments (original case), PathSegmentsSanitized (safe), FirstSegmentLower
- .Channel -> Value, Source, SegmentsWithChannelFirst (first replaced by channel)
- .Affix   -> Label, Prefix, Suffix, Separator, LabelCase, HasLabel

.PARAMETER BranchName
Full branch name (e.g., "feature/foo-bar"). Backslashes are normalized to "/".

.PARAMETER MaxSegments
Maximum allowed "/"-separated segments (default 3).

.PARAMETER ForbiddenSegments
Case-insensitive list of forbidden segment values. Default: @('latest').

.PARAMETER RequiredFirstSegments
Case-insensitive allow-list for the first segment. Default covers GitFlow + common prefixes:
main, master, develop, feature, release, hotfix, bugfix, support, fix, chore, docs, build, ci, perf, refactor, style, test.

# Channel resolution:
.PARAMETER ChannelMap
Hashtable mapping first-segment -> channel (case-insensitive). Your entries override defaults.

.PARAMETER DefaultChannel
Channel to use if the first segment is unmapped (unless -ErrorOnMissingChannel). Default: 'no-deploy'.

.PARAMETER ErrorOnMissingChannel
Throw if the first segment is unmapped and no DefaultChannel should be used.

.PARAMETER KnownFirstSegments
Baseline set for completeness validation of ChannelMap. Defaults to the same list as RequiredFirstSegments.

.PARAMETER ValidateChannelMap
Throw if ChannelMap (plus defaults) does not cover all KnownFirstSegments.

# Label/prefix/suffix:
.PARAMETER LabelMap
Hashtable mapping channel -> label (case-insensitive). Your entries override built-in label defaults.

.PARAMETER LabelStyle
Built-in labels when LabelMap isn’t provided: Short | Long
Short: production='', staging='rc', quality='qa', development='dev'   (default)
Long : production='', staging='staging', quality='quality', development='development'

.PARAMETER DefaultLabel
Label to use if a channel has no label mapping (unless -ErrorOnMissingLabel). Default: $null.

.PARAMETER LabelCase
Case for the label: Lower (default), Upper, Preserve.

.PARAMETER Separator
Separator for prefix/suffix around the label. Default: "-".

.PARAMETER IncludeSeparator
Include the separator in Prefix/Suffix. Default: $true.

.PARAMETER NoSuffixChannels
Channels that must never receive a suffix. Default: @('production').

.PARAMETER NoPrefixChannels
Channels that must never receive a prefix. Default: @().

.PARAMETER ErrorOnMissingLabel
Throw if label is missing for the resolved channel and DefaultLabel is $null.

.PARAMETER KnownChannels
Baseline set for completeness validation of LabelMap. Default: @('production','staging','quality','development').

.PARAMETER ValidateLabelMap
Throw if LabelMap (plus defaults) does not cover all KnownChannels.

.OUTPUTS
System.Object (PSCustomObject)
# Sections:
#   .Branch  : @{ Segments; PathSegmentsSanitized; FirstSegmentLower }
#   .Channel : @{ Value; Source; SegmentsWithChannelFirst }
#   .Affix   : @{ Label; Prefix; Suffix; Separator; LabelCase; HasLabel }
#>
    [CmdletBinding()]
    param(
        # --- Branch validation ---
        [Parameter(Mandatory)]
        [string]$BranchName,

        [int]$MaxSegments = 3,
        [string[]]$ForbiddenSegments = @('latest'),

        [string[]]$RequiredFirstSegments = @(
            'main','master','develop','feature','release','hotfix','bugfix','support',
            'fix','chore','docs','build','ci','perf','refactor','style','test'
        ),

        # --- Channel resolution ---
        [hashtable]$ChannelMap,
        [string]$DefaultChannel = 'no-deploy',
        [switch]$ErrorOnMissingChannel,
        [string[]]$KnownFirstSegments = @(
            'main','master','develop','feature','release','hotfix','bugfix','support',
            'fix','chore','docs','build','ci','perf','refactor','style','test'
        ),
        [switch]$ValidateChannelMap,

        # --- Label/prefix/suffix ---
        [hashtable]$LabelMap,
        [ValidateSet('Short','Long')]
        [string]$LabelStyle = 'Short',
        [string]$DefaultLabel = $null,
        [ValidateSet('Lower','Upper','Preserve')]
        [string]$LabelCase = 'Lower',
        [string]$Separator = '-',
        [bool]$IncludeSeparator = $true,
        [string[]]$NoSuffixChannels = @('production'),
        [string[]]$NoPrefixChannels = @(),
        [switch]$ErrorOnMissingLabel,
        [string[]]$KnownChannels = @('production','staging','quality','development'),
        [switch]$ValidateLabelMap
    )

    # =========================
    # 1) Branch validation (preserve original case)
    # =========================
    if ([string]::IsNullOrWhiteSpace($BranchName)) { throw "BranchName is empty." }

    $bn = $BranchName -replace '\\','/'  # normalize slashes only

    if ($bn.StartsWith('/')) { throw "Branch name cannot start with '/'." }
    if ($bn.EndsWith('/'))   { throw "Branch name cannot end with '/'." }
    if ($bn -match '//')     { throw "Branch name cannot contain '//'." }
    if ($bn -match '\.\.')   { throw "Branch name cannot contain '..'." }
    if ($bn -match '@\{')    { throw "Branch name cannot contain '@{'." }
    if ($bn -match '\.lock$'){ throw "Branch name cannot end with '.lock'." }
    if ($bn -match '[~^:?*\[]') { throw "Branch name contains forbidden characters (~ ^ : ? * [ )." }
    if ($bn -match '\\')     { throw "Branch name cannot contain backslash '\'. Use '/' as separator." }
    if ($bn -match '[\x00-\x1F]') { throw "Branch name contains control characters." }

    # Ensure we always have a string[] even for single-segment branches
    $segments = @($bn -split '/' | Where-Object { $_ -ne '' })

    foreach ($seg in $segments) {
        if ($seg -eq '.' -or $seg -eq '..') { throw "Segment '$seg' is invalid ('.' or '..' not allowed)." }
        if ($seg.StartsWith('.')) { throw "Segment '$seg' cannot start with '.'." }
        if ($seg.EndsWith('.'))   { throw "Segment '$seg' cannot end with '.'." }
    }

    if ($segments.Count -gt $MaxSegments) {
        throw "Number of segments ($($segments.Count)) exceeds the maximum allowed ($MaxSegments)."
    }

    # Forbidden segments (case-insensitive)
    $forbid = $ForbiddenSegments | ForEach-Object { $_.ToLowerInvariant() }
    foreach ($seg in $segments) {
        if ($forbid -contains $seg.ToLowerInvariant()) {
            throw "Segment '$seg' is forbidden."
        }
    }

    # Required first segment (case-insensitive)
    if ($segments.Count -ge 1) {
        $allowedFirst = $RequiredFirstSegments | ForEach-Object { $_.ToLowerInvariant() }
        $firstRawLower = ([string]$segments[0]).ToLowerInvariant()
        if ($allowedFirst.Count -gt 0 -and $allowedFirst -notcontains $firstRawLower) {
            $list = ($RequiredFirstSegments -join "', '")
            throw "First segment '$($segments[0])' is not allowed. Allowed first segments: '$list'."
        }
    }

    # Always compute a path-safe version of segments (no case changes)
    $pathSegments = @($segments)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    for ($i = 0; $i -lt $pathSegments.Count; $i++) {
        foreach ($ch in $invalid) {
            $pathSegments[$i] = $pathSegments[$i] -replace ([regex]::Escape([string]$ch)), '_'
        }
        $pathSegments[$i] = $pathSegments[$i] -replace ' ', '_'
    }

    $firstSegmentLower = if ($segments.Count -ge 1) { ([string]$segments[0]).ToLowerInvariant() } else { "" }

    # =========================
    # 2) Channel resolution (case-insensitive)
    # =========================
    $channelDefaults = @{
        'main'    = 'production'
        'master'  = 'production'
        'hotfix'  = 'production'
        'release' = 'staging'
        'develop' = 'quality'
        'bugfix'  = 'quality'
        'fix'     = 'quality'
        'support' = 'quality'
        'feature' = 'development'
        'chore'   = 'development'
        'docs'    = 'development'
        'build'   = 'development'
        'ci'      = 'development'
        'perf'    = 'development'
        'refactor'= 'development'
        'style'   = 'development'
        'test'    = 'development'
    }

    $channelMapEff = @{}
    foreach ($k in $channelDefaults.Keys) { $channelMapEff[$k.ToLowerInvariant()] = $channelDefaults[$k] }
    if ($ChannelMap) {
        foreach ($k in $ChannelMap.Keys) { $channelMapEff[$k.ToLowerInvariant()] = $ChannelMap[$k] }
    }

    if ($ValidateChannelMap) {
        $missing = @()
        foreach ($k in $KnownFirstSegments) {
            if (-not $channelMapEff.ContainsKey($k.ToLowerInvariant())) { $missing += $k }
        }
        if ($missing.Count -gt 0) {
            throw ("ChannelMap is incomplete. Missing mappings for: {0}" -f ($missing -join ', '))
        }
    }

    $channel = $null
    $channelSource = 'Default'
    if ($channelMapEff.ContainsKey($firstSegmentLower)) {
        $channel = [string]$channelMapEff[$firstSegmentLower]

        # Detect user override case-insensitively
        if ($ChannelMap) {
            $userKeysLower = @($ChannelMap.Keys | ForEach-Object { $_.ToLowerInvariant() })
            if ($userKeysLower -contains $firstSegmentLower) { $channelSource = 'Override' }
        }
    } else {
        if ($ErrorOnMissingChannel) { throw ("No channel mapping for first segment '{0}'." -f $firstSegmentLower) }
        $channel = $DefaultChannel
        $channelSource = 'Fallback'
    }

    $segmentsWithChan = @($segments)
    if ($segmentsWithChan.Count -ge 1) { $segmentsWithChan[0] = $channel }

    # =========================
    # 3) Label/Affix generation (case-insensitive mapping; label case optional)
    # =========================
    $labelDefaultsShort = @{
        'production'  = ''
        'staging'     = 'rc'
        'quality'     = 'qa'
        'development' = 'dev'
    }
    $labelDefaultsLong = @{
        'production'  = ''
        'staging'     = 'staging'
        'quality'     = 'quality'
        'development' = 'development'
    }
    $labelDefaults = if ($LabelStyle -eq 'Long') { $labelDefaultsLong } else { $labelDefaultsShort }

    $labelMapEff = @{}
    foreach ($k in $labelDefaults.Keys) { $labelMapEff[$k.ToLowerInvariant()] = $labelDefaults[$k] }
    if ($LabelMap) {
        foreach ($k in $LabelMap.Keys) { $labelMapEff[$k.ToLowerInvariant()] = $LabelMap[$k] }
    }

    if ($ValidateLabelMap) {
        $missingL = @()
        foreach ($k in $KnownChannels) {
            if (-not $labelMapEff.ContainsKey($k.ToLowerInvariant())) { $missingL += $k }
        }
        if ($missingL.Count -gt 0) {
            throw ("LabelMap is incomplete. Missing labels for: {0}" -f ($missingL -join ', '))
        }
    }

    $chLower = $channel.ToLowerInvariant()
    $label = $null
    if ($labelMapEff.ContainsKey($chLower)) {
        $label = [string]$labelMapEff[$chLower]
    } elseif ($PSBoundParameters.ContainsKey('DefaultLabel')) {
        $label = $DefaultLabel
    }
    if ($null -eq $label) {
        if ($ErrorOnMissingLabel) { throw "No label mapping for channel '$channel' and no DefaultLabel provided." }
        $label = ''
    }

    switch ($LabelCase) {
        'Lower'    { $label = $label.ToLowerInvariant() }
        'Upper'    { $label = $label.ToUpperInvariant() }
        'Preserve' { }
    }

    $hasLabel = -not [string]::IsNullOrEmpty($label)

    $noSuffixSet = $NoSuffixChannels | ForEach-Object { $_.ToLowerInvariant() }
    $noPrefixSet = $NoPrefixChannels | ForEach-Object { $_.ToLowerInvariant() }

    $prefix = ''
    $suffix = ''
    if ($hasLabel -and ($noPrefixSet -notcontains $chLower)) {
        $prefix = if ($IncludeSeparator -and $Separator) { "$label$Separator" } else { "$label" }
    }
    if ($hasLabel -and ($noSuffixSet -notcontains $chLower)) {
        $suffix = if ($IncludeSeparator -and $Separator) { "$Separator$label" } else { "$label" }
    }

    # =========================
    # 4) Return SECTIONED object
    # =========================
    $branchSection = [pscustomobject]@{
        Segments               = @($segments)         # original case, non-destructive
        PathSegmentsSanitized  = @($pathSegments)     # safe for filesystem (spaces & invalid chars -> '_')
        FirstSegmentLower      = $firstSegmentLower   # for case-insensitive mapping
    }

    $channelSection = [pscustomobject]@{
        Value                    = $channel
        Source                   = $channelSource     # 'Default' | 'Override' | 'Fallback'
        SegmentsWithChannelFirst = @($segmentsWithChan)
    }

    $affixSection = [pscustomobject]@{
        Label     = $label
        Prefix    = $prefix
        Suffix    = $suffix
        Separator = $Separator
        LabelCase = $LabelCase
        HasLabel  = [bool]$hasLabel
    }

    [pscustomobject]@{
        Branch  = $branchSection
        Channel = $channelSection
        Affix   = $affixSection
    }
}

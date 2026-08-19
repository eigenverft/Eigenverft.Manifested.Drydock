function Copy-DirectoryTreeGitAware {
    <#
    .SYNOPSIS
        Copies a directory tree while respecting Git repositories found below the source path.

    .DESCRIPTION
        Copies a directory tree like a normal recursive copy, but treats Git repositories specially.

        The command is intended for fast backup or staging copies of large directory trees. Files and
        folders outside Git repositories are copied normally. When a Git repository is found, its .git
        metadata is not copied and files ignored by that repository's .gitignore files are left out.

        Git is used only to determine which repository files belong in the copy. Global Git excludes and
        .git/info/exclude are not used. Existing tracked files are copied even when they also match an
        ignore rule.

        The destination uses the same transit.destination.lock lease name as Sync-DirectoryTreeLockSafe.
        This prevents two compatible Drydock copy operations from writing to the same destination at the
        same time. The source is not locked or modified.

        Existing destination files can be skipped when they already match the selected comparison policy.
        No files or directories are removed from the destination.

        Long-running copies write a compact progress line after about 15 seconds and then about every
        15 seconds. Large files also write a status line before the copy starts. This uses normal host
        output so progress remains readable in CI logs; no Write-Progress UI is used.

    .PARAMETER SourceDirectory
        The directory tree to copy.

    .PARAMETER DestinationDirectory
        The directory that receives the copied tree.

    .PARAMETER CopyRetryCount
        Number of retry attempts after the first failed file copy. Default is 3.

    .PARAMETER CopyRetryDelaySeconds
        Delay between file copy retries. Default is 5 seconds.

    .PARAMETER CopyComparisonPolicy
        Controls when an existing destination file can be skipped. Default is LengthAndLastWriteTimeUtc.

    .PARAMETER LockRetryCount
        Number of retries while the destination is leased by another compatible Drydock operation.

    .PARAMETER LockRetryDelaySeconds
        Delay between destination lease retries.

    .PARAMETER LockTokenExpiryHours
        Age after which a stale destination lease may be removed. Default is 12 hours.

    .PARAMETER LogDetailLevel
        Summary writes start, progress, status, warning, and final summary messages. Detailed also writes
        repository, lease, retry, and skip details.

    .EXAMPLE
        Copy-DirectoryTreeGitAware -SourceDirectory 'D:\Programs\Eigenverft.App.McpServer' -DestinationDirectory 'E:\Backup\Eigenverft.App.McpServer'

        Creates a fast backup-style copy. Normal directories are copied recursively; Git metadata and files
        ignored by repository .gitignore files are left out.

    .EXAMPLE
        Copy-DirectoryTreeGitAware -SourceDirectory 'D:\Workspace' -DestinationDirectory 'E:\WorkspaceBackup' -CopyComparisonPolicy Length

        Uses file length to skip destination files that already match the source length.

    .NOTES
        This is the first implementation draft. Directory reparse points are skipped and reported instead
        of being followed, to avoid recursively leaving the requested source tree through junctions or links.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,

        [Parameter()]
        [ValidateRange(0, 100)]
        [int]$CopyRetryCount = 3,

        [Parameter()]
        [ValidateRange(0, 3600)]
        [int]$CopyRetryDelaySeconds = 5,

        [Parameter()]
        [ValidateSet('None', 'Length', 'LengthAndLastWriteTimeUtc', 'Sha256Hash', 'Md5FastHash')]
        [string]$CopyComparisonPolicy = 'LengthAndLastWriteTimeUtc',

        [Parameter()]
        [ValidateRange(0, 100)]
        [int]$LockRetryCount = 10,

        [Parameter()]
        [ValidateRange(0, 3600)]
        [int]$LockRetryDelaySeconds = 30,

        [Parameter()]
        [ValidateRange(1, 87600)]
        [int]$LockTokenExpiryHours = 12,

        [Parameter()]
        [ValidateSet('Detailed', 'Summary')]
        [string]$LogDetailLevel = 'Summary'
    )

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "Git is required for Copy-DirectoryTreeGitAware but was not found in PATH."
    }

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        throw "Source directory '$SourceDirectory' does not exist or is not a directory."
    }

    $sourceRootResolved = (Resolve-Path -LiteralPath $SourceDirectory).ProviderPath
    $destinationRootFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationDirectory)

    $sourceCompare = $sourceRootResolved.TrimEnd('\', '/')
    $destinationCompare = $destinationRootFull.TrimEnd('\', '/')
    $sourcePrefix = $sourceCompare + [System.IO.Path]::DirectorySeparatorChar
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $pathComparison = [System.StringComparison]::OrdinalIgnoreCase
        $pathComparer = [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        $pathComparison = [System.StringComparison]::Ordinal
        $pathComparer = [System.StringComparer]::Ordinal
    }

    if ([string]::Equals($sourceCompare, $destinationCompare, $pathComparison)) {
        throw 'Source and destination paths must be different.'
    }

    if ($destinationCompare.StartsWith($sourcePrefix, $pathComparison)) {
        throw "Destination '$destinationRootFull' must not be inside source '$sourceRootResolved'."
    }

    [System.IO.Directory]::CreateDirectory($destinationRootFull) | Out-Null
    $destinationRootResolved = (Resolve-Path -LiteralPath $destinationRootFull).ProviderPath

    $stats = [PSCustomObject]@{
        DirectoriesVisited    = 0L
        DirectoriesCreated    = 0L
        GitRepositories       = 0L
        GitMetadataSkipped    = 0L
        FilesProcessed        = 0L
        FilesCopied           = 0L
        FilesUnchanged        = 0L
        MissingSourceFiles    = 0L
        CopyRetries           = 0L
        ReparsePointsSkipped  = 0L
    }

    $processedRepositories = New-Object 'System.Collections.Generic.HashSet[string]' ($pathComparer)
    $destinationLockFileName = 'transit.destination.lock'
    $sourceLockBaseName = 'transit.source'
    $destinationLockPath = Join-Path -Path $destinationRootResolved -ChildPath $destinationLockFileName
    $destinationLockToken = [Guid]::NewGuid().ToString('N')
    $destinationLeaseState = [PSCustomObject]@{ Acquired = $false }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $progressState = [PSCustomObject]@{
        IntervalMilliseconds = 15000L
        NextAtMilliseconds   = 15000L
    }
    $largeFileSizeThresholdBytes = [long](200 * 1024 * 1024)

    function local:_Write-Message {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        [Diagnostics.CodeAnalysis.SuppressMessage("PSAvoidUsingWriteHost","")]
        param(
            [Parameter(Mandatory = $true)][string]$Tag,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
        )

        Write-Host "[Copy-DirectoryTreeGitAware] [$Tag] $Message"
    }

    function local:_Write-ProgressMessage {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([string]$CurrentPath)

        $elapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        if ($elapsedMilliseconds -lt $progressState.NextAtMilliseconds) {
            return
        }

        $currentSuffix = ''
        if (-not [string]::IsNullOrWhiteSpace($CurrentPath)) {
            $currentSuffix = " Current: '$CurrentPath'."
        }

        _Write-Message -Tag 'PROGRESS' -Message (
            "Running {0}. Directories visited: {1}; Git repos: {2}; files processed/copied/unchanged: {3}/{4}/{5}; retries: {6}.{7}" -f
            $stopwatch.Elapsed.ToString('hh\:mm\:ss'),
            $stats.DirectoriesVisited,
            $stats.GitRepositories,
            $stats.FilesProcessed,
            $stats.FilesCopied,
            $stats.FilesUnchanged,
            $stats.CopyRetries,
            $currentSuffix
        )

        while ($progressState.NextAtMilliseconds -le $elapsedMilliseconds) {
            $progressState.NextAtMilliseconds = $progressState.NextAtMilliseconds + $progressState.IntervalMilliseconds
        }
    }

    function local:_Write-DetailMessage {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([Parameter(Mandatory = $true)][string]$Message)
        if ($LogDetailLevel -eq 'Detailed') {
            _Write-Message -Tag 'DETAIL' -Message $Message
        }
    }

    function local:_Ensure-Directory {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([Parameter(Mandatory = $true)][string]$Path)

        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            [System.IO.Directory]::CreateDirectory($Path) | Out-Null
            $stats.DirectoriesCreated = $stats.DirectoriesCreated + 1
            _Write-DetailMessage "Created directory '$Path'."
        }
    }

    function local:_Remove-StaleTransitLockIfExpired {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([Parameter(Mandatory = $true)][string]$LockFilePath)

        if (-not (Test-Path -LiteralPath $LockFilePath -PathType Leaf -ErrorAction SilentlyContinue)) {
            return $false
        }

        $expiresUtc = $null
        try {
            $rawContent = Get-Content -LiteralPath $LockFilePath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($rawContent)) {
                try {
                    $jsonObject = ConvertFrom-Json -InputObject $rawContent -ErrorAction Stop
                    $expiresProperty = $jsonObject.PSObject.Properties['ExpiresUtc']
                    if ($null -ne $expiresProperty -and $null -ne $expiresProperty.Value) {
                        $expiresUtc = [DateTime]::Parse(
                            [string]$expiresProperty.Value,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::AdjustToUniversal
                        )
                    }
                }
                catch {
                    _Write-DetailMessage "Transit lease '$LockFilePath' has no usable ExpiresUtc value; falling back to file timestamps."
                }
            }

            if ($null -eq $expiresUtc) {
                $lockInfo = Get-Item -LiteralPath $LockFilePath -Force -ErrorAction Stop
                $timestamp = $lockInfo.LastWriteTimeUtc
                if ($lockInfo.CreationTimeUtc -gt $timestamp) {
                    $timestamp = $lockInfo.CreationTimeUtc
                }
                $expiresUtc = $timestamp.AddHours($LockTokenExpiryHours)
            }
        }
        catch {
            $expiresUtc = [DateTime]::UtcNow.AddSeconds(-1)
        }

        if ([DateTime]::UtcNow -le $expiresUtc) {
            return $false
        }

        Remove-Item -LiteralPath $LockFilePath -Force -ErrorAction Stop
        _Write-DetailMessage "Removed stale transit lease '$LockFilePath'."
        return $true
    }

    function local:_Acquire-DestinationLease {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param()
        $attempt = 0

        while ($true) {
            $writerExists = Test-Path -LiteralPath $destinationLockPath -PathType Leaf -ErrorAction SilentlyContinue
            if ($writerExists) {
                if (_Remove-StaleTransitLockIfExpired -LockFilePath $destinationLockPath) {
                    $writerExists = $false
                }
            }

            $readerExists = $false
            $readerItems = @(Get-ChildItem -LiteralPath $destinationRootResolved -File -Force -ErrorAction SilentlyContinue)
            foreach ($readerItem in $readerItems) {
                if ([string]::Equals($readerItem.Name, $sourceLockBaseName, $pathComparison) -or
                    $readerItem.Name.StartsWith($sourceLockBaseName + '.', $pathComparison)) {
                    if (-not (_Remove-StaleTransitLockIfExpired -LockFilePath $readerItem.FullName)) {
                        $readerExists = $true
                    }
                }
            }

            if (-not $writerExists -and -not $readerExists) {
                $stream = $null
                try {
                    $stream = New-Object System.IO.FileStream(
                        $destinationLockPath,
                        [System.IO.FileMode]::CreateNew,
                        [System.IO.FileAccess]::Write,
                        [System.IO.FileShare]::None
                    )

                    $nowUtc = [DateTime]::UtcNow
                    $payload = [PSCustomObject]@{
                        CreatedUtc = $nowUtc.ToString('o')
                        ExpiresUtc = $nowUtc.AddHours($LockTokenExpiryHours).ToString('o')
                        Token      = $destinationLockToken
                    }
                    $json = $payload | ConvertTo-Json -Compress
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                    $destinationLeaseState.Acquired = $true
                    _Write-DetailMessage "Acquired destination lease '$destinationLockPath'."
                    return
                }
                catch [System.IO.IOException] {
                    _Write-DetailMessage 'Destination lease CreateNew race detected; retrying through the normal lease checks.'
                }
                finally {
                    if ($null -ne $stream) {
                        $stream.Dispose()
                    }
                }
            }

            if ($attempt -ge $LockRetryCount) {
                throw "Destination '$destinationRootResolved' is still leased after $LockRetryCount retries."
            }

            $attempt = $attempt + 1
            _Write-DetailMessage "Destination is leased; waiting $LockRetryDelaySeconds seconds (attempt $attempt of $LockRetryCount)."
            if ($LockRetryDelaySeconds -gt 0) {
                Start-Sleep -Seconds $LockRetryDelaySeconds
            }
            _Write-ProgressMessage -CurrentPath $destinationRootResolved
        }
    }

    function local:_Release-DestinationLease {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param()
        if (-not $destinationLeaseState.Acquired) {
            return
        }

        if (-not (Test-Path -LiteralPath $destinationLockPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            return
        }

        try {
            $rawContent = Get-Content -LiteralPath $destinationLockPath -Raw -ErrorAction Stop
            $jsonObject = ConvertFrom-Json -InputObject $rawContent -ErrorAction Stop
            $tokenProperty = $jsonObject.PSObject.Properties['Token']
            if ($null -eq $tokenProperty -or [string]$tokenProperty.Value -ne $destinationLockToken) {
                _Write-Message -Tag 'WARNING' -Message "Destination lease '$destinationLockPath' changed owner; it will not be removed by this process."
                return
            }

            Remove-Item -LiteralPath $destinationLockPath -Force -ErrorAction Stop
            _Write-DetailMessage "Released destination lease '$destinationLockPath'."
        }
        catch {
            _Write-Message -Tag 'WARNING' -Message "Failed to release destination lease '$destinationLockPath': $($_.Exception.Message)"
        }
    }

    function local:_Test-DestinationFileMatch {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        [Diagnostics.CodeAnalysis.SuppressMessage("PSAvoidUsingBrokenHashAlgorithms","")]
        param(
            [Parameter(Mandatory = $true)][string]$SourceFullPath,
            [Parameter(Mandatory = $true)][string]$DestinationFullPath
        )

        if ($CopyComparisonPolicy -eq 'None' -or -not (Test-Path -LiteralPath $DestinationFullPath -PathType Leaf)) {
            return $false
        }

        $sourceInfo = Get-Item -LiteralPath $SourceFullPath -Force -ErrorAction Stop
        $destinationInfo = Get-Item -LiteralPath $DestinationFullPath -Force -ErrorAction Stop

        switch ($CopyComparisonPolicy) {
            'Length' {
                return ([long]$sourceInfo.Length -eq [long]$destinationInfo.Length)
            }
            'LengthAndLastWriteTimeUtc' {
                return (([long]$sourceInfo.Length -eq [long]$destinationInfo.Length) -and
                    ($sourceInfo.LastWriteTimeUtc -eq $destinationInfo.LastWriteTimeUtc))
            }
            'Sha256Hash' {
                $sourceHash = (Get-FileHash -LiteralPath $SourceFullPath -Algorithm SHA256 -ErrorAction Stop).Hash
                $destinationHash = (Get-FileHash -LiteralPath $DestinationFullPath -Algorithm SHA256 -ErrorAction Stop).Hash
                return ($sourceHash -eq $destinationHash)
            }
            'Md5FastHash' {
                $sourceHash = (Get-FileHash -LiteralPath $SourceFullPath -Algorithm MD5 -ErrorAction Stop).Hash
                $destinationHash = (Get-FileHash -LiteralPath $DestinationFullPath -Algorithm MD5 -ErrorAction Stop).Hash
                return ($sourceHash -eq $destinationHash)
            }
        }

        return $false
    }

    function local:_Copy-OneFile {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)][string]$SourceFullPath,
            [Parameter(Mandatory = $true)][string]$DestinationFullPath
        )

        $stats.FilesProcessed = $stats.FilesProcessed + 1
        _Write-ProgressMessage -CurrentPath $SourceFullPath

        try {
            if (_Test-DestinationFileMatch -SourceFullPath $SourceFullPath -DestinationFullPath $DestinationFullPath) {
                $stats.FilesUnchanged = $stats.FilesUnchanged + 1
                _Write-DetailMessage "Skipped unchanged file '$SourceFullPath'."
                return
            }
        }
        catch {
            _Write-DetailMessage "Comparison failed for '$SourceFullPath'; proceeding with copy. $($_.Exception.Message)"
        }

        $destinationParent = Split-Path -Path $DestinationFullPath -Parent
        if (-not [string]::IsNullOrEmpty($destinationParent)) {
            _Ensure-Directory -Path $destinationParent
        }

        try {
            $sourceInfoBeforeCopy = Get-Item -LiteralPath $SourceFullPath -Force -ErrorAction Stop
            if ([long]$sourceInfoBeforeCopy.Length -ge $largeFileSizeThresholdBytes) {
                $sizeMB = [Math]::Round(([double]$sourceInfoBeforeCopy.Length / 1MB), 1)
                _Write-Message -Tag 'STATUS' -Message "Copying large file (about $sizeMB MB), this may take a while: '$SourceFullPath'."
            }
        }
        catch {
            _Write-DetailMessage "Could not read file size before copy for '$SourceFullPath'. $($_.Exception.Message)"
        }

        $maxAttempts = $CopyRetryCount + 1
        $attempt = 0

        while ($attempt -lt $maxAttempts) {
            try {
                Copy-Item -LiteralPath $SourceFullPath -Destination $DestinationFullPath -Force -ErrorAction Stop

                try {
                    $sourceInfoAfterCopy = Get-Item -LiteralPath $SourceFullPath -Force -ErrorAction Stop
                    $destinationInfoAfterCopy = Get-Item -LiteralPath $DestinationFullPath -Force -ErrorAction Stop
                    $destinationInfoAfterCopy.LastWriteTimeUtc = $sourceInfoAfterCopy.LastWriteTimeUtc
                    $destinationInfoAfterCopy.CreationTimeUtc = $sourceInfoAfterCopy.CreationTimeUtc
                }
                catch {
                    _Write-Message -Tag 'WARNING' -Message "Copied '$SourceFullPath' but failed to preserve timestamps: $($_.Exception.Message)"
                }

                $stats.FilesCopied = $stats.FilesCopied + 1
                _Write-ProgressMessage -CurrentPath $SourceFullPath
                return
            }
            catch {
                $attempt = $attempt + 1
                if ($attempt -ge $maxAttempts) {
                    throw "Failed to copy '$SourceFullPath' to '$DestinationFullPath' after $maxAttempts attempts. $($_.Exception.Message)"
                }

                $stats.CopyRetries = $stats.CopyRetries + 1
                _Write-DetailMessage "Copy attempt $attempt of $maxAttempts failed for '$SourceFullPath'; waiting $CopyRetryDelaySeconds seconds."
                if ($CopyRetryDelaySeconds -gt 0) {
                    Start-Sleep -Seconds $CopyRetryDelaySeconds
                }
            }
        }
    }

    function local:_Get-GitRepositoryFileList {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param([Parameter(Mandatory = $true)][string]$RepositoryPath)

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $gitCommand.Source
        $startInfo.WorkingDirectory = $RepositoryPath
        $startInfo.Arguments = 'ls-files --cached --others --exclude-per-directory=.gitignore -z'
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true

        try {
            $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        }
        catch {
            _Write-DetailMessage 'Redirected Git stream encoding could not be set explicitly on this runtime.'
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo

        try {
            if (-not $process.Start()) {
                throw "Failed to start Git for repository '$RepositoryPath'."
            }

            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()

            if ($process.ExitCode -ne 0) {
                throw "Git failed for repository '$RepositoryPath' with exit code $($process.ExitCode). $stderr"
            }

            return @($stdout -split "`0" | Where-Object { -not [string]::IsNullOrEmpty($_) })
        }
        finally {
            $process.Dispose()
        }
    }

    function local:_Copy-GitRepository {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)][string]$RepositorySourcePath,
            [Parameter(Mandatory = $true)][string]$RepositoryDestinationPath
        )

        $repositoryResolved = (Resolve-Path -LiteralPath $RepositorySourcePath).ProviderPath
        if (-not $processedRepositories.Add($repositoryResolved)) {
            return
        }

        $stats.GitRepositories = $stats.GitRepositories + 1
        $stats.GitMetadataSkipped = $stats.GitMetadataSkipped + 1
        _Write-DetailMessage "Git repository found at '$repositoryResolved'."
        _Ensure-Directory -Path $RepositoryDestinationPath

        $repositoryFiles = @(_Get-GitRepositoryFileList -RepositoryPath $repositoryResolved)
        _Write-ProgressMessage -CurrentPath $repositoryResolved
        foreach ($relativeGitPath in $repositoryFiles) {
            $relativeFileSystemPath = $relativeGitPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $sourcePath = Join-Path -Path $repositoryResolved -ChildPath $relativeFileSystemPath
            $destinationPath = Join-Path -Path $RepositoryDestinationPath -ChildPath $relativeFileSystemPath

            if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
                _Copy-OneFile -SourceFullPath $sourcePath -DestinationFullPath $destinationPath
                continue
            }

            if (Test-Path -LiteralPath $sourcePath -PathType Container) {
                $nestedGitMarker = Join-Path -Path $sourcePath -ChildPath '.git'
                if (Test-Path -LiteralPath $nestedGitMarker) {
                    _Copy-GitRepository -RepositorySourcePath $sourcePath -RepositoryDestinationPath $destinationPath
                }
                continue
            }

            $stats.MissingSourceFiles = $stats.MissingSourceFiles + 1
            _Write-DetailMessage "Git listed '$sourcePath', but the file no longer exists; skipping it."
        }
    }

    function local:_Walk-Directory {
        [Diagnostics.CodeAnalysis.SuppressMessage("PSUseApprovedVerbs","")]
        param(
            [Parameter(Mandatory = $true)][string]$CurrentSourcePath,
            [Parameter(Mandatory = $true)][string]$CurrentDestinationPath
        )

        $stats.DirectoriesVisited = $stats.DirectoriesVisited + 1
        _Write-ProgressMessage -CurrentPath $CurrentSourcePath

        $gitMarker = Join-Path -Path $CurrentSourcePath -ChildPath '.git'
        if (Test-Path -LiteralPath $gitMarker) {
            _Copy-GitRepository -RepositorySourcePath $CurrentSourcePath -RepositoryDestinationPath $CurrentDestinationPath
            return
        }

        _Ensure-Directory -Path $CurrentDestinationPath

        $items = @(Get-ChildItem -LiteralPath $CurrentSourcePath -Force -ErrorAction Stop)
        foreach ($item in $items) {
            if ([string]::Equals($item.Name, '.git', $pathComparison)) {
                continue
            }

            $destinationPath = Join-Path -Path $CurrentDestinationPath -ChildPath $item.Name

            if ($item.PSIsContainer) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $stats.ReparsePointsSkipped = $stats.ReparsePointsSkipped + 1
                    _Write-Message -Tag 'WARNING' -Message "Skipping directory reparse point '$($item.FullName)' in first implementation draft."
                    continue
                }

                _Walk-Directory -CurrentSourcePath $item.FullName -CurrentDestinationPath $destinationPath
            }
            else {
                _Copy-OneFile -SourceFullPath $item.FullName -DestinationFullPath $destinationPath
            }
        }
    }

    _Write-Message -Tag 'START' -Message "Copying '$sourceRootResolved' to '$destinationRootResolved' with comparison policy '$CopyComparisonPolicy'."

    try {
        _Acquire-DestinationLease
        _Walk-Directory -CurrentSourcePath $sourceRootResolved -CurrentDestinationPath $destinationRootResolved

        $stopwatch.Stop()
        _Write-Message -Tag 'SUMMARY' -Message (
            "Completed in {0}. Directories visited/created: {1}/{2}; Git repos: {3}; files processed/copied/unchanged/missing: {4}/{5}/{6}/{7}; retries: {8}; reparse points skipped: {9}. From: {10} To: {11}" -f
            $stopwatch.Elapsed,
            $stats.DirectoriesVisited,
            $stats.DirectoriesCreated,
            $stats.GitRepositories,
            $stats.FilesProcessed,
            $stats.FilesCopied,
            $stats.FilesUnchanged,
            $stats.MissingSourceFiles,
            $stats.CopyRetries,
            $stats.ReparsePointsSkipped,
            $SourceDirectory,
            $DestinationDirectory
        )
    }
    finally {
        if ($stopwatch.IsRunning) {
            $stopwatch.Stop()
        }
        _Release-DestinationLease
    }
}


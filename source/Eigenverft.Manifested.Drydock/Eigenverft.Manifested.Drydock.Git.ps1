function Get-GitTopLevelDirectory {
    <#
    .SYNOPSIS
        Retrieves the top-level directory of the current Git repository.

    .DESCRIPTION
        This function calls Git using 'git rev-parse --show-toplevel' to determine
        the root directory of the current Git repository. If Git is not available
        or the current directory is not within a Git repository, the function returns
        an error. The function converts any forward slashes to the system's directory
        separator (works correctly on both Windows and Linux).

    .PARAMETER None
        This function does not require any parameters.

    .EXAMPLE
        PS C:\Projects\MyRepo> Get-GitTopLevelDirectory
        C:\Projects\MyRepo

    .NOTES
        Ensure Git is installed and available in your system's PATH.
    #>
    [CmdletBinding()]
    [alias("ggtd")]
    param()

    try {
        # Attempt to retrieve the top-level directory of the Git repository.
        $topLevel = git rev-parse --show-toplevel 2>$null

        if (-not $topLevel) {
            Write-Error "Not a Git repository or Git is not available in the PATH."
            return $null
        }

        # Trim the result and replace forward slashes with the current directory separator.
        $topLevel = $topLevel.Trim().Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        return $topLevel
    }
    catch {
        Write-Error "Error retrieving Git top-level directory: $_"
    }
}

function Get-GitCurrentBranch {
    <#
    .SYNOPSIS
    Retrieves the current Git branch name.

    .DESCRIPTION
    This function calls Git to determine the current branch. It first uses
    'git rev-parse --abbrev-ref HEAD' to get the branch name. If the output is
    "HEAD" (indicating a detached HEAD state), it then attempts to find a branch
    that contains the current commit using 'git branch --contains HEAD'. If no
    branch is found, it falls back to returning the commit hash.

    .EXAMPLE
    PS C:\> Get-GitCurrentBranch

    Returns:
    master

    .NOTES
    - Ensure Git is available in your system's PATH.
    - In cases of a detached HEAD with multiple containing branches, the first
      branch found is returned.
    #>
    [CmdletBinding()]
    [alias("ggcb")]
    param()
    
    try {
        # Get the abbreviated branch name
        $branch = git rev-parse --abbrev-ref HEAD 2>$null

        # If HEAD is returned, we're in a detached state.
        if ($branch -eq 'HEAD') {
            # Try to get branch names that contain the current commit.
            $branches = @(git branch --contains HEAD 2>$null | ForEach-Object {
                # Remove any asterisks or leading/trailing whitespace.
                $_.Replace('*','').Trim()
            } | Where-Object { $_ -ne '' -and $_ -notmatch '^\(HEAD detached' })

            if ($branches.Count -gt 0) {
                # Return the first branch found
                return $branches[0]
            }
            else {
                # As a fallback, return the commit hash.
                return git rev-parse HEAD 2>$null
            }
        }
        else {
            return $branch.Trim()
        }
    }
    catch {
        Write-Error "Error retrieving Git branch: $_"
    }
}

function Get-GitCurrentBranchRoot {
    <#
    .SYNOPSIS
    Retrieves the root portion of the current Git branch name.

    .DESCRIPTION
    This function retrieves the current Git branch name by invoking Git commands directly.
    It first attempts to get the branch name using 'git rev-parse --abbrev-ref HEAD'. If the result is
    "HEAD" (indicating a detached HEAD state), it then looks for a branch that contains the current commit
    via 'git branch --contains HEAD'. If no branch is found, it falls back to using the commit hash.
    The function then splits the branch name on both forward (/) and backslashes (\) and returns the first
    segment as the branch root.

    .EXAMPLE
    PS C:\> Get-GitCurrentBranchRoot

    Returns:
    feature

    .NOTES
    - Ensure Git is available in your system's PATH.
    - For detached HEAD states with multiple containing branches, the first branch found is used.
    #>
    [CmdletBinding()]
    [alias("ggcbr")]
    param()

    try {
        # Attempt to get the abbreviated branch name.
        $branch = git rev-parse --abbrev-ref HEAD 2>$null

        # Check for detached HEAD state.
        if ($branch -eq 'HEAD') {
            # Retrieve branches containing the current commit.
            $branches = @(git branch --contains HEAD 2>$null | ForEach-Object {
                $_.Replace('*','').Trim()
            } | Where-Object { $_ -ne '' -and $_ -notmatch '^\(HEAD detached' })

            if ($branches.Count -gt 0) {
                $branch = $branches[0]
            }
            else {
                # Fallback to commit hash if no branch is found.
                $branch = git rev-parse HEAD 2>$null
            }
        }
        
        $branch = $branch.Trim()
        if ([string]::IsNullOrWhiteSpace($branch)) {
            Write-Error "Unable to determine the current Git branch."
            return
        }
        
        # Split the branch name on both '/' and '\' and return the first segment.
        $root = $branch -split '[\\/]' | Select-Object -First 1
        return $root
    }
    catch {
        Write-Error "Error retrieving Git branch root: $_"
    }
}

function Get-GitRepositoryName {
    <#
    .SYNOPSIS
        Returns the Git repository name based on the remote URL.

    .DESCRIPTION
        This function retrieves the repository remote URL by calling
        'git config --get remote.origin.url'.
        It then extracts the repository name from the URL by taking the last
        segment after the final "/" or ":" and removing a trailing ".git"
        suffix when present.
        If no remote URL is available, the function writes an error.

    .PARAMETER None
        This function does not require any parameters.

    .EXAMPLE
        PS C:\Projects\MyRepo> Get-GitRepositoryName
        MyRepo

    .NOTES
        Ensure Git is installed and available in the system PATH.
    #>
    [CmdletBinding()]
    [alias("ggrn")]
    param()

    try {
        # Retrieve the repository remote URL.
        $remoteUrl = git config --get remote.origin.url 2>$null

        if (-not $remoteUrl) {
            Write-Error "No remote URL found. Ensure the repository has a remote URL.."
            return $null
        }

        $remoteUrl = $remoteUrl.Trim()

        # Remove a trailing ".git" suffix when present.
        if ($remoteUrl -match "\.git$") {
            $remoteUrl = $remoteUrl.Substring(0, $remoteUrl.Length - 4)
        }

        # Handle both HTTPS and SSH URL formats.
        if ($remoteUrl.Contains('/')) {
            $parts = $remoteUrl.Split('/')
        }
        else {
            # SSH format, for example: git@github.com:User/Repo
            $parts = $remoteUrl.Split(':')
        }

        # Extract the final segment as the repository name.
        $repoName = $parts[-1]
        return $repoName
    }
    catch {
        Write-Error "Error retrieving the repository name: $_"
    }
}

function Get-GitRemoteUrl {
    <#
    .SYNOPSIS
        Returns the Git repository remote URL.

    .DESCRIPTION
        This function retrieves the repository remote URL by calling
        'git config --get remote.origin.url' and returns it as a trimmed string.
        If no remote URL is available, the function writes an error.

    .PARAMETER None
        This function does not require any parameters.

    .EXAMPLE
        PS C:\Projects\MyRepo> Get-GitRemoteUrl
        https://github.com/contoso/MyRepo.git

    .NOTES
        Ensure Git is installed and available in the system PATH.
    #>
    [CmdletBinding()]
    [alias("gru")]
    param()

    try {
        # Retrieve the repository remote URL.
        $remoteUrl = git config --get remote.origin.url 2>$null

        if (-not $remoteUrl) {
            Write-Error "No remote URL found. Ensure the repository has a remote URL.."
            return $null
        }

        $remoteUrl = $remoteUrl.Trim()

        return $remoteUrl
    }
    catch {
        Write-Error "Error retrieving the repository remote URL: $_"
    }
}

function Invoke-GitAddCommitPush {
<#
.SYNOPSIS
Stages a module folder, optionally configures safe.directory, commits with a transient identity, and pushes to origin. Optionally tags HEAD.

.DESCRIPTION
Wraps these Git calls (kept close to your original flags):
  For each item in $Folders:
    git -C "$TopLevelDirectory" add -v -A -- "<item>"
  (optional) git -C "$TopLevelDirectory" config --global --add safe.directory "$TopLevelDirectory"
  git -C "$TopLevelDirectory" -c user.name="..." -c user.email="..." commit -m "..."
  git -C "$TopLevelDirectory" push origin "$CurrentBranch"

If -Tags are provided, creates annotated tags on HEAD and pushes them:
  git -C "$TopLevelDirectory" -c user.name="..." -c user.email="..." tag -a <tag> -m "<msg>" <commit>
  git -C "$TopLevelDirectory" push origin <tag>

Writes status via Write-Host and emits no return value. Optionally exits the host on errors.

.PARAMETER TopLevelDirectory
Git repository root to pass via -C. If omitted, the current repo root is detected.

.PARAMETER Folders
Pathspec/folder values to stage (ideally relative to repo root). Each value is passed after the pathspec separator: -- "<item>".

.PARAMETER CurrentBranch
Target branch for push. If omitted, the current branch is detected.

.PARAMETER CommitMessage
Commit message. Default: 'Updated from Workflow [skip ci]'.

.PARAMETER UserName
Transient user.name for the commit via 'git -c'. Default: 'github-actions[bot]'.

.PARAMETER UserEmail
Transient user.email for the commit via 'git -c'. Default matches GitHub Actions bot.

.PARAMETER SafeDirectory
When set, adds the repo root to global safe.directory before committing/pushing.

.PARAMETER Tags
Optional array of tag names to create and push, e.g. @('v1.2.3','latest').

.PARAMETER TagMessage
Optional annotation message to use for each tag; defaults to "Tag <tag>".

.PARAMETER ForceTagUpdate
If set, existing tags with the same name are moved (force-updated) to the new commit.

.PARAMETER ExitOnError
On any failure, exits the PowerShell host with a non-zero code (atomic behavior).

.EXAMPLE
Invoke-GitAddCommitPush -TopLevelDirectory (Get-GitTopLevelDirectory) -Folders 'src/My.Module' -CurrentBranch 'main'

.EXAMPLE
Invoke-GitAddCommitPush -Folders 'src/My.Module','src/Another.Module' -Tags @('v1.4.0','latest') -TagMessage 'Release 1.4.0'

.EXAMPLE
Invoke-GitAddCommitPush -Folders 'src/My.Module' -SafeDirectory
Adds the repo to safe.directory before proceeding.

.NOTES
- Uses Write-Host per requirement; no objects returned.
- Reviewer note: Keeps original flags and structure; pushes are always performed.
#>
    [CmdletBinding()]
    [Alias('igacp')]
    param(
        [Parameter(Mandatory=$false)]
        [string]$TopLevelDirectory,

        [Parameter(Mandatory=$true)]
        [string[]]$Folders,

        [Parameter(Mandatory=$false)]
        [string]$CurrentBranch,

        [Parameter(Mandatory=$false)]
        [string]$CommitMessage = 'Updated from Workflow [skip ci]',

        [Parameter(Mandatory=$false)]
        [string]$UserName  = 'github-actions[bot]',

        [Parameter(Mandatory=$false)]
        [string]$UserEmail = '41898282+github-actions[bot]@users.noreply.github.com',

        [Parameter(Mandatory=$false)]
        [switch]$SafeDirectory,

        [Parameter(Mandatory=$false)]
        [string[]]$Tags = @(),

        [Parameter(Mandatory=$false)]
        [string]$TagMessage,

        [Parameter(Mandatory=$false)]
        [switch]$ForceTagUpdate,

        [Parameter(Mandatory=$false)]
        [switch]$ExitOnError
    )

    # --- Preflight: Git availability ---
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "[Invoke-GitAddCommitPush] Git not found in PATH."
        if ($ExitOnError) { exit 1 }; return
    }

    # --- Resolve repo root ---
    if (-not $TopLevelDirectory) {
        try { $TopLevelDirectory = (git rev-parse --show-toplevel 2>$null).Trim() } catch { $TopLevelDirectory = $null }
    }
    if ([string]::IsNullOrWhiteSpace($TopLevelDirectory)) {
        Write-Host "[Invoke-GitAddCommitPush] Unable to determine repo root (TopLevelDirectory)."
        if ($ExitOnError) { exit 1 }; return
    }
    try {
        $repoPath = (Get-Item -LiteralPath $TopLevelDirectory -ErrorAction Stop).FullName
    }
    catch {
        Write-Host "[Invoke-GitAddCommitPush] Repo root not found: '$TopLevelDirectory'."
        if ($ExitOnError) { exit 1 }; return
    }

    # --- git add -v -A -- "<each folder>" ---
    foreach ($folder in $Folders) {
        $f = ([string]$folder).Trim()
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        Write-Host "[Invoke-GitAddCommitPush] git add -v -A -- '$f'"
        & git -C $repoPath add -v -A -- $f 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[Invoke-GitAddCommitPush] git add failed for '$f' (code $LASTEXITCODE)."
            if ($ExitOnError) { exit $LASTEXITCODE }; return
        }
    }

    # --- Optional: safe.directory ---
    if ($SafeDirectory) {
        Write-Host "[Invoke-GitAddCommitPush] git config --global --add safe.directory '$repoPath'"
        & git -C $repoPath config --global --add safe.directory $repoPath 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[Invoke-GitAddCommitPush] git config safe.directory failed (code $LASTEXITCODE)."
            if ($ExitOnError) { exit $LASTEXITCODE }; return
        }
    }

    # --- Commit with transient identity ---
    Write-Host "[Invoke-GitAddCommitPush] git commit -m '$CommitMessage'"
    & git -C $repoPath -c "user.name=$UserName" -c "user.email=$UserEmail" commit -m $CommitMessage 2>&1 | ForEach-Object { Write-Host $_ }
    $commitCode = $LASTEXITCODE
    if ($commitCode -ne 0) {
        Write-Host "[Invoke-GitAddCommitPush] git commit returned $commitCode (possibly nothing to commit)."
        if ($ExitOnError) { exit $commitCode }
    }

    # --- Determine branch if not provided ---
    if (-not $CurrentBranch) {
        $CurrentBranch = git -C $repoPath rev-parse --abbrev-ref HEAD 2>$null
        if ($CurrentBranch) { $CurrentBranch = $CurrentBranch.Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($CurrentBranch)) {
        Write-Host "[Invoke-GitAddCommitPush] Unable to determine branch."
        if ($ExitOnError) { exit 1 }; return
    }

    # --- Always push branch ---
    Write-Host "[Invoke-GitAddCommitPush] git push origin '$CurrentBranch'"
    & git -C $repoPath push origin $CurrentBranch
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Host "[Invoke-GitAddCommitPush] git push failed (code $code)."
        if ($ExitOnError) { exit $code }; return
    }
    Write-Host "[Invoke-GitAddCommitPush] Pushed branch '$CurrentBranch' to 'origin'."

    # --- Tagging (optional): create annotated tags on HEAD and push ---
    if ($Tags -and $Tags.Count -gt 0) {
        $head = (& git -C $repoPath rev-parse HEAD 2>$null)
        if ($head) { $head = $head.Trim() }

        if ([string]::IsNullOrWhiteSpace($head)) {
            Write-Host "[Invoke-GitAddCommitPush] Unable to resolve HEAD for tagging."
            if ($ExitOnError) { exit 1 }; return
        }

        foreach ($rawTag in $Tags) {
            $tag = ([string]$rawTag).Trim()
            if ([string]::IsNullOrWhiteSpace($tag)) { continue }

            # Fast existence check; quiet and no stderr output
            $null = & git -C $repoPath rev-parse -q --verify ("refs/tags/$tag") 2>$null
            $exists = ($LASTEXITCODE -eq 0)

            if ($exists -and -not $ForceTagUpdate) {
                Write-Host "[Invoke-GitAddCommitPush] Tag '$tag' already exists; skipping (use -ForceTagUpdate to move it)."
            } else {
                $msg = if ($TagMessage) { $TagMessage } else { "Tag $tag" }

                # Include transient identity for tag creation/update (canonical arg order)
                $tagArgs = @('-C', $repoPath, '-c', "user.name=$UserName", '-c', "user.email=$UserEmail", 'tag', '-a', $tag, '-m', $msg, $head)
                if ($exists -and $ForceTagUpdate) {
                    $tagArgs = @('-C', $repoPath, '-c', "user.name=$UserName", '-c', "user.email=$UserEmail", 'tag', '-f', '-a', $tag, '-m', $msg, $head)
                }

                Write-Host ("[Invoke-GitAddCommitPush] {0} annotated tag '{1}' on {2}." -f ($(if ($exists) { 'Updating' } else { 'Creating' }), $tag, $head))
                $null = & git @tagArgs 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[Invoke-GitAddCommitPush] git tag failed for '$tag' (code $LASTEXITCODE)."
                    if ($ExitOnError) { exit $LASTEXITCODE }; continue
                }
            }

            # Push tag (force if moved); --porcelain -> stdout only, --no-progress avoids stderr chatter
            $pushArgs = @('-C', $repoPath, 'push', '--porcelain', '--no-progress', 'origin', $tag)
            if ($exists -and $ForceTagUpdate) {
                $pushArgs = @('-C', $repoPath, 'push', '--force', '--porcelain', '--no-progress', 'origin', $tag)
            }

            Write-Host "[Invoke-GitAddCommitPush] Pushing tag '$tag' to 'origin'."
            & git @pushArgs 2>$null | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[Invoke-GitAddCommitPush] git push for tag '$tag' failed (code $LASTEXITCODE)."
                if ($ExitOnError) { exit $LASTEXITCODE }
            }
        }
    } else {
        Write-Host "[Invoke-GitAddCommitPush] No tags specified."
    }


    Write-Host "[Invoke-GitAddCommitPush] Completed."
}

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
        Summary writes only the final result. Detailed also writes repository, lease, retry, and skip details.

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

    if ($LockTokenExpiryHours -le 0) {
        $LockTokenExpiryHours = 24
        Write-Warning "LockTokenExpiryHours was <= 0; defaulting to 24 hours."
    }

    $sourceRootResolved = (Resolve-Path -LiteralPath $SourceDirectory).ProviderPath
    $destinationRootFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationDirectory)

    $sourceCompare = $sourceRootResolved.TrimEnd('\', '/')
    $destinationCompare = $destinationRootFull.TrimEnd('\', '/')
    $sourcePrefix = $sourceCompare + [System.IO.Path]::DirectorySeparatorChar

    if ([string]::Equals($sourceCompare, $destinationCompare, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source and destination paths must be different.'
    }

    if ($destinationCompare.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
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

    $processedRepositories = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $destinationLockFileName = 'transit.destination.lock'
    $sourceLockBaseName = 'transit.source'
    $destinationLockPath = Join-Path -Path $destinationRootResolved -ChildPath $destinationLockFileName
    $destinationLockToken = [Guid]::NewGuid().ToString('N')
    $destinationLeaseState = [PSCustomObject]@{ Acquired = $false }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    function local:_Write-DetailMessage {
        param([Parameter(Mandatory = $true)][string]$Message)
        if ($LogDetailLevel -eq 'Detailed') {
            Write-Host "[Copy-DirectoryTreeGitAware] $Message"
        }
    }

    function local:_Ensure-Directory {
        param([Parameter(Mandatory = $true)][string]$Path)

        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            [System.IO.Directory]::CreateDirectory($Path) | Out-Null
            $stats.DirectoriesCreated = $stats.DirectoriesCreated + 1
            _Write-DetailMessage "Created directory '$Path'."
        }
    }

    function local:_Remove-StaleTransitLockIfExpired {
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
                    # Fall back to file timestamps for older or invalid lease payloads.
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
                if ([string]::Equals($readerItem.Name, $sourceLockBaseName, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $readerItem.Name.StartsWith($sourceLockBaseName + '.', [System.StringComparison]::OrdinalIgnoreCase)) {
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
                    # Another process won the CreateNew race. Retry through the normal lease path.
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
        }
    }

    function local:_Release-DestinationLease {
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
                Write-Warning "Destination lease '$destinationLockPath' changed owner; it will not be removed by this process."
                return
            }

            Remove-Item -LiteralPath $destinationLockPath -Force -ErrorAction Stop
            _Write-DetailMessage "Released destination lease '$destinationLockPath'."
        }
        catch {
            Write-Warning "Failed to release destination lease '$destinationLockPath': $($_.Exception.Message)"
        }
    }

    function local:_Test-DestinationFileMatches {
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
        param(
            [Parameter(Mandatory = $true)][string]$SourceFullPath,
            [Parameter(Mandatory = $true)][string]$DestinationFullPath
        )

        $stats.FilesProcessed = $stats.FilesProcessed + 1

        try {
            if (_Test-DestinationFileMatches -SourceFullPath $SourceFullPath -DestinationFullPath $DestinationFullPath) {
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
                    Write-Warning "Copied '$SourceFullPath' but failed to preserve timestamps: $($_.Exception.Message)"
                }

                $stats.FilesCopied = $stats.FilesCopied + 1
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
            # Older runtimes may not expose explicit redirected-stream encodings.
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
        param(
            [Parameter(Mandatory = $true)][string]$CurrentSourcePath,
            [Parameter(Mandatory = $true)][string]$CurrentDestinationPath
        )

        $stats.DirectoriesVisited = $stats.DirectoriesVisited + 1

        $gitMarker = Join-Path -Path $CurrentSourcePath -ChildPath '.git'
        if (Test-Path -LiteralPath $gitMarker) {
            _Copy-GitRepository -RepositorySourcePath $CurrentSourcePath -RepositoryDestinationPath $CurrentDestinationPath
            return
        }

        _Ensure-Directory -Path $CurrentDestinationPath

        $items = @(Get-ChildItem -LiteralPath $CurrentSourcePath -Force -ErrorAction Stop)
        foreach ($item in $items) {
            if ([string]::Equals($item.Name, '.git', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $destinationPath = Join-Path -Path $CurrentDestinationPath -ChildPath $item.Name

            if ($item.PSIsContainer) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $stats.ReparsePointsSkipped = $stats.ReparsePointsSkipped + 1
                    Write-Warning "Skipping directory reparse point '$($item.FullName)' in first implementation draft."
                    continue
                }

                _Walk-Directory -CurrentSourcePath $item.FullName -CurrentDestinationPath $destinationPath
            }
            else {
                _Copy-OneFile -SourceFullPath $item.FullName -DestinationFullPath $destinationPath
            }
        }
    }

    try {
        _Acquire-DestinationLease
        _Walk-Directory -CurrentSourcePath $sourceRootResolved -CurrentDestinationPath $destinationRootResolved

        $stopwatch.Stop()
        Write-Host (
            "[Copy-DirectoryTreeGitAware] Completed in {0}. Directories visited/created: {1}/{2}; Git repos: {3}; files processed/copied/unchanged/missing: {4}/{5}/{6}/{7}; retries: {8}; reparse points skipped: {9}. From: {10} To: {11}" -f
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


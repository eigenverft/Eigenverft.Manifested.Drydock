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
            $branches = git branch --contains HEAD 2>$null | ForEach-Object {
                # Remove any asterisks or leading/trailing whitespace.
                $_.Replace('*','').Trim()
            } | Where-Object { $_ -ne '' }

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
            $branches = git branch --contains HEAD 2>$null | ForEach-Object {
                $_.Replace('*','').Trim()
            } | Where-Object { $_ -ne '' }

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
        Gibt den Namen des Git-Repositories anhand der Remote-URL zurück.

    .DESCRIPTION
        Diese Funktion ruft über 'git config --get remote.origin.url' die Remote-URL des Repositories ab.
        Anschließend wird der Repository-Name aus der URL extrahiert, indem der letzte Teil der URL (nach dem letzten "/" oder ":")
        entnommen und eine eventuell vorhandene ".git"-Endung entfernt wird.
        Sollte keine Remote-URL vorhanden sein, wird ein Fehler ausgegeben.

    .PARAMETER None
        Diese Funktion benötigt keine Parameter.

    .EXAMPLE
        PS C:\Projects\MyRepo> Get-GitRepositoryName
        MyRepo

    .NOTES
        Stelle sicher, dass Git installiert ist und in deinem Systempfad verfügbar ist.
    #>
    [CmdletBinding()]
    [alias("ggrn")]
    param()

    try {
        # Remote-URL des Repositories abrufen
        $remoteUrl = git config --get remote.origin.url 2>$null

        if (-not $remoteUrl) {
            Write-Error "No remote URL found. Ensure the repository has a remote URL.."
            return $null
        }

        $remoteUrl = $remoteUrl.Trim()

        # Entferne eine eventuell vorhandene ".git"-Endung
        if ($remoteUrl -match "\.git$") {
            $remoteUrl = $remoteUrl.Substring(0, $remoteUrl.Length - 4)
        }

        # Unterscheidung zwischen URL-Formaten (HTTPS/SSH)
        if ($remoteUrl.Contains('/')) {
            $parts = $remoteUrl.Split('/')
        }
        else {
            # SSH-Format: z.B. git@github.com:User/Repo
            $parts = $remoteUrl.Split(':')
        }

        # Letztes Element als Repository-Name extrahieren
        $repoName = $parts[-1]
        return $repoName
    }
    catch {
        Write-Error "Fehler beim Abrufen des Repository-Namens: $_"
    }
}

function Get-GitRemoteUrl {
    <#
    .SYNOPSIS
        Gibt den Namen des Git-Repositories anhand der Remote-URL zurück.

    .DESCRIPTION
        Diese Funktion ruft über 'git config --get remote.origin.url' die Remote-URL des Repositories ab.
        Anschließend wird der Repository-Name aus der URL extrahiert, indem der letzte Teil der URL (nach dem letzten "/" oder ":")
        entnommen und eine eventuell vorhandene ".git"-Endung entfernt wird.
        Sollte keine Remote-URL vorhanden sein, wird ein Fehler ausgegeben.

    .PARAMETER None
        Diese Funktion benötigt keine Parameter.

    .EXAMPLE
        PS C:\Projects\MyRepo> Get-GitRepositoryName
        MyRepo

    .NOTES
        Stelle sicher, dass Git installiert ist und in deinem Systempfad verfügbar ist.
    #>
    [CmdletBinding()]
    [alias("gru")]
    param()

    try {
        # Remote-URL des Repositories abrufen
        $remoteUrl = git config --get remote.origin.url 2>$null

        if (-not $remoteUrl) {
            Write-Error "No remote URL found. Ensure the repository has a remote URL.."
            return $null
        }

        $remoteUrl = $remoteUrl.Trim()

        return $remoteUrl
    }
    catch {
        Write-Error "Fehler beim Abrufen des Repository-Namens: $_"
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
        $head = git -C $repoPath rev-parse HEAD 2>$null
        if ($head) { $head = $head.Trim() }

        if ([string]::IsNullOrWhiteSpace($head)) {
            Write-Host "[Invoke-GitAddCommitPush] Unable to resolve HEAD for tagging."
            if ($ExitOnError) { exit 1 }; return
        }

        foreach ($rawTag in $Tags) {
            $tag = ([string]$rawTag).Trim()
            if ([string]::IsNullOrWhiteSpace($tag)) { continue }

            & git -C $repoPath show-ref --tags --verify --quiet ("refs/tags/$tag")
            $exists = ($LASTEXITCODE -eq 0)

            if ($exists -and -not $ForceTagUpdate) {
                Write-Host "[Invoke-GitAddCommitPush] Tag '$tag' already exists; skipping (use -ForceTagUpdate to move it)."
            } else {
                $msg = if ($TagMessage) { $TagMessage } else { "Tag $tag" }

                # >>> CHANGE: include transient identity for tag object creation/update
                $tagArgs = @('-C', $repoPath, '-c', "user.name=$UserName", '-c', "user.email=$UserEmail", 'tag', '-a', $tag, $head, '-m', $msg)
                if ($exists -and $ForceTagUpdate) {
                    $tagArgs = @('-C', $repoPath, '-c', "user.name=$UserName", '-c', "user.email=$UserEmail", 'tag', '-f', '-a', $tag, $head, '-m', $msg)
                }

                Write-Host ("[Invoke-GitAddCommitPush] {0} annotated tag '{1}' on {2}." -f ($(if ($exists) { 'Updating' } else { 'Creating' }), $tag, $head))
                & git @tagArgs 2>&1 | ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[Invoke-GitAddCommitPush] git tag failed for '$tag' (code $LASTEXITCODE)."
                    if ($ExitOnError) { exit $LASTEXITCODE }; continue
                }
            }

            # Push tag (force if moved)
            $pushArgs = @('-C', $repoPath, 'push', 'origin', $tag)
            if ($exists -and $ForceTagUpdate) { $pushArgs = @('-C', $repoPath, 'push', '--force', 'origin', $tag) }

            Write-Host "[Invoke-GitAddCommitPush] Pushing tag '$tag' to 'origin'."
            & git @pushArgs 2>&1 | ForEach-Object { Write-Host $_ }
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


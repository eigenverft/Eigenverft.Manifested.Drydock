function Find-FilesByPattern {
    <#
    .SYNOPSIS
        Recursively searches a directory for files matching a specified pattern.
    .DESCRIPTION
        This function searches the specified directory and all its subdirectories for files
        that match the provided filename pattern (e.g., "*.txt", "*.sln", "*.csproj").
        It returns an array of matching FileInfo objects, which can be iterated with a ForEach loop.
    .PARAMETER Path
        The root directory where the search should begin.
    .PARAMETER Pattern
        The filename pattern to search for (e.g., "*.txt", "*.sln", "*.csproj").
    .EXAMPLE
        $files = Find-FilesByPattern -Path "C:\MyProjects" -Pattern "*.txt"
        foreach ($file in $files) {
            Write-Output $file.FullName
        }
    #>
    [CmdletBinding()]
    [alias("ffbp")]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    # Validate that the provided path exists and is a directory.
    if (-not (Test-Path -Path $Path -PathType Container)) {
        throw "The specified path '$Path' does not exist or is not a directory."
    }

    try {
        # Recursively search for files matching the given pattern.
        $results = Get-ChildItem -Path $Path -Filter $Pattern -Recurse -File -ErrorAction Stop
        return $results
    }
    catch {
        Write-Error "An error occurred while searching for files: $_"
    }
}
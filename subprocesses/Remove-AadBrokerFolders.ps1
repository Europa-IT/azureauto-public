# Standalone script for removing personal Azure join

# This runs elevated over folders the profile owner can write to, so a junction or symlink planted in
# (or swapped into) the tree must never redirect a delete or attribute change outside it.
$ReparsePoint = [System.IO.FileAttributes]::ReparsePoint
$BlockingAttributes = [System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Hidden

# True if $Path or any of its ancestors is currently a reparse point. Reads attributes fresh from disk.
function Test-ReparsePointInPath {
    param([string]$Path)

    $Current = $Path
    while ($Current) {
        if ([System.IO.File]::GetAttributes($Current) -band $ReparsePoint) {
            return $true
        }
        $Current = [System.IO.Path]::GetDirectoryName($Current)
    }
    return $false
}

# Deletes a single file, directory or link without recursing. Refuses if any parent has become a
# reparse point since enumeration. A link is deleted as the link itself and its attributes are left alone.
function Remove-SingleItem {
    param([System.IO.FileSystemInfo]$Item)

    if (Test-ReparsePointInPath ([System.IO.Path]::GetDirectoryName($Item.FullName))) {
        throw "A parent of $($Item.FullName) is a reparse point."
    }

    $Attributes = [System.IO.File]::GetAttributes($Item.FullName)
    if (-not ($Attributes -band $ReparsePoint) -and ($Attributes -band $BlockingAttributes)) {
        [System.IO.File]::SetAttributes($Item.FullName, $Attributes -band -bnot $BlockingAttributes)
    }

    if ($Item -is [System.IO.DirectoryInfo]) {
        [System.IO.Directory]::Delete($Item.FullName, $false)
    } else {
        [System.IO.File]::Delete($Item.FullName)
    }
}

# Removes everything it can beneath $Directory, depth first, without descending into reparse points.
# Adds paths that could not be removed to $Failed and returns $true only if the directory is now empty.
function Remove-DirectoryContents {
    param([System.IO.DirectoryInfo]$Directory, [System.Collections.Generic.List[string]]$Failed)

    try {
        if (Test-ReparsePointInPath $Directory.FullName) {
            throw "$($Directory.FullName) or a parent is a reparse point."
        }
        $Entries = @($Directory.EnumerateFileSystemInfos())
    } catch {
        $Failed.Add("$($Directory.FullName) (could not enumerate)")
        return $false
    }

    $AllRemoved = $true
    foreach ($Entry in $Entries) {
        if ($Entry -is [System.IO.DirectoryInfo] -and -not ($Entry.Attributes -band $ReparsePoint)) {
            # A directory that still holds a failed child is left in place without being reported itself.
            if (-not (Remove-DirectoryContents -Directory $Entry -Failed $Failed)) {
                $AllRemoved = $false
                continue
            }
        }
        try {
            Remove-SingleItem -Item $Entry
        } catch {
            $Failed.Add($Entry.FullName)
            $AllRemoved = $false
        }
    }
    return $AllRemoved
}

# Removes everything it can beneath $Root, then $Root itself. Returns the paths that could not be removed.
function Remove-FolderBestEffort {
    param([System.IO.DirectoryInfo]$Root)

    $Failed = [System.Collections.Generic.List[string]]::new()
    if ($Root.Attributes -band $ReparsePoint) {
        $Failed.Add("$($Root.FullName) (is a reparse point, skipped)")
    } elseif (Remove-DirectoryContents -Directory $Root -Failed $Failed) {
        try {
            Remove-SingleItem -Item $Root
        } catch {
            $Failed.Add($Root.FullName)
        }
    }
    return ,$Failed.ToArray()
}

$BrokerFolders = @(& "$PSScriptRoot\Get-AadBrokerFolders.ps1")
Write-Host "Found $(@($BrokerFolders).Count) AAD broker folder(s) to remove."

$PartialRemovals = @()
foreach ($Folder in $BrokerFolders) {
    $Failed = Remove-FolderBestEffort -Root $Folder
    if ($Failed.Count -eq 0) {
        Write-Host "Removed: $($Folder.FullName)"
    } else {
        Write-Host "Partially removed: $($Folder.FullName) ($($Failed.Count) item(s) left in place)"
        $Failed | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
        if ($Failed.Count -gt 10) {
            Write-Host "    ...and $($Failed.Count - 10) more"
        }
        $PartialRemovals += $Folder.FullName
    }
}

if ($PartialRemovals.Count -gt 0) {
    Write-Host "Warning: The following AAD broker folders could not be fully removed (may need manual removal after restart):"
    $PartialRemovals | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "All AAD broker folders removed successfully."
}

Read-Host "User AAD key removal complete, press Enter to restart"
Restart-Computer -Force

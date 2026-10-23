<#
.SYNOPSIS
    Creates a sibling working folder of the current repo, from the latest base branch, and cd's into it.
    With -Remove, safely deletes such a folder again.

.DESCRIPTION
    Run from anywhere inside a git repo (any subfolder). The new folder is created next to the
    repo's top-level folder and named <RepoName>.<Name>, where RepoName comes from the origin
    remote URL (e.g. https://github.com/org/Four75.git -> Four75).

    Example: inside E:\git\git37\Four75.Smw\src\Web
        gitclone name1   ->   E:\git\git37\Four75.name1

    Default mode is a git worktree on a new branch <Name> started from origin/<Base>
    (fast, shares objects with the current repo). Use -Clone for a fully independent clone.

    gitclone -Remove <folder> undoes it. For a worktree it runs `git worktree remove` and then
    deletes the worktree's branch if that branch is merged into its base (the branch's upstream,
    else origin's default branch) - including when it was squash-merged, which `git branch -d`
    alone cannot tell. Otherwise it keeps the branch and lists the commits that are not merged.
    For a clone it deletes the folder.
    Either way it refuses when there are uncommitted or untracked changes (and, for a clone,
    unpushed commits or stashes) unless -Force is given.

.PARAMETER Name
    Suffix of the new folder; also the new branch name in worktree mode.

.PARAMETER Base
    Branch to start from. Defaults to the origin's default branch (origin/HEAD), else master.

.PARAMETER Clone
    Make a full independent clone of <Base> instead of a worktree.

.PARAMETER Remove
    Folder to remove: a path, or just the folder name (resolved from the current directory, or as
    a sibling of the repo you are in).

.PARAMETER Force
    With -Remove: discard uncommitted changes, delete an unmerged branch, delete a clone with
    unpushed commits.

.PARAMETER Help
    Show this help.

.PARAMETER Version
    Show the gitclone version.

.EXAMPLE
    gitclone name1
.EXAMPLE
    gitclone name1 -Clone
.EXAMPLE
    gitclone name1 -Base develop
.EXAMPLE
    gitclone -Remove Four75.name1
.EXAMPLE
    gitclone -help
.EXAMPLE
    gitclone -version
#>
[CmdletBinding(DefaultParameterSetName = 'Create', SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Create')][string]$Name,
    [Parameter(ParameterSetName = 'Create')][string]$Base,
    [Parameter(ParameterSetName = 'Create')][switch]$Clone,
    [Parameter(Mandatory, ParameterSetName = 'Remove')][string]$Remove,
    [Parameter(ParameterSetName = 'Remove')][switch]$Force,
    [Parameter(Mandatory, ParameterSetName = 'Help')][switch]$Help,
    [Parameter(Mandatory, ParameterSetName = 'Version')][switch]$Version
)

# Bump on every change to this script (semver: fix -> patch, new behaviour -> minor, breaking -> major).
$GitcloneVersion = '1.1.0'

if ($Help) { Get-Help $PSCommandPath -Detailed; return }
if ($Version) { "gitclone $GitcloneVersion"; return }

function Get-RepoRoot([string]$Path) {
    $top = git -C $Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { [IO.Path]::GetFullPath($top) }
}

function Get-Worktrees([string]$Path) {
    @(git -C $Path worktree list --porcelain | Where-Object { $_ -like 'worktree *' } |
        ForEach-Object { [IO.Path]::GetFullPath($_.Substring(9)).TrimEnd('\') })
}

# The ref a branch is measured against: its upstream, else origin's default branch, else origin/master.
function Get-BaseRef([string]$Path, [string]$Branch) {
    $up = git -C $Path rev-parse --abbrev-ref --symbolic-full-name "$Branch@{upstream}" 2>$null
    if ($LASTEXITCODE -eq 0 -and $up) { return $up }
    $head = git -C $Path symbolic-ref --short refs/remotes/origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $head) { $head } else { 'origin/master' }
}

# True when everything $Branch changed since it left $Base is already in $Base: either $Branch is an
# ancestor of $Base, or $Base contains one commit whose patch equals the branch squashed into a single
# commit (a squash merge; `git branch -d` cannot see that because the branch's commits are not ancestors).
function Test-MergedInto([string]$Path, [string]$Branch, [string]$Base) {
    git -C $Path merge-base --is-ancestor $Branch $Base 2>$null
    if ($LASTEXITCODE -eq 0) { return $true }
    $mergeBase = git -C $Path merge-base $Base $Branch 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    $tree = git -C $Path rev-parse "$Branch^{tree}"
    $squash = git -C $Path commit-tree $tree -p $mergeBase -m "squash of $Branch"
    $cherry = @(git -C $Path cherry $Base $squash 2>$null)
    return ($LASTEXITCODE -eq 0) -and ($cherry.Count -eq 1) -and ($cherry[0] -like '-*')
}

if ($PSCmdlet.ParameterSetName -eq 'Remove') {
    $target = $null
    if (Test-Path -LiteralPath $Remove -PathType Container) {
        $target = (Resolve-Path -LiteralPath $Remove).ProviderPath
    } else {
        $here = Get-RepoRoot (Get-Location).Path
        if ($here) {
            $sibling = Join-Path (Split-Path $here -Parent) $Remove
            if (Test-Path -LiteralPath $sibling -PathType Container) { $target = (Resolve-Path -LiteralPath $sibling).ProviderPath }
        }
    }
    if (-not $target) { Write-Error "Folder '$Remove' not found."; return }
    $target = $target.TrimEnd('\')

    if ((Get-RepoRoot $target) -ne $target) { Write-Error "'$target' is not the top folder of a git repository."; return }

    $worktrees = @(Get-Worktrees $target)
    $main = $worktrees[0]
    $isWorktree = $main -ne $target
    if (-not $isWorktree -and $worktrees.Count -gt 1) {
        Write-Error "'$target' is a main repository with other worktrees attached ($($worktrees[1..($worktrees.Count - 1)] -join ', ')). Remove those first."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($target, 'Remove')) { return }

    # Can't delete the folder we're standing in.
    $cwd = (Get-Location).Path.TrimEnd('\')
    if ($cwd -eq $target -or $cwd.StartsWith("$target\", [StringComparison]::OrdinalIgnoreCase)) {
        Set-Location -LiteralPath (Split-Path $target -Parent)
    }

    if ($isWorktree) {
        $branch = git -C $target branch --show-current
        $out = if ($Force) { git -C $main worktree remove --force $target 2>&1 } else { git -C $main worktree remove $target 2>&1 }
        if ($LASTEXITCODE -ne 0) {
            if ((Get-Worktrees $main) -contains $target) {
                $out | ForEach-Object { Write-Host "$_" }
                Write-Error "Not removed: '$target' has uncommitted or untracked changes. Commit/stash them, or use -Force."
                return
            }
            # git passed its checks and unregistered the worktree, but stopped deleting at something it
            # can't remove on Windows (e.g. an npm-workspace junction in node_modules). Finish the job.
            Remove-Item -LiteralPath $target -Recurse -Force
            if (Test-Path -LiteralPath $target) { Write-Error "Unregistered the worktree, but could not fully delete '$target' (a file may be in use)."; return }
        }
        Write-Host "Removed worktree $target" -ForegroundColor Green
        if ($branch) {
            if ($Force) {
                git -C $main branch -D $branch 2>$null
                Write-Host "Deleted branch $branch" -ForegroundColor Green
            } else {
                $base = Get-BaseRef $main $branch
                if ($base -match '^([^/]+)/(.+)$') { git -C $main fetch --quiet $Matches[1] $Matches[2] 2>$null }   # best effort: judge against an up-to-date base
                if (Test-MergedInto $main $branch $base) {
                    git -C $main branch -D $branch 2>$null
                    Write-Host "Deleted branch $branch (merged into $base)" -ForegroundColor Green
                } else {
                    $unmerged = @(git -C $main log --oneline "$base..$branch" 2>$null)
                    Write-Warning ("Kept branch '$branch': it has commits not in ${base}:`n  " + ($unmerged -join "`n  ") + "`nDelete it with: git branch -D $branch")
                }
            }
        }
    } else {
        if (-not $Force) {
            $problems = @()
            if (git -C $target status --porcelain) { $problems += 'uncommitted or untracked changes' }
            if (git -C $target log --branches --not --remotes --oneline) { $problems += 'unpushed commits' }
            if (git -C $target stash list) { $problems += 'stashes' }
            if ($problems) { Write-Error "Not removed: clone '$target' has $($problems -join ', '). Use -Force to delete anyway."; return }
        }
        Remove-Item -LiteralPath $target -Recurse -Force
        Write-Host "Removed clone $target" -ForegroundColor Green
    }
    return
}

$root = Get-RepoRoot (Get-Location).Path
if (-not $root) { Write-Error 'Not inside a git repository.'; return }

$url = git -C $root remote get-url origin 2>$null
if ($LASTEXITCODE -ne 0 -or -not $url) { Write-Error "Repository '$root' has no 'origin' remote."; return }

# https://github.com/org/Four75.git, git@github.com:org/Four75.git, or a local path -> Four75
$repo = ($url.TrimEnd('/', '\') -split '[/\\:]')[-1] -replace '\.git$', ''
$target = Join-Path (Split-Path $root -Parent) "$repo.$Name"
if (Test-Path -LiteralPath $target) { Write-Error "'$target' already exists."; return }

if (-not $Base) {
    $originHead = git -C $root symbolic-ref --short refs/remotes/origin/HEAD 2>$null
    $Base = if ($LASTEXITCODE -eq 0 -and $originHead) { $originHead -replace '^origin/', '' } else { 'master' }
}

if ($Clone) {
    git clone --branch $Base $url $target
} else {
    git -C $root fetch origin $Base
    if ($LASTEXITCODE -ne 0) { Write-Error "Could not fetch '$Base' from origin."; return }
    git -C $root worktree add -b $Name $target "origin/$Base"
}
if ($LASTEXITCODE -ne 0) { Write-Error 'git failed; see output above.'; return }

Set-Location -LiteralPath $target
Write-Host "Now in $target ($(if ($Clone) { "clone of $Base" } else { "worktree, branch $Name from origin/$Base" }))" -ForegroundColor Green

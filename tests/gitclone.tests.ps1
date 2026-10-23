# End-to-end tests for gitclone.ps1 against a throwaway local "origin" (no network, no real repos).
# Run: pwsh -NoProfile -File tests\gitclone.tests.ps1
$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path $PSScriptRoot -Parent
$env:PATH = "$scriptDir;$env:PATH"   # invoke as `gitclone`, exactly as from PATH

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "gitclone-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$failures = 0
$checks = 0
$expectedChecks = 39
function Check([string]$what, [bool]$ok) {
    $script:checks++
    if ($ok) { Write-Host "PASS  $what" -ForegroundColor Green }
    else { Write-Host "FAIL  $what" -ForegroundColor Red; $script:failures++ }
}
function GitQ { git -c user.name=test -c user.email=test@example.com @args 2>&1 | Out-Null }

try {
    # origin: bare repo named Four75.git with one commit on master
    $origin = Join-Path $sandbox 'remote\Four75.git'
    GitQ init --bare --initial-branch=master $origin
    $seed = Join-Path $sandbox 'seed'
    GitQ clone $origin $seed
    Set-Content (Join-Path $seed 'a.txt') 'one'
    GitQ -C $seed add .
    GitQ -C $seed commit -m one
    GitQ -C $seed push origin master

    # the user's working copy, on a feature branch, in a folder named differently from the repo
    $parent = Join-Path $sandbox 'git37'
    $work = Join-Path $parent 'Four75.Smw'
    GitQ clone $origin $work
    GitQ -C $work switch -c smw
    New-Item -ItemType Directory (Join-Path $work 'src\Web') | Out-Null

    # origin master moves on after the working copy was cloned -> gitclone must fetch it
    Set-Content (Join-Path $seed 'b.txt') 'two'
    GitQ -C $seed add .
    GitQ -C $seed commit -m two
    GitQ -C $seed push origin master
    $latest = git -C $seed rev-parse HEAD

    # 1. worktree mode from a subfolder
    Set-Location (Join-Path $work 'src\Web')
    gitclone name1 *> $null
    $t1 = Join-Path $parent 'Four75.name1'
    Check 'worktree: folder created as sibling <repo>.<name>' (Test-Path $t1)
    Check 'worktree: cd into new folder' ((Get-Location).Path -eq $t1)
    Check 'worktree: on new branch name1' ((git -C $t1 branch --show-current) -eq 'name1')
    Check 'worktree: at latest origin/master' ((git -C $t1 rev-parse HEAD) -eq $latest)
    Check 'worktree: original folder untouched' ((git -C $work branch --show-current) -eq 'smw')

    # 2. clone mode
    Set-Location $work
    gitclone name2 -Clone *> $null
    $t2 = Join-Path $parent 'Four75.name2'
    Check 'clone: cd into new folder' ((Get-Location).Path -eq $t2)
    Check 'clone: independent .git directory' (Test-Path (Join-Path $t2 '.git') -PathType Container)
    Check 'clone: on master at latest' (((git -C $t2 branch --show-current) -eq 'master') -and ((git -C $t2 rev-parse HEAD) -eq $latest))

    # 3. existing target is refused, location unchanged
    Set-Location $work
    gitclone name1 -ErrorVariable err -ErrorAction SilentlyContinue *> $null
    Check 'existing target: error reported' ($err.Count -gt 0 -and "$err" -match 'already exists')
    Check 'existing target: location unchanged' ((Get-Location).Path -eq $work)

    # 4. outside a repo is refused
    Set-Location $sandbox
    gitclone name3 -ErrorVariable err -ErrorAction SilentlyContinue *> $null
    Check 'outside repo: error reported' ($err.Count -gt 0 -and "$err" -match 'Not inside a git repository')
    Check 'outside repo: nothing created' (-not (Test-Path (Join-Path $sandbox 'Four75.name3')))

    function Branches { @(git -C $work branch --format='%(refname:short)') }

    # 5. remove a clean worktree from its parent folder (outside any repo), lower-case name
    Set-Location $parent
    gitclone -Remove four75.name1 *> $null
    Check 'remove worktree: folder gone' (-not (Test-Path $t1))
    Check 'remove worktree: branch deleted' ((Branches) -notcontains 'name1')
    Check 'remove worktree: unregistered from repo' (@(git -C $work worktree list).Count -eq 1)

    # 6. dirty worktree is refused, then removed with -Force
    Set-Location $work
    gitclone name4 *> $null
    $t4 = Join-Path $parent 'Four75.name4'
    Set-Content (Join-Path $t4 'untracked.txt') 'x'
    Set-Location $parent
    gitclone -Remove Four75.name4 -ErrorVariable err -ErrorAction SilentlyContinue *> $null
    Check 'dirty worktree: error reported' ($err.Count -gt 0 -and "$err" -match 'uncommitted or untracked')
    Check 'dirty worktree: folder kept' (Test-Path (Join-Path $t4 'untracked.txt'))
    gitclone -Remove Four75.name4 -Force *> $null
    Check 'dirty worktree -Force: folder and branch gone' ((-not (Test-Path $t4)) -and ((Branches) -notcontains 'name4'))

    # 7. worktree with an unmerged commit: folder removed, branch kept with a warning
    Set-Location $work
    gitclone name5 *> $null
    $t5 = Join-Path $parent 'Four75.name5'
    Set-Content (Join-Path $t5 'c.txt') 'three'
    GitQ -C $t5 add .
    GitQ -C $t5 commit -m three
    Set-Location $parent
    gitclone -Remove Four75.name5 -WarningVariable warn *> $null
    Check 'unmerged worktree: folder gone' (-not (Test-Path $t5))
    Check 'unmerged worktree: branch kept with warning' (((Branches) -contains 'name5') -and "$warn" -match 'not in origin/master')
    Check 'unmerged worktree: warning lists the unmerged commits' ("$warn" -match '\b[0-9a-f]{7,} three\b')

    # 8. remove from inside the worktree itself: steps out to the parent first
    Set-Location $work
    gitclone name7 *> $null
    $t7 = Join-Path $parent 'Four75.name7'
    New-Item -ItemType Directory (Join-Path $t7 'sub') | Out-Null
    Set-Location (Join-Path $t7 'sub')
    gitclone -Remove $t7 *> $null
    Check 'remove from inside: folder gone' (-not (Test-Path $t7))
    Check 'remove from inside: moved to parent' ((Get-Location).Path -eq $parent)

    # 9. bare folder name resolved as a sibling while standing in the original repo
    Set-Location $work
    gitclone name8 *> $null
    Set-Location (Join-Path $work 'src\Web')
    gitclone -Remove Four75.name8 *> $null
    Check 'remove sibling by name from inside original repo' (-not (Test-Path (Join-Path $parent 'Four75.name8')))

    # 10. clean clone is deleted
    Set-Location $parent
    gitclone -Remove Four75.name2 *> $null
    Check 'remove clean clone: folder gone' (-not (Test-Path $t2))

    # 11. clone with an unpushed commit is refused
    Set-Location $work
    gitclone name6 -Clone *> $null
    $t6 = Join-Path $parent 'Four75.name6'
    Set-Content (Join-Path $t6 'd.txt') 'four'
    GitQ -C $t6 add .
    GitQ -C $t6 commit -m four
    Set-Location $parent
    gitclone -Remove Four75.name6 -ErrorVariable err -ErrorAction SilentlyContinue *> $null
    Check 'unpushed clone: error reported' ($err.Count -gt 0 -and "$err" -match 'unpushed commits')
    Check 'unpushed clone: folder kept' (Test-Path $t6)

    # 12. the original repo with worktrees attached is refused
    Set-Location $work
    gitclone name9 *> $null
    Set-Location $parent
    gitclone -Remove Four75.Smw -ErrorVariable err -ErrorAction SilentlyContinue *> $null
    Check 'main repo with worktrees: refused, kept' (($err.Count -gt 0 -and "$err" -match 'other worktrees') -and (Test-Path $work))

    # 13. a plain folder that is not a repo is refused
    New-Item -ItemType Directory (Join-Path $parent 'plain') | Out-Null
    gitclone -Remove plain -ErrorVariable err -ErrorAction SilentlyContinue *> $null
    Check 'non-repo folder: refused, kept' (($err.Count -gt 0 -and "$err" -match 'not the top folder') -and (Test-Path (Join-Path $parent 'plain')))

    # 14. -WhatIf changes nothing
    gitclone -Remove Four75.name9 -WhatIf *> $null
    Check '-WhatIf: folder kept' (Test-Path (Join-Path $parent 'Four75.name9'))

    # 15. worktree with an npm-workspace junction in ignored node_modules pointing at a folder git deletes first
    Add-Content (Join-Path $work '.git\info\exclude') "node_modules/`napps/"
    Set-Location $work
    gitclone name10 *> $null
    $t10 = Join-Path $parent 'Four75.name10'
    New-Item -ItemType Directory (Join-Path $t10 'apps\admin') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path $t10 'node_modules\@smw') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $t10 'node_modules\@smw\admin') -Target (Join-Path $t10 'apps\admin') | Out-Null
    Set-Location $parent
    gitclone -Remove Four75.name10 -ErrorVariable err -ErrorAction SilentlyContinue *> $null
    Check 'junction in node_modules: no error, folder and branch gone' (($err.Count -eq 0) -and (-not (Test-Path $t10)) -and ((Branches) -notcontains 'name10'))

    # 16. worktree whose commits were squash-merged into origin/master: branch deleted, no warning
    Set-Location $work
    gitclone name11 *> $null
    $t11 = Join-Path $parent 'Four75.name11'
    Set-Content (Join-Path $t11 'e.txt') 'five'
    GitQ -C $t11 add .
    GitQ -C $t11 commit -m five
    Set-Content (Join-Path $t11 'e.txt') 'six'
    GitQ -C $t11 add .
    GitQ -C $t11 commit -m six
    GitQ -C $t11 push origin name11
    GitQ -C $seed fetch origin
    GitQ -C $seed merge --squash origin/name11
    GitQ -C $seed commit -m 'feat: five and six (squashed)'
    GitQ -C $seed push origin master
    Set-Location $parent
    gitclone -Remove Four75.name11 -WarningVariable warn *> $null
    Check 'squash-merged worktree: folder gone' (-not (Test-Path $t11))
    Check 'squash-merged worktree: branch deleted' ((Branches) -notcontains 'name11')
    Check 'squash-merged worktree: no warning' ($warn.Count -eq 0)

    # 17. -help shows usage and does nothing else
    $before = (Get-Location).Path
    $help = gitclone -help | Out-String
    Check '-help: shows synopsis, parameters and examples' (($help -match 'SYNOPSIS') -and ($help -match '-Remove') -and ($help -match 'gitclone name1 -Clone'))
    Check '-help: location unchanged' ((Get-Location).Path -eq $before)

    # 18. -version prints the version declared in the script and does nothing else
    $declared = (Select-String -Path (Join-Path $scriptDir 'gitclone.ps1') -Pattern '^\$GitcloneVersion = ''([^'']+)''').Matches[0].Groups[1].Value
    $ver = gitclone -version | Out-String
    Check '-version: prints gitclone <semver>' ($ver.Trim() -match '^gitclone \d+\.\d+\.\d+$')
    Check '-version: matches the version declared in the script' ($ver.Trim() -eq "gitclone $declared")
    Check '-version: location unchanged' ((Get-Location).Path -eq $before)
}
finally {
    Set-Location ([IO.Path]::GetTempPath())
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}

if ($checks -ne $expectedChecks) { Write-Host "Only $checks of $expectedChecks checks ran" -ForegroundColor Red; exit 1 }
if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green

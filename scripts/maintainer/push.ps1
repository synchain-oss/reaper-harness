#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
#
# Push the current sub-branch: only HEAD:refs/heads/feat/<slug>. There is no force option; long-lived branches and a
# detached HEAD are refused; an already pushed branch may only fast-forward. Before anything is sent:
#   - the gh credential resolves to the maintainer (GH_TOKEN of this process) and origin's push URL names that
#     maintainer and this repository (git's credential helper picks the credential by the user name in the URL);
#   - the working tree is clean (the commits are what is pushed);
#   - every new commit (not on origin/feature/v1, not on the remote branch) has the maintainer as author and committer
#     and passes the message rules of scripts/check-commits.mjs (subject, sign-off, no AI attribution, privacy);
#   - scripts/check-privacy.mjs --commits finds nothing in those commits;
#   - the pinned gitleaks finds nothing in them (HARNESS_GITLEAKS / git config harness.gitleaks).
# The push itself goes through the pre-push hook as usual; there is no --no-verify.
#   pwsh scripts/maintainer/push.ps1 [-Repo <worktree>]
#   pwsh scripts/maintainer/push.ps1 -SelfTest

[CmdletBinding()]
param([switch]$SelfTest, [string]$Repo)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/HarnessGh.psm1') -Force

$FieldSep = [string][char]0x1f
$RecordSep = [string][char]0x1e
$Maintainer = 'DLsnows'
$MaintainerEmail = 'noreply@synchain.ca'

<# git remote get-url --push has already expanded pushurl and pushInsteadOf: it is the address git push really uses. #>
function Assert-PushUrl {
    param([Parameter(Mandatory)][string]$Worktree)
    $url = (Invoke-HarnessGit @('remote', 'get-url', '--push', 'origin') -Repo $Worktree).Out.Trim()
    $want = "^https://$([regex]::Escape((Get-HarnessMaintainer)))@github\.com/$([regex]::Escape((Get-HarnessRepo)))(?:\.git)?$"
    if ($url -notmatch $want) { throw "origin's push URL must be https://$(Get-HarnessMaintainer)@github.com/$(Get-HarnessRepo) (.git optional); nothing is pushed" }
}

<# New commits: reachable from the head, not from origin/feature/v1 and not from the remote branch. #>
function Get-NewCommits {
    param([Parameter(Mandatory)][string]$Worktree, [Parameter(Mandatory)][string[]]$RevArgs)
    $format = "--format=$($RecordSep)%H$($FieldSep)%an$($FieldSep)%ae$($FieldSep)%cn$($FieldSep)%ce$($FieldSep)%P$($FieldSep)%B"
    $raw = (Invoke-HarnessGit (@('log', $format) + $RevArgs) -Repo $Worktree).Out
    foreach ($rec in ($raw -split $RecordSep | Where-Object { $_.Trim() })) {
        $f = $rec.TrimStart("`n") -split $FieldSep, 7
        [pscustomobject]@{
            Sha = $f[0]; Author = "$($f[1]) <$($f[2])>"; Committer = "$($f[3]) <$($f[4])>"
            Parents = @($f[5] -split '\s+' | Where-Object { $_ }).Count; Message = $f[6]
        }
    }
}

<# Problems of one commit; empty = fine. Author and committer are checked here; the message rules are those of check-commits.mjs. #>
function Get-CommitProblems {
    param([Parameter(Mandatory)]$Commit)
    $want = "$Maintainer <$MaintainerEmail>"
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($Commit.Author -cne $want) { $problems.Add("author is not $want") }
    if ($Commit.Committer -cne $want) { $problems.Add("committer is not $want") }
    foreach ($e in @(Get-MessageErrors $Commit.Message -Merge:($Commit.Parents -gt 1))) { $problems.Add($e) }
    $problems.ToArray()
}

function Invoke-Push {
    param([Parameter(Mandatory)][string]$Worktree)
    Initialize-HarnessIdentity
    Assert-PushUrl $Worktree
    $branch = (Invoke-HarnessGit @('symbolic-ref', '--quiet', '--short', 'HEAD') -Repo $Worktree -AllowFail).Out.Trim()
    if ($branch -cnotmatch '^feat/[a-z0-9][a-z0-9-]*$') { throw "Only feat/<slug> sub-branches are pushed; the current branch is '$branch'" }
    $dirty = (Invoke-HarnessGit @('status', '--porcelain') -Repo $Worktree).Out.Trim()
    if ($dirty) { throw 'The working tree is not clean: commit or clean up before pushing' }
    $headSha = (Invoke-HarnessGit @('rev-parse', 'HEAD') -Repo $Worktree).Out.Trim()
    Invoke-HarnessGitLocked {
        Invoke-HarnessGit @('fetch', '--no-tags', 'origin', '+refs/heads/feature/v1:refs/remotes/origin/feature/v1') -Repo $Worktree | Out-Null
    } | Out-Null
    $remote = (Invoke-HarnessGit @('ls-remote', '--heads', 'origin', "refs/heads/$branch") -Repo $Worktree).Out.Trim()
    $range = @($headSha, '--not', 'origin/feature/v1')
    if ($remote) {
        $old = ($remote -split '\s+')[0]
        if ((Invoke-HarnessGit @('merge-base', '--is-ancestor', $old, $headSha) -Repo $Worktree -AllowFail).Code -ne 0) {
            throw "Remote $branch is not an ancestor of HEAD: an already pushed branch may only fast-forward, no force-push"
        }
        if ($old -eq $headSha) { return "$branch is up to date ($($headSha.Substring(0, 7))), nothing to push" }
        $range += $old
    }
    $commits = @(Get-NewCommits -Worktree $Worktree -RevArgs $range)
    if (-not $commits.Count) { throw "No new commits relative to origin/feature/v1: nothing to push" }
    $bad = foreach ($c in $commits) {
        $p = @(Get-CommitProblems $c)
        if ($p.Count) { "$($c.Sha.Substring(0, 7)): $($p -join '; ')" }
    }
    if (@($bad).Count) { throw "Commit check failed, nothing is pushed: $(@($bad) -join ' | ')" }
    $priv = Invoke-HarnessNodeScript 'scripts/check-privacy.mjs' (@('--commits') + $range + @(Get-HarnessNeedleArgs)) -AllowFail
    if ($priv.Code -ne 0) {
        $detail = @((($priv.Out + "`n" + $priv.Err) -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 5)
        throw "Privacy check found something in the new commits, nothing is pushed: $($detail -join ' | ')"
    }
    $leaks = Get-HarnessSetting -Env 'HARNESS_GITLEAKS' -GitKey 'harness.gitleaks'
    if (-not $leaks) { throw 'gitleaks is not configured: set HARNESS_GITLEAKS or git config harness.gitleaks' }
    $logOpts = (@($range) + @('--no-ext-diff', '--no-textconv')) -join ' '
    $scan = Invoke-HarnessExternal $leaks @('git', $Worktree, '--no-banner', '--redact', "--log-opts=$logOpts") -AllowFail
    if ($scan.Code -ne 0) { throw "gitleaks reported findings in the new commits, nothing is pushed" }
    Invoke-HarnessGit @('push', 'origin', "HEAD:refs/heads/$branch") -Repo $Worktree | Out-Null
    "Pushed $branch at $($headSha.Substring(0, 7))"
}

function Invoke-SelfTest {
    $cases = New-HarnessCases
    $goodUrl = 'https://DLsnows@github.com/synchain-oss/reaper-harness.git'
    $me = 'DLsnows'
    $mail = 'noreply@synchain.ca'
    $goodMsg = "feat(example): add the example module`n`nBody text.`n`nSigned-off-by: DLsnows <noreply@synchain.ca>"
    $makeCommit = { param($author = "$me|$mail", $committer = "$me|$mail", $parents = 'b' * 40, $message = $goodMsg)
        $a = $author -split '\|'; $c = $committer -split '\|'
        "$RecordSep$('c' * 40)$FieldSep$($a[0])$FieldSep$($a[1])$FieldSep$($c[0])$FieldSep$($c[1])$FieldSep$parents$FieldSep$message" }
    $state = @{ Branch = 'feat/example'; Dirty = ''; Remote = ''; Ancestor = 0; Leaks = 0; Privacy = 0; Token = 0; Login = 'DLsnows'; Url = $goodUrl; Log = (& $makeCommit) }
    $log = [System.Collections.Generic.List[string]]::new()
    $headSha = 'a' * 40
    $routes = [ordered]@{
        '^gh auth token --user DLsnows$' = { @{ Code = $state.Token; Out = $(if ($state.Token) { '' } else { 'tok-selftest' }); Err = '' } }
        '^gh api user --jq \.login$'     = { $state.Login }
        'remote get-url --push origin$'  = { $state.Url }
        'symbolic-ref'                   = { @{ Code = $(if ($state.Branch) { 0 } else { 1 }); Out = $state.Branch; Err = '' } }
        'status --porcelain'             = { $state.Dirty }
        'rev-parse HEAD'                 = { $headSha }
        ' fetch '                        = { '' }
        'ls-remote'                      = { $state.Remote }
        'merge-base'                     = { @{ Code = $state.Ancestor; Out = ''; Err = '' } }
        ' log --format='                 = { $state.Log }
        'check-privacy\.mjs --commits'   = { @{ Code = $state.Privacy; Out = $(if ($state.Privacy) { '[stand-in] finding' } else { '' }); Err = '' } }
        '^gitleaks-fake git'             = { @{ Code = $state.Leaks; Out = ''; Err = '' } }
        ' push origin '                  = { '' }
    }
    $savedLeaks = $env:HARNESS_GITLEAKS
    $savedToken = $env:GH_TOKEN
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "harness-push-selftest-$PID"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $env:HARNESS_GITLEAKS = 'gitleaks-fake'
        # the message rules (check-commits.mjs through lib/maint.mjs) run for real with a needle file of the self-test; only the
        # scan of the history by the privacy tool is faked, as there is no real history behind the fake commits
        New-HarnessSelfTestNeedles -Directory $tmp | Out-Null
        Set-HarnessFake (New-HarnessFake -Routes $routes -Log $log)
        $lockNames = [System.Collections.Generic.List[string]]::new()
        Set-HarnessLockImpl { param($name, $sb) $lockNames.Add($name); & $sb }
        $run = { $log.Clear(); Invoke-Push -Worktree 'wt' }
        $r = & $run
        $push = @($log | Where-Object { $_ -match ' push ' })
        Add-HarnessCase $cases 'new branch: pushes HEAD:refs/heads/feat/<slug> after gitleaks scans only the new commits' $false (-not (
                $r -match '^Pushed' -and $push.Count -eq 1 -and $push[0] -match 'push origin HEAD:refs/heads/feat/example$' -and
                @($log | Where-Object { $_ -match "gitleaks-fake git wt .*--log-opts=$headSha --not origin/feature/v1 --no-ext-diff" }).Count -eq 1))
        $first = { param($pattern) for ($k = 0; $k -lt $log.Count; $k++) { if ($log[$k] -match $pattern) { return $k } }; -1 }
        Add-HarnessCase $cases 'identity, push URL, commit check, privacy and gitleaks all come before the push' $false (-not (
                $env:GH_TOKEN -eq 'tok-selftest' -and (& $first '^gh api user') -ge 0 -and (& $first 'remote get-url --push') -gt (& $first '^gh api user') -and
                (& $first ' log --format=') -gt (& $first 'remote get-url --push') -and (& $first 'check-privacy') -gt (& $first ' log --format=') -and
                (& $first '^gitleaks-fake') -gt (& $first 'check-privacy') -and (& $first ' push origin ') -gt (& $first '^gitleaks-fake')))
        Add-HarnessCase $cases 'origin/feature/v1 is fetched, under the git lock, before the new-commit range is taken' $false (-not (
                (& $first 'fetch --no-tags origin \+refs/heads/feature/v1:refs/remotes/origin/feature/v1$') -ge 0 -and
                (& $first 'fetch --no-tags') -lt (& $first ' log --format=') -and $lockNames -contains 'git'))
        Add-HarnessCase $cases 'the new-commit range excludes origin/feature/v1' $false (@($log | Where-Object { $_ -match "check-privacy\.mjs --commits $headSha --not origin/feature/v1 --needles" }).Count -ne 1)

        foreach ($id in @(
                @{ Label = 'gh credential resolves to another account'; Key = 'Login'; Value = 'someone-else' },
                @{ Label = 'no gh credential for the maintainer on this machine'; Key = 'Token'; Value = 1 },
                @{ Label = 'push URL without the maintainer user name'; Key = 'Url'; Value = 'https://github.com/synchain-oss/reaper-harness.git' },
                @{ Label = 'push URL with another account'; Key = 'Url'; Value = 'https://someone@github.com/synchain-oss/reaper-harness.git' },
                @{ Label = 'push URL pointing at another repository'; Key = 'Url'; Value = 'https://DLsnows@github.com/someone/reaper-harness.git' })) {
            $saved = $state[$id.Key]; $state[$id.Key] = $id.Value; $log.Clear()
            Add-HarnessCase $cases "wrong identity, no push: $($id.Label)" $true ((Test-Throws { Invoke-Push -Worktree 'wt' }) -and -not @($log | Where-Object { $_ -match ' push |gitleaks|check-privacy' }).Count)
            $state[$id.Key] = $saved
        }
        & $run | Out-Null
        Add-HarnessCase $cases 'push command has no force and no --no-verify' $false (@($log | Where-Object { $_ -match ' push .*(--force|-f\b|--no-verify|\+HEAD|--mirror)' }).Count -gt 0)

        $state.Remote = "$('b' * 40)`trefs/heads/feat/example"
        & $run | Out-Null
        Add-HarnessCase $cases 'already pushed: only the increment is checked and scanned' $false (@($log | Where-Object { $_ -match "gitleaks-fake git wt .*--log-opts=$headSha --not origin/feature/v1 $('b' * 40) " }).Count -ne 1)
        $state.Ancestor = 1
        Add-HarnessCase $cases 'remote is not an ancestor (would need force)' $true (Test-Throws { Invoke-Push -Worktree 'wt' })
        $state.Ancestor = 0
        $state.Remote = "$headSha`trefs/heads/feat/example"
        $log.Clear(); $msg = Invoke-Push -Worktree 'wt'
        Add-HarnessCase $cases 'remote already at HEAD: nothing to push, no push command' $false (-not ($msg -match 'up to date' -and -not @($log | Where-Object { $_ -match ' push ' }).Count))
        $state.Remote = ''

        $state.Leaks = 1; $log.Clear()
        Add-HarnessCase $cases 'gitleaks finding: no push' $true ((Test-Throws { Invoke-Push -Worktree 'wt' }) -and -not @($log | Where-Object { $_ -match ' push ' }).Count)
        $state.Leaks = 0
        $env:HARNESS_GITLEAKS = $null
        $withoutLeaks = [ordered]@{ ' config --get harness\.gitleaks' = { @{ Code = 1; Out = ''; Err = '' } } }
        foreach ($k in $routes.Keys) { $withoutLeaks[$k] = $routes[$k] }
        Set-HarnessFake (New-HarnessFake -Routes $withoutLeaks -Log $log)
        $log.Clear()
        $unconfigured = Get-ThrownMessage { Invoke-Push -Worktree 'wt' }
        Add-HarnessCase $cases 'gitleaks not configured: no push, and the reason is the missing setting' $true ([bool]$unconfigured -and $unconfigured -match 'gitleaks is not configured' -and -not @($log | Where-Object { $_ -match ' push ' }).Count)
        Set-HarnessFake (New-HarnessFake -Routes $routes -Log $log)
        $env:HARNESS_GITLEAKS = 'gitleaks-fake'
        $state.Privacy = 1; $log.Clear()
        Add-HarnessCase $cases 'privacy finding in the new commits: no push' $true ((Test-Throws { Invoke-Push -Worktree 'wt' }) -and -not @($log | Where-Object { $_ -match ' push |gitleaks' }).Count)
        $state.Privacy = 0

        $commitCase = {
            param($label, $record, $expectBad)
            $state.Log = $record; $log.Clear()
            $thrown = Test-Throws { Invoke-Push -Worktree 'wt' }
            Add-HarnessCase $cases "commit check: $label" $expectBad ($(if ($expectBad) { $thrown -and -not @($log | Where-Object { $_ -match ' push ' }).Count } else { $thrown }))
        }
        & $commitCase 'a clean commit passes' (& $makeCommit) $false
        & $commitCase 'author is someone else' (& $makeCommit -author 'Someone|someone@example.com') $true
        & $commitCase 'author has the right name but another email' (& $makeCommit -author "$me|other@example.com") $true
        & $commitCase 'committer is someone else' (& $makeCommit -committer 'Someone|someone@example.com') $true
        & $commitCase 'no Signed-off-by' (& $makeCommit -message "feat(example): add it`n`nBody.") $true
        & $commitCase 'Signed-off-by of someone else' (& $makeCommit -message "feat(example): add it`n`nSigned-off-by: Someone <someone@example.com>") $true
        & $commitCase 'AI attribution trailer' (& $makeCommit -message "$goodMsg`nCo-Authored-By: A Name <a@example.com>") $true
        & $commitCase 'a trailer other than Signed-off-by' (& $makeCommit -message "feat(example): add it`n`nReviewed-by: Someone`nSigned-off-by: DLsnows <noreply@synchain.ca>") $true
        & $commitCase 'subject without type(scope)' (& $makeCommit -message "add the example module`n`nSigned-off-by: DLsnows <noreply@synchain.ca>") $true
        & $commitCase 'merge commit needs no subject or sign-off' (& $makeCommit -parents "$('b' * 40) $('d' * 40)" -message "Merge branch 'feature/v1' into feat/example") $false
        & $commitCase 'merge commit by someone else' (& $makeCommit -parents "$('b' * 40) $('d' * 40)" -author 'Someone|someone@example.com' -message "Merge branch 'feature/v1' into feat/example") $true
        & $commitCase 'one bad commit among good ones' ((& $makeCommit) + (& $makeCommit -author 'Someone|someone@example.com')) $true
        $state.Log = ''
        Add-HarnessCase $cases 'no new commits relative to origin/feature/v1: nothing to push' $true (Test-Throws { Invoke-Push -Worktree 'wt' })
        $state.Log = (& $makeCommit)

        foreach ($b in 'feature/v1', 'dev', 'prod', 'main', 'fix/example', 'feat/Bad_Name', 'feat/Example') {
            $state.Branch = $b
            Add-HarnessCase $cases "branch $b is refused" $true (Test-Throws { Invoke-Push -Worktree 'wt' })
        }
        $state.Branch = ''
        Add-HarnessCase $cases 'detached HEAD' $true (Test-Throws { Invoke-Push -Worktree 'wt' })
        $state.Branch = 'feat/example'; $state.Dirty = ' M x.txt'
        Add-HarnessCase $cases 'working tree is not clean' $true (Test-Throws { Invoke-Push -Worktree 'wt' })
        $state.Dirty = ''
        $selfText = Get-Content -Raw -LiteralPath $PSCommandPath
        Add-HarnessCase $cases 'source hygiene: push.ps1' $false (@(Get-HarnessSourceProblems -Text $selfText -Name 'push.ps1').Count -gt 0)
    } finally {
        Set-HarnessFake $null
        Set-HarnessLockImpl $null
        Set-HarnessNeedles
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        $env:HARNESS_GITLEAKS = $savedLeaks
        $env:GH_TOKEN = $savedToken
    }
    Complete-HarnessSelfTest $cases 'push'
}

if ($SelfTest) { exit (Invoke-SelfTest) }
$target = if ($Repo) { $Repo } else { (Get-Location).Path }
Write-Output (Invoke-Push -Worktree $target)

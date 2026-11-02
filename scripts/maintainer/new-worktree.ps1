#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
#
# Create the working tree for one unit of work: under the git lock fetch origin/feature/v1, then
#   git worktree add --no-track -b feat/<slug> <root>/wt/<card> origin/feature/v1
# and set the repository-local commit identity (maintainer name and no-reply email). The card name only appears in the local
# path; the branch name carries none (it goes through the public-text check). A worktree that already sits on that branch is
# reported, not rebuilt. <root> is the workspace root: HARNESS_ROOT or git config harness.root; no path is written in this file.
#   pwsh scripts/maintainer/new-worktree.ps1 -Card <name> -Slug <slug>
#   pwsh scripts/maintainer/new-worktree.ps1 -SelfTest

[CmdletBinding()]
param([switch]$SelfTest, [string]$Card, [string]$Slug)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/HarnessGh.psm1') -Force

$MaintainerEmail = 'noreply@synchain.ca'

<# The repository-local identity every commit of the worktrees is made with (shared by all worktrees of the clone); verified after it is set. #>
function Set-RepoIdentity {
    param([Parameter(Mandatory)][string]$Worktree)
    $want = [ordered]@{ 'user.name' = (Get-HarnessMaintainer); 'user.email' = $MaintainerEmail }
    foreach ($key in $want.Keys) {
        $now = (Invoke-HarnessGit @('config', '--get', $key) -Repo $Worktree -AllowFail).Out.Trim()
        if ($now -cne $want[$key]) { Invoke-HarnessGit @('config', '--local', $key, $want[$key]) -Repo $Worktree | Out-Null }
        $after = (Invoke-HarnessGit @('config', '--get', $key) -Repo $Worktree).Out.Trim()
        if ($after -cne $want[$key]) { throw "Could not set $key to $($want[$key]) (it reads back as '$after'); check for a more specific config that overrides it" }
    }
}

function New-WorkWorktree {
    param([Parameter(Mandatory)][string]$Card, [Parameter(Mandatory)][string]$Slug)
    # the card name becomes one path component under <root>/wt: it starts with a letter or digit (so never . or ..) and holds no separator
    if ($Card -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$') { throw "Not a usable card name (letters, digits, . _ - only, at most 32): $Card" }
    if ($Slug -cnotmatch '^[a-z0-9][a-z0-9-]*$') { throw "The slug may only hold lowercase letters, digits and hyphens: $Slug" }
    $branch = "feat/$Slug"
    $scan = Test-PublicText $branch
    if (-not $scan.Ok) { throw "The branch name failed the public-text check: $($scan.Findings -join '; ')" }
    $wt = Join-Path (Join-Path (Get-HarnessRoot) 'wt') $Card
    if (Test-Path -LiteralPath $wt) {
        $current = (Invoke-HarnessGit @('symbolic-ref', '--quiet', '--short', 'HEAD') -Repo $wt -AllowFail).Out.Trim()
        if (-not (Test-HarnessSameText $current $branch)) { throw "$wt already exists, but on branch '$current', not on $branch" }
        Set-RepoIdentity $wt
        return "Worktree already exists: $wt ($branch)"
    }
    Invoke-HarnessGitLocked {
        Invoke-HarnessGit @('fetch', '--no-tags', 'origin', '+refs/heads/feature/v1:refs/remotes/origin/feature/v1') | Out-Null
        if ((Invoke-HarnessGit @('rev-parse', '--verify', '--quiet', "refs/heads/$branch") -AllowFail).Code -eq 0) {
            throw "Local branch $branch exists already (choose another slug, or clean up the old branch)"
        }
        Invoke-HarnessGit @('worktree', 'add', '--no-track', '-b', $branch, $wt, 'origin/feature/v1') | Out-Null
    } | Out-Null
    Set-RepoIdentity $wt
    "Created worktree: $wt ($branch, based on origin/feature/v1)"
}

<# The command line: the arguments first, then the identity, and only then anything that changes the repository. #>
function Invoke-Entry {
    [CmdletBinding()]
    param([string]$Card, [string]$Slug)
    if (-not $Card -or -not $Slug) { throw 'Both -Card <name> and -Slug <slug> are required' }
    Initialize-HarnessIdentity
    Write-Output (New-WorkWorktree -Card $Card -Slug $Slug)
}

function Invoke-SelfTest {
    $cases = New-HarnessCases
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "harness-wt-selftest-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $oldRoot = $env:HARNESS_ROOT
    $savedToken = $env:GH_TOKEN
    $unit = 'unit-a'
    $log = [System.Collections.Generic.List[string]]::new()
    $locked = [System.Collections.Generic.List[string]]::new()
    $state = @{ LocalBranch = 1; Current = 'feat/example-unit'; Name = 'DLsnows'; Email = 'noreply@synchain.ca'; Sticky = $false; Login = 'DLsnows' }
    $routes = [ordered]@{
        '^gh auth token --user DLsnows$' = { 'tok-selftest' }
        '^gh api user --jq \.login$' = { $state.Login }
        ' fetch '                   = { '' }
        'rev-parse --verify'        = { @{ Code = $state.LocalBranch; Out = ''; Err = '' } }
        'worktree add'              = { param($argv) New-Item -ItemType Directory -Force -Path $argv[-2] | Out-Null; '' }
        'symbolic-ref'              = { $state.Current }
        ' config --get user\.name$'  = { $state.Name }
        ' config --get user\.email$' = { $state.Email }
        ' config --local user\.name ' = { param($argv) if (-not $state.Sticky) { $state.Name = $argv[-1] }; '' }
        ' config --local user\.email ' = { param($argv) if (-not $state.Sticky) { $state.Email = $argv[-1] }; '' }
    }
    try {
        $env:HARNESS_ROOT = $tmp
        # the repository's own privacy tool runs for real, with a needle file of the self-test
        New-HarnessSelfTestNeedles -Directory $tmp | Out-Null
        Set-HarnessFake (New-HarnessFake -Routes $routes -Log $log)
        Set-HarnessLockImpl { param($name, $block) $locked.Add('lock'); & $block }
        $state.Name = ''; $state.Email = ''
        # a refusal comes back as text: a run that was meant to pass then turns its own case red, by name
        $make = { try { New-WorkWorktree -Card $unit -Slug 'example-unit' } catch { "threw: $($_.Exception.Message)" } }
        $made = & $make
        $add = @($log | Where-Object { $_ -match 'worktree add' })
        $wt = Join-Path (Join-Path $tmp 'wt') $unit
        Add-HarnessCase $cases 'worktree add --no-track -b feat/<slug> <root>/wt/<card> origin/feature/v1 after a fetch under the git lock' $false (-not (
                $locked.Count -eq 1 -and $add.Count -eq 1 -and $add[0].EndsWith("worktree add --no-track -b feat/example-unit $wt origin/feature/v1") -and
                @($log | Where-Object { $_ -match ' fetch ' }).Count -eq 1))
        Add-HarnessCase $cases 'the repository-local identity is set and read back' $false (-not ($state.Name -ceq 'DLsnows' -and $state.Email -ceq 'noreply@synchain.ca' -and $made -match 'Created worktree'))
        Add-HarnessCase $cases 'the identity is never set globally' $false (@($log | Where-Object { $_ -match 'config --global' }).Count -gt 0)
        $n = $log.Count
        $again = & $make
        Add-HarnessCase $cases 'a worktree that already sits on the branch is not rebuilt' $false (-not ($again -match 'already exists' -and -not @($log | Select-Object -Skip $n | Where-Object { $_ -match 'worktree add' }).Count))
        Add-HarnessCase $cases 'the identity already correct is not rewritten' $false (@($log | Select-Object -Skip $n | Where-Object { $_ -match 'config --local' }).Count -gt 0)
        $state.Name = 'someone'
        $n = $log.Count
        & $make | Out-Null
        Add-HarnessCase $cases 'a wrong identity is corrected' $false (-not ($state.Name -ceq 'DLsnows' -and @($log | Select-Object -Skip $n | Where-Object { $_ -match 'config --local user\.name' }).Count -eq 1))
        $state.Name = 'someone'; $state.Sticky = $true
        Add-HarnessCase $cases 'an identity that does not stick (overridden elsewhere) is an error' $true (Test-Throws { New-WorkWorktree -Card $unit -Slug 'example-unit' })
        $state.Sticky = $false; $state.Name = 'DLsnows'
        $state.Current = 'feat/other'
        Add-HarnessCase $cases 'the worktree exists but on another branch' $true (Test-Throws { New-WorkWorktree -Card $unit -Slug 'example-unit' })
        $state.Current = 'feat/Example-Unit'
        Add-HarnessCase $cases 'the worktree exists on a branch that differs only by letter case' $true (Test-Throws { New-WorkWorktree -Card $unit -Slug 'example-unit' })
        $state.Current = 'feat/other'
        $state.LocalBranch = 0
        Add-HarnessCase $cases 'the local branch exists already' $true ((Get-ThrownMessage { New-WorkWorktree -Card 'unit-b' -Slug 'example-unit' }) -match 'Local branch feat/example-unit exists already')
        # each refusal is checked by its own reason: with a second reason behind it a missing check would go unnoticed (the local branch is still reported as existing here)
        Add-HarnessCase $cases 'a slug that carries a task-card number is stopped by the public-text check' $true ((Get-ThrownMessage { New-WorkWorktree -Card 'unit-c' -Slug ('rh' + '-02-x') }) -match 'branch name failed the public-text check')
        Add-HarnessCase $cases 'a slug with uppercase' $true ((Get-ThrownMessage { New-WorkWorktree -Card 'unit-c' -Slug 'Bad' }) -match 'slug may only hold')
        Add-HarnessCase $cases 'a slug with a slash' $true ((Get-ThrownMessage { New-WorkWorktree -Card 'unit-c' -Slug 'a/b' }) -match 'slug may only hold')
        Add-HarnessCase $cases 'a slug that starts with a hyphen' $true ((Get-ThrownMessage { New-WorkWorktree -Card 'unit-c' -Slug '-x' }) -match 'slug may only hold')
        foreach ($escape in @('../x', '..', 'a\b', '.hidden', 'a/b', ('x' * 33))) {
            Add-HarnessCase $cases "a card name that is not one path component: '$escape'" $true ((Get-ThrownMessage { New-WorkWorktree -Card $escape -Slug 'example' }) -match 'Not a usable card name')
        }
        Add-HarnessCase $cases 'a card name of 32 characters is accepted' $false ((Get-ThrownMessage { New-WorkWorktree -Card ('x' * 32) -Slug 'example' }) -match 'Not a usable card name')
        # the command line: arguments first, then the identity, then the repository
        $state.LocalBranch = 1; $state.Current = 'feat/entry-unit'; $log.Clear()
        $entered = @(Invoke-Entry -Card 'unit-e' -Slug 'entry-unit')
        $ghCalls = @($log | Where-Object { $_ -match '^gh ' })
        Add-HarnessCase $cases 'entry: the first gh calls are the identity check, before the worktree is added' $false (-not (
                $ghCalls.Count -ge 2 -and $ghCalls[0] -ceq 'gh auth token --user DLsnows' -and $ghCalls[1] -ceq 'gh api user --jq .login' -and $log.IndexOf($ghCalls[1]) -lt (@(0..($log.Count - 1) | Where-Object { $log[$_] -match 'worktree add' }) + @(-1))[0] -and $entered[0] -match 'Created worktree'))
        $state.Login = 'someone-else'; $log.Clear()
        Add-HarnessCase $cases 'entry: another account: refused, no fetch and no worktree' $true ((Get-ThrownMessage { Invoke-Entry -Card 'unit-f' -Slug 'entry-other' }) -match 'resolves to someone-else' -and @($log | Where-Object { $_ -match ' fetch |worktree add' }).Count -eq 0)
        $state.Login = 'DLsnows'; $log.Clear()
        Add-HarnessCase $cases 'entry: no -Card: refused before anything is asked' $true ((Get-ThrownMessage { Invoke-Entry -Slug 'example' }) -match 'Both -Card' -and $log.Count -eq 0)
        Add-HarnessCase $cases 'entry: no -Slug: refused before anything is asked' $true ((Get-ThrownMessage { Invoke-Entry -Card 'unit-g' }) -match 'Both -Card' -and $log.Count -eq 0)
        $env:HARNESS_ROOT = ''
        Set-HarnessFake (New-HarnessFake -Routes ([ordered]@{ ' config --get harness\.root$' ={ @{ Code = 1; Out = ''; Err = '' } } }) -Log $log)
        Add-HarnessCase $cases 'no workspace root configured' $true (Test-Throws { New-WorkWorktree -Card 'unit-d' -Slug 'example' })
        $selfText = Get-Content -Raw -LiteralPath $PSCommandPath
        Add-HarnessCase $cases 'source hygiene: new-worktree.ps1' $false (@(Get-HarnessSourceProblems -Text $selfText -Name 'new-worktree.ps1').Count -gt 0)
    } catch {
        # a crash does not hide what already turned red by name
        Write-HarnessFailedCases $cases
        throw
    } finally {
        Set-HarnessFake $null
        Set-HarnessLockImpl $null
        Set-HarnessNeedles
        $env:HARNESS_ROOT = $oldRoot
        $env:GH_TOKEN = $savedToken
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        $full = [IO.Path]::GetFullPath($tmp).TrimEnd('\', '/')
        if ((Split-Path -Parent $full) -ieq $tempRoot -and (Split-Path -Leaf $full) -like 'harness-wt-selftest-*') { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
        Add-HarnessCase $cases 'the self-test temp directory was removed' $false (Test-Path -LiteralPath $tmp)
    }
    Complete-HarnessSelfTest $cases 'new-worktree'
}

if ($SelfTest) { exit [int]@(Invoke-SelfTest)[-1] }
Invoke-Entry @PSBoundParameters

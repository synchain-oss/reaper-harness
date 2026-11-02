#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
#
# Open a PR (into feature/v1 only). Refused: a base other than feature/v1 (dev and prod always), a head that is not
# feat/<slug>, a draft (a draft does not trigger the review bot). The title must be type(scope): description; the body
# must carry every section of the PR template (a checkout without the template is an error) and end with the maintainer's
# sign-off line. Title and body pass the PR-text rules of scripts/check-commits.mjs (format, sign-off, privacy); the body and
# the branch name also pass the public-text gate (scripts/check-privacy.mjs plus AI attribution trailers). The first line of
# the body is the hidden agent marker. If the same head already has an open PR only its number is reported.
#   pwsh scripts/maintainer/pr-open.ps1 -Head feat/<slug> -Title "<type(scope): description>" -BodyFile <f> [-Role impl] [-Round 0]
#   pwsh scripts/maintainer/pr-open.ps1 -Update -Pr <n> -BodyFile <f> [-Title "<new title>"] [-Role impl] [-Round <r>]
#   pwsh scripts/maintainer/pr-open.ps1 -SelfTest
# -Update replaces the body (and the title when -Title is given) of an open PR: head must be a feat/ branch of this repo and
# base feature/v1; body and title pass the same checks and the marker's head is the PR's current head. Use it when the body
# went stale instead of correcting it in a comment.

[CmdletBinding()]
param(
    [switch]$SelfTest, [string]$Head, [string]$Title, [string]$BodyFile,
    [switch]$Draft, [string]$Role = 'impl', [int]$Round = 0, [switch]$Update, [int]$Pr
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/HarnessGh.psm1') -Force

$BaseBranch = 'feature/v1'

# the PR template of this checkout; only the self-test names another file
$TemplateOverride = $null

<# Level-2 headings of the PR template: the body must have each of them. A checkout without the template is an error. #>
function Get-TemplateHeadings {
    $file = if ($TemplateOverride) { $TemplateOverride } else { Join-Path (Get-HarnessRepoRoot) '.github/pull_request_template.md' }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw '.github/pull_request_template.md is missing in this checkout: the required sections are unknown, nothing is sent' }
    $headings = @([regex]::Matches((Get-Content -Raw -LiteralPath $file), '(?m)^## .+$') | ForEach-Object { $_.Value.TrimEnd() })
    if (-not $headings.Count) { throw 'The PR template has no level-2 headings: the required sections are unknown, nothing is sent' }
    $headings
}

<# Every check before a PR is opened or edited; returns the body to send (marker added) or throws. #>
function Test-OpenRequest {
    param([string]$Branch, [string]$Base, [string]$PrTitle, [string]$Body, [bool]$IsDraft, [string]$AgentRole, [int]$AgentRound, [string]$HeadSha)
    if ($Base -cne $BaseBranch) { throw "base must be $BaseBranch, got '$Base' (no PR into dev or prod from here)" }
    if ($Branch -cnotmatch '^feat/[a-z0-9][a-z0-9-]*$') { throw "head must be feat/<slug>, got '$Branch'" }
    if ($IsDraft) { throw 'No draft PRs: a draft does not trigger the review bot' }
    Assert-PublicText $Branch 'branch name'
    $lines = @($Body -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
    $missing = @(Get-TemplateHeadings | Where-Object { $lines -notcontains $_ })
    if ($missing.Count) { throw "The body lacks sections of the PR template: $($missing -join ', ')" }
    $problems = @(Get-PrTextErrors -Title $PrTitle -Body $Body)
    if ($problems.Count) { throw "PR title or body failed the format check: $($problems -join '; ')" }
    $full = Format-AgentText -Text $Body -Role $AgentRole -Kind 'pr-body' -Round $AgentRound -Head $HeadSha -Label 'PR body'
    $full
}

function Invoke-Open {
    param([string]$Branch, [string]$Base, [string]$PrTitle, [string]$Body, [bool]$IsDraft, [string]$AgentRole, [int]$AgentRound)
    $slug = Get-HarnessRepo
    $owner = $slug.Split('/')[0]
    $remote = Get-HarnessApi "repos/$slug/branches/$([uri]::EscapeDataString($Branch))" -AllowFail
    if (-not $remote) { throw "The remote has no branch $Branch (push it with push.ps1 first)" }
    $sha = [string]$remote.commit.sha
    $existing = @(Get-HarnessApi "repos/$slug/pulls?state=open&head=$($owner):$([uri]::EscapeDataString($Branch))&per_page=10" -Paginate)
    if ($existing.Count) { return "An open PR already exists: #$($existing[0].number) $($existing[0].html_url)" }
    $full = Test-OpenRequest -Branch $Branch -Base $Base -PrTitle $PrTitle -Body $Body -IsDraft $IsDraft -AgentRole $AgentRole -AgentRound $AgentRound -HeadSha $sha
    $r = Invoke-HarnessApiWrite -Method POST -Path "repos/$slug/pulls" -Body @{
        title = $PrTitle; head = $Branch; base = $Base; body = $full; draft = $false; maintainer_can_modify = $false
    }
    "Opened PR #$($r.number): $($r.html_url) (head $($sha.Substring(0, 7)))"
}

<# Replace the body (and title) of an open PR: same checks as opening; the marker's head is the PR's head right now. #>
function Invoke-Update {
    param([int]$Number, [string]$NewTitle, [string]$Body, [string]$AgentRole, [int]$AgentRound)
    $slug = Get-HarnessRepo
    $pull = Get-HarnessApi "repos/$slug/pulls/$Number"
    if ($pull.state -ne 'open') { throw "#$Number is not open, its body is not edited" }
    # a deleted fork makes head.repo null, which is not the same as "not a branch of this repo"
    if ($null -eq (Get-HarnessProp $pull.head 'repo')) { throw "The source repository of #$Number was deleted, it cannot be updated; handle the PR directly" }
    if ($pull.head.repo.full_name -ne $slug) { throw "The head of #$Number is not a branch of this repository" }
    $sha = [string]$pull.head.sha
    $effective = if ($NewTitle) { $NewTitle } else { [string]$pull.title }
    $full = Test-OpenRequest -Branch $pull.head.ref -Base $pull.base.ref -PrTitle $effective -Body $Body -IsDraft ([bool]$pull.draft) -AgentRole $AgentRole -AgentRound $AgentRound -HeadSha $sha
    $payload = @{ body = $full }
    if ($NewTitle) { $payload.title = $NewTitle }
    Invoke-HarnessApiWrite -Method PATCH -Path "repos/$slug/pulls/$Number" -Body $payload | Out-Null
    "Updated #$Number $(if ($NewTitle) { 'title and ' })body (head $($sha.Substring(0, 7)))"
}

function Invoke-SelfTest {
    $cases = New-HarnessCases
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "harness-pr-open-selftest-$PID"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        # the repository's own privacy tool and message rules run for real, with a needle file of the self-test
        New-HarnessSelfTestNeedles -Directory $tmp | Out-Null
        $template = "<!-- template -->`n## 做了什么`n`n## 为什么`n`n## 怎么测的`n`n## 安全自查`n`n## DCO`n`nSigned-off-by:`n"
        $templateFile = Join-Path $tmp 'pull_request_template.md'
        [IO.File]::WriteAllText($templateFile, $template, [Text.UTF8Encoding]::new($false))
        $script:TemplateOverride = $templateFile
        $sign = Get-HarnessSignoff
        $good = "## 做了什么`n加入示例。`n`n## 为什么`n演示。`n`n## 怎么测的`n自测。`n`n## 安全自查`n不涉及。`n`n## DCO`n- [x] 已签名`n`n$sign"
        $sha = 'a' * 40
        $posted = [System.Collections.Generic.List[object]]::new()
        $patched = [System.Collections.Generic.List[object]]::new()
        $open = @()
        $existing = [pscustomobject]@{ number = 12; state = 'open'; draft = $false; title = 'ci(example): add the example'
            head = [pscustomobject]@{ ref = 'feat/example'; sha = 'b' * 40; repo = [pscustomobject]@{ full_name = (Get-HarnessRepo) } }
            base = [pscustomobject]@{ ref = 'feature/v1' }
        }
        $routes = [ordered]@{
            'branches/feat%2Fexample'       ={ @{ commit = @{ sha = $sha } } }
            'branches/'                     = { @{ Code = 1; Out = ''; Err = 'Branch not found' } }
            'pulls\?state=open'             = { , $open }
            'api -X POST \S+/pulls --input' = { param($argv) $posted.Add((Get-Content -Raw ($argv[-1]) | ConvertFrom-Json)); @{ number = 9; html_url = 'https://github.com/x/y/pull/9' } }
            'api -X PATCH \S+/pulls/12 --input' = { param($argv) $patched.Add((Get-Content -Raw ($argv[-1]) | ConvertFrom-Json)); @{ number = 12 } }
            'pulls/12$'                     = { $existing }
        }
        Set-HarnessFake (New-HarnessFake -Routes $routes)
        $goodTitle = 'ci(example): add the example'
        $accepted = { param($h, $b, $t, $bodyIn, $d) -not (Test-Throws { Test-OpenRequest -Branch $h -Base $b -PrTitle $t -Body $bodyIn -IsDraft $d -AgentRole impl -AgentRound 0 -HeadSha $sha }) }
        Add-HarnessCase $cases 'a valid request is accepted' $false (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle $good $false))
        Add-HarnessCase $cases 'base=dev' $true (-not (& $accepted 'feat/example' 'dev' $goodTitle $good $false))
        Add-HarnessCase $cases 'base=prod' $true (-not (& $accepted 'feat/example' 'prod' $goodTitle $good $false))
        Add-HarnessCase $cases 'base is another feature line' $true (-not (& $accepted 'feat/example' 'feature/v2' $goodTitle $good $false))
        Add-HarnessCase $cases 'base differs from feature/v1 only by case' $true (-not (& $accepted 'feat/example' 'Feature/V1' $goodTitle $good $false))
        Add-HarnessCase $cases 'head is not feat/' $true (-not (& $accepted 'fix/example' 'feature/v1' $goodTitle $good $false))
        Add-HarnessCase $cases 'head with uppercase letters' $true (-not (& $accepted 'feat/Example' 'feature/v1' $goodTitle $good $false))
        Add-HarnessCase $cases 'head contains a card number' $true (-not (& $accepted ('feat/r' + 'h-03-x') 'feature/v1' $goodTitle $good $false))
        Add-HarnessCase $cases 'draft' $true (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle $good $true))
        Add-HarnessCase $cases 'body lacks a template section' $true (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle ($good -replace '(?m)^## DCO\s*$', '') $false))
        Add-HarnessCase $cases 'last body line is not the sign-off' $true (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle "$good`nmore" $false))
        Add-HarnessCase $cases 'sign-off of somebody else' $true (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle ($good -replace 'DLsnows <noreply@synchain.ca>', 'Someone <s@example.com>') $false))
        Add-HarnessCase $cases 'body has an AI attribution trailer' $true (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle ($good -replace '(?m)^## DCO', "## DCO`nCo-Authored-By: a <a@b.c>") $false))
        Add-HarnessCase $cases 'body has a generated-with line' $true (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle ($good -replace '(?m)^## DCO', ("## DCO`nGenerated with [Cla" + 'ude Code](x)')) $false))
        Add-HarnessCase $cases 'body has a local path' $true (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle ($good -replace '(?m)^## DCO', ('## DCO' + "`n" + 'C:' + '\Users\someone')) $false))
        Add-HarnessCase $cases 'body has a personal needle' $true (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle ($good -replace '(?m)^## DCO', "## DCO`n$(Get-HarnessFakeNeedle)") $false))
        Add-HarnessCase $cases 'body has a card number' $true (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle ($good -replace '(?m)^## DCO', ('## DCO' + "`nsee R" + 'H-04')) $false))
        Add-HarnessCase $cases 'title format' $true (-not (& $accepted 'feat/example' 'feature/v1' 'add the example' $good $false))
        Add-HarnessCase $cases 'title unknown type' $true (-not (& $accepted 'feat/example' 'feature/v1' 'wip(example): add it' $good $false))
        Add-HarnessCase $cases 'title contains a card number' $true (-not (& $accepted 'feat/example' 'feature/v1' ('ci(example): finish R' + 'H-03') $good $false))
        Add-HarnessCase $cases 'body written with its own marker' $true (-not (& $accepted 'feat/example' 'feature/v1' $goodTitle ("<!-- harness-agent v1 role=impl kind=note round=0 head=aaaaaaa -->`n" + $good) $false))
        Add-HarnessCase $cases 'privacy tool missing is an error, not a pass' $true (Test-Throws {
                Set-HarnessFake (New-HarnessFake -Routes ([ordered]@{ 'check-privacy\.mjs --text' = { @{ Code = 1; Out = ''; Err = 'Cannot find module' } } }))
                try { Test-OpenRequest -Branch 'feat/example' -Base 'feature/v1' -PrTitle $goodTitle -Body $good -IsDraft $false -AgentRole impl -AgentRound 0 -HeadSha $sha } finally { Set-HarnessFake (New-HarnessFake -Routes $routes) }
            })

        $msg = Invoke-Open -Branch 'feat/example' -Base 'feature/v1' -PrTitle $goodTitle -Body $good -IsDraft $false -AgentRole impl -AgentRound 0
        $p = $posted[-1]
        Add-HarnessCase $cases 'the PR sent: base, head, not draft, marker on the first line, sign-off on the last' $false (-not (
                $msg -match '#9' -and $p.base -eq 'feature/v1' -and $p.head -eq 'feat/example' -and $p.draft -eq $false -and $p.maintainer_can_modify -eq $false -and
                $p.body -match '^<!-- harness-agent v1 role=impl kind=pr-body round=0 head=aaaaaaa -->' -and $p.body.TrimEnd().EndsWith($sign)))
        $open = @([pscustomobject]@{ number = 7; html_url = 'u' })
        $n = $posted.Count
        $again = Invoke-Open -Branch 'feat/example' -Base 'feature/v1' -PrTitle $goodTitle -Body $good -IsDraft $false -AgentRole impl -AgentRound 0
        Add-HarnessCase $cases 'an open PR for the same head is not opened again' $false (-not ($again -match '#7' -and $posted.Count -eq $n))
        $noBranch = Get-ThrownMessage { Invoke-Open -Branch 'feat/missing' -Base 'feature/v1' -PrTitle $goodTitle -Body $good -IsDraft $false -AgentRole impl -AgentRound 0 }
        Add-HarnessCase $cases 'the remote has no such branch: refused for that reason, nothing sent' $true ([bool]$noBranch -and $noBranch -match 'has no branch feat/missing' -and $posted.Count -eq $n)
        $open = @()
        Add-HarnessCase $cases 'a rejected request sends nothing' $true ((Test-Throws { Invoke-Open -Branch 'feat/example' -Base 'dev' -PrTitle $goodTitle -Body $good -IsDraft $false -AgentRole impl -AgentRound 0 }) -and $posted.Count -eq $n)

        # -Update: same checks; the marker's head is the PR's head right now; the title stays when none is given
        $up = Invoke-Update -Number 12 -NewTitle '' -Body $good -AgentRole impl -AgentRound 2
        $q = $patched[-1]
        Add-HarnessCase $cases '-Update: body sent with round and the PR head in the marker, title untouched' $false (-not (
                $up -match '#12' -and $q.body -match '^<!-- harness-agent v1 role=impl kind=pr-body round=2 head=bbbbbbb -->' -and
                $q.body.TrimEnd().EndsWith($sign) -and @($q.PSObject.Properties.Name) -notcontains 'title'))
        $n = $patched.Count
        $upd = { param($bodyIn, $t = '') -not (Test-Throws { Invoke-Update -Number 12 -NewTitle $t -Body $bodyIn -AgentRole impl -AgentRound 2 }) }
        Add-HarnessCase $cases '-Update: body lacking a template section' $true (-not (& $upd ($good -replace '(?m)^## DCO\s*$', '')))
        Add-HarnessCase $cases '-Update: body with a local path' $true (-not (& $upd ($good -replace '(?m)^## DCO', ('## DCO' + "`n" + 'C:' + '\Users\someone'))))
        Add-HarnessCase $cases '-Update: last line is not the sign-off' $true (-not (& $upd "$good`nmore"))
        Add-HarnessCase $cases '-Update: new title with a card number' $true (-not (& $upd $good ('ci(example): finish R' + 'H-03')))
        Add-HarnessCase $cases '-Update: nothing was sent while checks failed' $true ($patched.Count -eq $n)
        Add-HarnessCase $cases '-Update: a new title is sent with the body' $false (-not ((& $upd $good 'ci(example): another title') -and $patched[-1].title -eq 'ci(example): another title'))
        $existing.state = 'closed'
        Add-HarnessCase $cases '-Update: closed PR' $true (-not (& $upd $good))
        $existing.state = 'open'; $existing.base.ref = 'dev'
        Add-HarnessCase $cases '-Update: PR into dev' $true (-not (& $upd $good))
        $existing.base.ref = 'feature/v1'
        $existing.draft = $true; $n = $patched.Count
        $draftReason = Get-ThrownMessage { Invoke-Update -Number 12 -NewTitle '' -Body $good -AgentRole impl -AgentRound 2 }
        Add-HarnessCase $cases '-Update: a draft PR is refused as a draft, nothing sent' $true ([bool]$draftReason -and $draftReason -match 'No draft' -and $patched.Count -eq $n)
        $existing.draft = $false
        $existing.head.repo.full_name = 'someone/reaper-harness'; $n = $patched.Count
        Add-HarnessCase $cases '-Update: head from a fork' $true ((-not (& $upd $good)) -and $patched.Count -eq $n)
        $existing.head.repo.full_name = (Get-HarnessRepo)
        $existing.head.repo = $null; $n = $patched.Count
        $gone = $(try { Invoke-Update -Number 12 -NewTitle '' -Body $good -AgentRole impl -AgentRound 2 } catch { $_.Exception.Message })
        Add-HarnessCase $cases '-Update: deleted source repository (head.repo is null) says why and sends nothing' $true ($gone -match 'was deleted' -and $gone -notmatch 'cannot be found' -and $patched.Count -eq $n)
        $existing.head.repo = [pscustomobject]@{ full_name = (Get-HarnessRepo) }
        # a checkout without the template (or with one that has no sections) cannot say what the body needs: refused, nothing sent
        $n = $posted.Count; $m = $patched.Count
        Remove-Item -LiteralPath $templateFile
        $noTemplate = Get-ThrownMessage { Test-OpenRequest -Branch 'feat/example' -Base 'feature/v1' -PrTitle $goodTitle -Body $good -IsDraft $false -AgentRole impl -AgentRound 0 -HeadSha $sha }
        Add-HarnessCase $cases 'no template in the checkout: refused for that reason' $true ([bool]$noTemplate -and $noTemplate -match 'pull_request_template\.md is missing')
        $noTemplateOpen = Get-ThrownMessage { Invoke-Open -Branch 'feat/example' -Base 'feature/v1' -PrTitle $goodTitle -Body $good -IsDraft $false -AgentRole impl -AgentRound 0 }
        Add-HarnessCase $cases 'no template in the checkout: nothing is opened' $true ([bool]$noTemplateOpen -and $posted.Count -eq $n)
        $noTemplateUpdate = Get-ThrownMessage { Invoke-Update -Number 12 -NewTitle '' -Body $good -AgentRole impl -AgentRound 2 }
        Add-HarnessCase $cases 'no template in the checkout: -Update is refused for that reason, nothing sent' $true ([bool]$noTemplateUpdate -and $noTemplateUpdate -match 'pull_request_template\.md is missing' -and $patched.Count -eq $m)
        [IO.File]::WriteAllText($templateFile, "<!-- no headings -->`nsome text`n", [Text.UTF8Encoding]::new($false))
        $noHeadings = Get-ThrownMessage { Test-OpenRequest -Branch 'feat/example' -Base 'feature/v1' -PrTitle $goodTitle -Body $good -IsDraft $false -AgentRole impl -AgentRound 0 -HeadSha $sha }
        Add-HarnessCase $cases 'a template without sections: refused for that reason' $true ([bool]$noHeadings -and $noHeadings -match 'no level-2 headings')
        # the template of this very checkout: the sections the body must have are read from it
        $script:TemplateOverride = $null
        Add-HarnessCase $cases 'the template of this checkout has sections' $false (@(Get-TemplateHeadings).Count -eq 0)
        $selfText = Get-Content -Raw -LiteralPath $PSCommandPath
        Add-HarnessCase $cases 'source hygiene: pr-open.ps1' $false (@(Get-HarnessSourceProblems -Text $selfText -Name 'pr-open.ps1').Count -gt 0)
    } finally {
        Set-HarnessFake $null
        $script:TemplateOverride = $null
        Set-HarnessNeedles
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Complete-HarnessSelfTest $cases 'pr-open'
}

if ($SelfTest) { exit (Invoke-SelfTest) }
if ($Update) {
    if ($Pr -le 0 -or -not $BodyFile) { throw '-Update needs -Pr and -BodyFile (-Title is optional)' }
    Initialize-HarnessIdentity
    Write-Output (Invoke-Update -Number $Pr -NewTitle $Title -Body ([IO.File]::ReadAllText($BodyFile, [Text.UTF8Encoding]::new($false))) -AgentRole $Role -AgentRound $Round)
    exit 0
}
if (-not $Head -or -not $Title -or -not $BodyFile) { throw '-Head, -Title and -BodyFile are required' }
Initialize-HarnessIdentity
$bodyText = [IO.File]::ReadAllText($BodyFile, [Text.UTF8Encoding]::new($false))
Write-Output (Invoke-Open -Branch $Head -Base $BaseBranch -PrTitle $Title -Body $bodyText -IsDraft $Draft.IsPresent -AgentRole $Role -AgentRound $Round)

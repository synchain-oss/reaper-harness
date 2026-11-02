#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
#
# Run every self-test of the maintainer wrappers, offline: the -SelfTest of each script (in a child pwsh, so one failing
# script cannot hide another), the Node helper's own self-test, the criteria of the shared module that no single script
# owns, and the source-hygiene rules over every file of this directory together with the rules' own good and bad
# samples. Exit code 0 only when everything passed.
#   pwsh scripts/maintainer/self-test.ps1 [-Only push,pr-merge]    (-Only none: just the shared rules)
# Node comes from HARNESS_NODE / git config harness.node (the pinned Node of .node-version); without either, the node on PATH is
# used only when its major version is the pinned one. The repository's own check scripts run for real, with a needle file of the
# self-test as the personal needles.

[CmdletBinding()]
param([string[]]$Only = @())

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/HarnessGh.psm1') -Force

$Scripts = @('push', 'pr-open', 'pr-comment', 'pr-merge', 'new-worktree')

function Invoke-Child {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$Arguments)
    $started = [datetime]::UtcNow
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $seconds = [Math]::Round(([datetime]::UtcNow - $started).TotalSeconds, 1)
    $summary = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match '-SelfTest: |self-test|FAIL|PASS' } | Select-Object -Last 12)
    [pscustomobject]@{ Name = $Name; Code = $code; Seconds = $seconds; Lines = $summary }
}

function Test-HygieneRules {
    $cases = New-HarnessCases
    $good = "#!/usr/bin/env pwsh`n# SPDX-License-Identifier: MIT`nSet-StrictMode -Version Latest`n`$ErrorActionPreference = 'Stop'`n`$alpha = 1`n`$beta = `$alpha`n"
    Add-HarnessCase $cases 'hygiene: a clean sample passes' $false (@(Get-HarnessSourceProblems -Text $good -Name 'x').Count -gt 0)
    $badSamples = [ordered]@{
        'a variable differing only by case next to a variable named keys' = "$good`$keys = 1`n`$Alpha = 2`n"
        'an exit code taken from the whole output of the self-test' = "$good" + 'if ($x) { exit (' + 'Invoke-SelfTest) }' + "`n"
        'no SPDX header'            = $good -replace 'SPDX-License-Identifier: MIT', 'license: none'
        'no StrictMode'             = $good -replace 'Set-StrictMode -Version Latest', '# off'
        'no ErrorActionPreference'  = $good -replace '\$ErrorActionPreference = ''Stop''', '$ErrorActionPreference = ''Continue'''
        'a drive path'              = "$good`$p = '" + 'C:' + "\Users\someone\x'`n"
        'a home-directory path'     = "$good`$p = '/home/" + "someone/x'`n"
        'a task-card number form'   = "$good# see " + 'R' + 'H-02' + "`n"
        'a variable differing only by case' = "$good`$Alpha = 2`n"
        'a script that does not parse' = "$good`$x = (`n"
    }
    foreach ($label in $badSamples.Keys) {
        Add-HarnessCase $cases "hygiene: $label is caught" $true (@(Get-HarnessSourceProblems -Text $badSamples[$label] -Name 'x').Count -gt 0)
    }
    , $cases
}

<#
  Rules of the shared module that no single script owns: every case checks one criterion of lib/HarnessGh.psm1 with a
  counter-example, and a refusal is matched by its reason (a second reason behind the same refusal would hide a missing check).
  External commands (gh, git) are faked; the Node scripts of the repository (lib/maint.mjs, the privacy tool, the message rules) run for real.
#>
function Test-ModuleRules {
    $modCases = New-HarnessCases
    $modTmp = Join-Path ([IO.Path]::GetTempPath()) "harness-module-selftest-$PID"
    New-Item -ItemType Directory -Force -Path $modTmp | Out-Null
    # the repository's own privacy tool and message rules run for real, with a needle file of the self-test
    $modNeedleFile = New-HarnessSelfTestNeedles -Directory $modTmp
    $modLog = [System.Collections.Generic.List[string]]::new()
    $modRoot = Get-HarnessRepoRoot
    $modSign = Get-HarnessSignoff
    $modHead = 'a' * 40
    $mod = @{ Privacy = @{ Code = 0; Out = ''; Err = '' }; GraphQl = $null; Paged = $null; CheckRuns = $null; Runs = @{ total_count = 0; workflow_runs = @() }; ExtraReview = $null; Edit = { param($edits) } }
    $modRoutes = [ordered]@{
        '^gh api boom$'                   = { @{ Code = 2; Out = ''; Err = "boom`nsecond line" } }
        '^gh api longboom$'               = { @{ Code = 2; Out = ''; Err = 'e' * 9000 } }
        'pagedboom$|wordsboom more$'      = { @{ Code = 2; Out = ''; Err = 'boom' } }
        '^git -C \S+ status --boom$'      = { @{ Code = 128; Out = ''; Err = 'fatal: not a git repository' } }
        'collaborators/DLsnows/permission' = { 'admin' }
        'collaborators/[^/]+/permission'   = { @{ Code = 0; Out = 'read'; Err = '' } }
        'actions/runs\?head_sha=' = { $mod.Runs }
        'commits/\S+/check-runs'           = { $mod.CheckRuns }
        'pulls/7/comments'                 = { Read-HarnessFixture 'review-comments.json' }
        'pulls/7/reviews'                  = { $list = Read-HarnessFixture 'reviews.json'; if ($mod.ExtraReview) { @($list) + @($mod.ExtraReview) } else { $list } }
        'issues/7/comments'                = { Read-HarnessFixture 'issue-comments.json' }
        'api -X POST graphql'              = {
            param($argv)
            if ($mod.GraphQl) { return $mod.GraphQl }
            $asked = Get-Content -Raw ($argv[-1]) | ConvertFrom-Json
            if ($mod.Paged) { return & $mod.Paged $asked }
            if ($asked.query -match 'reviews\(') { $modEdits = Read-HarnessFixture 'review-edits.json'; & $mod.Edit $modEdits; return $modEdits }
            Read-HarnessFixture 'threads.json'
        }
    }
    $modTry = { param($block) try { & $block } catch { 'threw' } }
    try {
        Set-HarnessFake (New-HarnessFake -Routes $modRoutes -Log $modLog)
        Set-HarnessLockImpl { param($lockName, $lockBlock) & $lockBlock }
        Clear-HarnessPermCache

        # ---- external commands, API reads, GraphQL -------------------------------------------
        $modFailed = Get-ThrownMessage { Invoke-HarnessExternal gh @('api', 'boom') }
        $modHidden = [string][char]0x200B
        Add-HarnessCase $modCases 'same text: the same characters' $false (-not (Test-HarnessSameText 'feature/v1' 'feature/v1'))
        Add-HarnessCase $modCases 'same text: a zero-width space makes it another text' $true (-not (Test-HarnessSameText "feature/v1$modHidden" 'feature/v1'))
        Add-HarnessCase $modCases 'same text: another letter case makes it another text' $true (-not (Test-HarnessSameText 'Feature/v1' 'feature/v1'))
        Add-HarnessCase $modCases 'same text: a zero-width space keeps a text out of a list' $true (-not (Test-HarnessTextIn "重要$modHidden" @('红旗', '重要')))
        Add-HarnessCase $modCases 'same text: in the list' $false (-not (Test-HarnessTextIn '重要' @('红旗', '重要')))
        Add-HarnessCase $modCases 'external: a non-zero exit code is an error naming the command, the code and the whole stderr' $true ($modFailed -ceq "gh api boom failed (exit code 2): boom`nsecond line")
        Add-HarnessCase $modCases 'external: an option does not push the endpoint out of the name of a command' $true ((Get-ThrownMessage { Invoke-HarnessExternal gh @('api', '--paginate', '--slurp', 'pagedboom') }) -cmatch '^gh api pagedboom failed \(exit code 2\)')
        Add-HarnessCase $modCases 'external: a command is named by its first three words that are not options' $true ((Get-ThrownMessage { Invoke-HarnessExternal gh @('api', '-X', 'PUT', 'wordsboom', 'more') }) -cmatch '^gh api PUT wordsboom failed \(exit code 2\)')
        Add-HarnessCase $modCases 'external: a git command is named by its subcommand, not by -C and the path' $true ((Get-ThrownMessage { Invoke-HarnessGit @('status', '--boom') }) -ceq 'git status failed (exit code 128): fatal: not a git repository')
        $modLong = Get-ThrownMessage { Invoke-HarnessExternal gh @('api', 'longboom') }
        Add-HarnessCase $modCases 'external: a long stderr is cut at about 4 KB and says so' $true ($modLong.Length -lt 4300 -and $modLong -match 'stderr cut at 4096 characters\)$')
        Add-HarnessCase $modCases 'external: -AllowFail hands the answer back instead' $false ((Invoke-HarnessExternal gh @('api', 'boom') -AllowFail).Code -ne 2)
        # the stderr file: gone after a command that ran and after one that could not even start (the real commands, a private temp directory)
        $modTempDir = Join-Path $modTmp 'stderr-files'
        New-Item -ItemType Directory -Force -Path $modTempDir | Out-Null
        $modTempSaved = @($env:TMP, $env:TEMP)
        Set-HarnessFake $null
        try {
            $env:TMP = $modTempDir; $env:TEMP = $modTempDir
            $modNoExe = Get-ThrownMessage { Invoke-HarnessExternal 'harness-no-such-command-5d2a' @('x') }
            $modLeftAfterNoExe = @(Get-ChildItem -LiteralPath $modTempDir -Force).Count
            Invoke-HarnessExternal git @('--version') | Out-Null
            $modLeftAfterRun = @(Get-ChildItem -LiteralPath $modTempDir -Force).Count
        } finally {
            $env:TMP = $modTempSaved[0]; $env:TEMP = $modTempSaved[1]
            Set-HarnessFake (New-HarnessFake -Routes $modRoutes -Log $modLog)
        }
        Add-HarnessCase $modCases 'external: a command that cannot start is an error and leaves no stderr file behind' $true ($modNoExe -and $modLeftAfterNoExe -eq 0)
        Add-HarnessCase $modCases 'external: a command that ran leaves no stderr file behind' $false ($modLeftAfterRun -ne 0)
        Add-HarnessCase $modCases 'api read: a failing call is an error' $true ($null -ne (Get-ThrownMessage { Get-HarnessApi 'boom' }))
        Add-HarnessCase $modCases 'api read: -AllowFail turns a failing call into null' $false ($null -ne (Get-HarnessApi 'boom' -AllowFail))
        $mod.GraphQl = @{ errors = @(@{ message = 'bad query' }) }
        Add-HarnessCase $modCases 'graphql: errors in the answer are an error' $true ((Get-ThrownMessage { Invoke-HarnessGraphQL -Query 'query { x }' }) -match '^GraphQL error: bad query$')
        $mod.GraphQl = @{ data = @{ ok = $true }; errors = $null }
        Add-HarnessCase $modCases 'graphql: an answer without errors passes through' $false (-not (Invoke-HarnessGraphQL -Query 'query { x }').data.ok)
        $mod.GraphQl = $null
        # GraphQL pages: the second page is asked for with the cursor of the first, its nodes count; every page is asked for this PR
        $modAsked = [System.Collections.Generic.List[string]]::new()
        $mod.Paged = {
            param($asked)
            $modAsked.Add("$($asked.variables.number)/$($asked.variables.after)")
            $second = [string]$asked.variables.after -ceq 'cursor-1'
            $isEdits = $asked.query -match 'reviews\('
            $node = if ($isEdits) { @{ databaseId = $(if ($second) { 2 } else { 1 }); updatedAt = '2026-11-01T10:00:00Z'; lastEditedAt = $null } }
            else { @{ id = $(if ($second) { 'T2' } else { 'T1' }); isResolved = $true; comments = @{ nodes = @() } } }
            $page = @{ pageInfo = @{ hasNextPage = (-not $second); endCursor = $(if ($second) { 'cursor-2' } else { 'cursor-1' }) }; nodes = @($node) }
            $key = if ($isEdits) { 'reviews' } else { 'reviewThreads' }
            @{ data = @{ repository = @{ pullRequest = @{ $key = $page } } } }
        }
        $modThreadPages = @(Get-HarnessReviewThreads 7)
        Add-HarnessCase $modCases 'graphql: the review threads of the second page are read' $false ((@($modThreadPages | ForEach-Object id) -join ',') -cne 'T1,T2')
        Add-HarnessCase $modCases 'graphql: the second page of threads is asked with the cursor of the first, for this PR' $false (($modAsked -join ' ') -cne '7/ 7/cursor-1')
        $modAsked.Clear()
        $modEditPages = Get-HarnessReviewEdits 42
        Add-HarnessCase $modCases 'graphql: the edit times of the second page are read' $false (-not ($modEditPages.ContainsKey('1') -and $modEditPages.ContainsKey('2')))
        Add-HarnessCase $modCases 'graphql: the second page of edit times is asked with the cursor of the first, for this PR' $false (($modAsked -join ' ') -cne '42/ 42/cursor-1')
        $mod.Paged = $null
        Add-HarnessCase $modCases 'PowerShell 7.4 and older are refused (-DateKind)' $true ((-not (Test-HarnessPwshVersion 7 4)) -and (-not (Test-HarnessPwshVersion 6 9)))
        Add-HarnessCase $modCases 'PowerShell 7.5 and newer are accepted' $false (-not ((Test-HarnessPwshVersion 7 5) -and (Test-HarnessPwshVersion 7 6) -and (Test-HarnessPwshVersion 8 0)))

        # ---- the tools of the repository: privacy tool, lib/maint.mjs, message rules ----------
        # a checkout without the tools: every lookup is an error, never a pass (the node of the environment is not asked, nothing runs)
        $modEmpty = Join-Path $modTmp 'empty'
        New-Item -ItemType Directory -Force -Path $modEmpty | Out-Null
        $modNodeSaved = $env:HARNESS_NODE
        Set-HarnessFake $null
        Set-HarnessRepoRoot $modEmpty
        $env:HARNESS_NODE = 'node'
        $modMissing = Get-ThrownMessage { Invoke-HarnessNodeScript 'scripts/check-privacy.mjs' @('--text', 'x') }
        $modMissingText = Get-ThrownMessage { Test-PublicText 'plain text' }
        $env:HARNESS_NODE = $modNodeSaved
        Set-HarnessRepoRoot $modRoot
        Set-HarnessFake (New-HarnessFake -Routes $modRoutes -Log $modLog)
        Add-HarnessCase $modCases 'node script: a checkout without the script is an error, never a pass' $true ($modMissing -match '^scripts/check-privacy\.mjs is missing in this checkout')
        Add-HarnessCase $modCases 'public text: a checkout without the tools is an error, never a pass' $true ($modMissingText -match 'is missing in this checkout')
        $modMaintBad = Get-ThrownMessage { Invoke-HarnessMaint -Command 'review-state' -Content 'not json' }
        Add-HarnessCase $modCases 'maint.mjs: an error answer is an error' $true ($modMaintBad -match '^maint\.mjs review-state: ')
        $modMaintOk = & $modTry { Invoke-HarnessMaint -Command 'review-state' -Content '[]' }
        Add-HarnessCase $modCases 'maint.mjs: a real answer is parsed' $false ($modMaintOk -is [string] -or (Get-HarnessProp $modMaintOk 'rounds') -ne 0 -or $null -ne (Get-HarnessProp $modMaintOk 'summary'))
        $modSameAuthors = & $modTry { Get-HarnessSameAuthors }
        Add-HarnessCase $modCases 'maint.mjs: the author list of check-commits.mjs arrives, the maintainer address and the no-reply address GitHub uses' $false (-not (@($modSameAuthors) -ccontains 'noreply@synchain.ca' -and @($modSameAuthors) -ccontains '140901583+dlsnows@users.noreply.github.com'))
        $modAi = 'Co-Authored' + '-By: a <a@b.c>'
        $modSession = 'Cla' + 'ude-Session: https://example.invalid/s'
        # a finding or a crash of the privacy tool is simulated by a route in front of the real tool; every other case runs the real one
        $modPrivacyRoutes = [ordered]@{ 'check-privacy\.mjs --text' = { $mod.Privacy } }
        foreach ($modRouteKey in $modRoutes.get_Keys()) { $modPrivacyRoutes[$modRouteKey] = $modRoutes[$modRouteKey] }
        Set-HarnessFake (New-HarnessFake -Routes $modPrivacyRoutes -Log $modLog)
        $mod.Privacy = @{ Code = 1; Out = '[stand-in] finding'; Err = '' }
        $modPub = Test-PublicText 'plain text'
        Add-HarnessCase $modCases 'public text: a finding of the privacy tool is a finding' $true ((-not $modPub.Ok) -and ($modPub.Findings -join ';') -match 'privacy check failed \(exit 1\).*stand-in')
        $mod.Privacy = @{ Code = 2; Out = ''; Err = 'Cannot find module' }
        $modCrash = Test-PublicText 'plain text'
        Add-HarnessCase $modCases 'public text: a crashed privacy tool is a finding, not a pass' $true ((-not $modCrash.Ok) -and ($modCrash.Findings -join ';') -match 'Cannot find module')
        $mod.Privacy = @{ Code = 0; Out = ''; Err = '' }
        Add-HarnessCase $modCases 'public text: a privacy tool that answers clean is clean' $false (-not (Test-PublicText 'plain text').Ok)
        Set-HarnessFake (New-HarnessFake -Routes $modRoutes -Log $modLog)
        Add-HarnessCase $modCases 'public text: a clean text passes the real tool' $false (-not (Test-PublicText 'plain text').Ok)
        Add-HarnessCase $modCases 'public text: a personal needle of the needle file is a finding' $true (((Test-PublicText "text $(Get-HarnessFakeNeedle)").Findings -join ';') -match 'privacy check failed \(exit 1\)')
        Add-HarnessCase $modCases 'public text: a local path is a finding' $true (((Test-PublicText ('see C:' + '\Users\someone\x')).Findings -join ';') -match 'privacy check failed \(exit 1\)')
        Add-HarnessCase $modCases 'public text: an AI attribution trailer is a finding even when the privacy tool is clean' $true (-not (Test-PublicText "text`n$modAi").Ok)
        Add-HarnessCase $modCases 'public text: an AI attribution trailer split by an invisible character is a finding all the same' $true (-not (Test-PublicText "text`n$($modAi.Substring(0, 3))$([char]0x200B)$($modAi.Substring(3))").Ok)
        Add-HarnessCase $modCases 'public text: Assert-PublicText stops with the label' $true ((Get-ThrownMessage { Assert-PublicText "text`n$modAi" 'my label' }) -match '^my label failed the public-text check, not sent')

        # ---- commit messages and PR texts: the rules are those of scripts/check-commits.mjs, answers are matched by their reason
        $modOk = "feat(example): add it`n`nBody text.`n`n$modSign"
        # a tool that falls over gives no answer to any of these cases: each one turns red under its own name instead of ending the self-test
        $modErr = { param($text, $merge = $false, $exactly = $false) try { (@(Get-MessageErrors $text -Merge:$merge -ExactlyOne:$exactly)) -join ' | ' } catch { "threw: $($_.Exception.Message)" } }
        Add-HarnessCase $modCases 'message: a clean message has no problem' $false ((& $modErr $modOk) -ne '')
        Add-HarnessCase $modCases 'message: an AI attribution trailer' $true ((& $modErr "$modOk`n$modAi") -match 'AI attribution trailers are not allowed')
        Add-HarnessCase $modCases 'message: an AI session trailer' $true ((& $modErr "$modOk`n$modSession") -match 'AI attribution trailers are not allowed')
        Add-HarnessCase $modCases 'message: an AI trailer in other letter case' $true ((& $modErr "$modOk`n$($modAi.ToUpperInvariant())") -match 'AI attribution trailers are not allowed')
        Add-HarnessCase $modCases 'message: the sign-off of the maintainer in other letter case' $true ((& $modErr "feat(example): add it`n`nSigned-off-by: dlsnows <noreply@synchain.ca>") -match 'every Signed-off-by line must be')
        Add-HarnessCase $modCases 'message: the sign-off key in lower case' $true ((& $modErr "feat(example): add it`n`nsigned-off-by: DLsnows <noreply@synchain.ca>") -match 'every Signed-off-by line must be')
        Add-HarnessCase $modCases 'message: no sign-off' $true ((& $modErr "feat(example): add it`n`nBody.") -match 'missing Signed-off-by')
        Add-HarnessCase $modCases 'message: a foreign trailer in a paragraph that is a quarter trailers and holds the sign-off' $true ((& $modErr "feat(example): add it`n`nBody.`n`nReviewed-by: Someone`nprose`nmore prose`nand more`n$modSign") -match 'only allowed trailer')
        Add-HarnessCase $modCases 'message: a colon line in a prose paragraph is no trailer block' $false ((& $modErr "feat(example): add it`n`n$modSign`n`nNote: x`nprose`nprose`nprose`nprose") -match 'only allowed trailer')
        Add-HarnessCase $modCases 'message: the type in upper case' $true ((& $modErr "Feat(example): add it`n`n$modSign") -match 'subject must be')
        Add-HarnessCase $modCases 'message: a subject without a scope' $true ((& $modErr "feat: add it`n`n$modSign") -match 'subject must be')
        Add-HarnessCase $modCases 'message: the default subject of git revert' $false ((& $modErr "Revert `"feat(example): add it`"`n`n$modSign") -ne '')
        Add-HarnessCase $modCases 'message: a merge commit needs neither subject nor sign-off' $false ((& $modErr "Merge branch 'feature/v1' into feat/example" $true) -ne '')
        Add-HarnessCase $modCases 'message: the same merge message is judged as a normal commit without the merge flag' $true ((& $modErr "Merge branch 'feature/v1' into feat/example") -match 'missing Signed-off-by')
        Add-HarnessCase $modCases 'message: two sign-offs where exactly one is required' $true ((& $modErr "$modOk`n$modSign" $false $true) -match 'exactly one Signed-off-by line is allowed')
        Add-HarnessCase $modCases 'message: two sign-offs where several are allowed' $false ((& $modErr "$modOk`n$modSign") -ne '')
        Add-HarnessCase $modCases 'message: a personal needle of the needle file' $true ((& $modErr "feat(example): add it`n`n$(Get-HarnessFakeNeedle)`n`n$modSign") -match '\[personal\]')
        Add-HarnessCase $modCases 'message: a local path' $true ((& $modErr ("feat(example): add it`n`nsee C:" + "\Users\someone\x`n`n$modSign")) -match '\[win-user-path\]')
        Add-HarnessCase $modCases 'message: a card number' $true ((& $modErr ("feat(example): add it`n`nsee R" + "H-04`n`n$modSign")) -match '\[card-id\]')
        $modPrErr = { param($title, $body) try { (@(Get-PrTextErrors -Title $title -Body $body)) -join ' | ' } catch { "threw: $($_.Exception.Message)" } }
        Add-HarnessCase $modCases 'PR text: a clean title and body' $false ((& $modPrErr 'feat(example): add it' "Body.`n`n$modSign") -ne '')
        Add-HarnessCase $modCases 'PR text: the type of the title in upper case' $true ((& $modPrErr 'Feat(example): add it' "Body.`n`n$modSign") -match 'PR title must be')
        Add-HarnessCase $modCases 'PR text: the sign-off on the last line in lower case' $true ((& $modPrErr 'feat(example): add it' "Body.`n`nsigned-off-by: DLsnows <noreply@synchain.ca>") -match 'last line must be')
        Add-HarnessCase $modCases 'PR text: an empty body has no sign-off' $true ((& $modPrErr 'feat(example): add it' '') -match 'last line must be')
        Add-HarnessCase $modCases 'PR text: a personal needle of the needle file in the body' $true ((& $modPrErr 'feat(example): add it' "Body $(Get-HarnessFakeNeedle).`n`n$modSign") -match '\[personal\]')
        # a tool that does not answer is an error: no answer is never "no problem"
        Set-HarnessFake (New-HarnessFake -Routes ([ordered]@{ 'maint\.mjs (message|pr-text|text) ' = { @{ Code = 1; Out = ''; Err = 'boom' } } }) -Log $modLog)
        Add-HarnessCase $modCases 'message: a crashed tool is an error, never "no problem"' $true ((Get-ThrownMessage { Get-MessageErrors $modOk }) -match 'maint\.mjs message produced no output')
        Add-HarnessCase $modCases 'PR text: a crashed tool is an error, never "no problem"' $true ((Get-ThrownMessage { Get-PrTextErrors -Title 'feat(example): add it' -Body "Body.`n`n$modSign" }) -match 'maint\.mjs pr-text produced no output')
        Add-HarnessCase $modCases 'public text: a crashed attribution lookup is an error, never a pass' $true ((Get-ThrownMessage { Test-PublicText 'plain text' }) -match 'maint\.mjs text produced no output')
        Set-HarnessFake (New-HarnessFake -Routes ([ordered]@{ 'maint\.mjs message ' = { 'this is not json' } }) -Log $modLog)
        Add-HarnessCase $modCases 'message: an answer that cannot be read is an error, never "no problem"' $true ($null -ne (Get-ThrownMessage { Get-MessageErrors $modOk }))
        Set-HarnessFake (New-HarnessFake -Routes $modRoutes -Log $modLog)

        # ---- agent markers and the permission lookup -----------------------------------------
        $modMarker = { param($extra) Get-ThrownMessage { New-AgentMarker -Role impl -Kind note -Round 1 -Head $modHead -Extra $extra } }
        foreach ($modField in @([ordered]@{ 'bad key' = 'x' }, [ordered]@{ Bot = 'x' }, [ordered]@{ 'bot-run' = 'a b' }, [ordered]@{ 'bot-run' = 'a>b' }, [ordered]@{ 'bot-run' = '' })) {
            Add-HarnessCase $modCases "marker: the invalid field '$(@($modField.Keys)[0])=$(@($modField.Values)[0])'" $true ((& $modMarker $modField) -match 'Invalid marker field')
        }
        Add-HarnessCase $modCases 'marker: two valid fields' $false ((New-AgentMarker -Role review -Kind disposition -Round 2 -Head $modHead -Extra ([ordered]@{ 'bot-run' = '77'; 'in-reply-to' = '1,2' })) -ne '<!-- harness-agent v1 role=review kind=disposition round=2 head=aaaaaaa bot-run=77 in-reply-to=1,2 -->')
        Add-HarnessCase $modCases 'marker: a kind in upper case is refused' $true ((Get-ThrownMessage { New-AgentMarker -Role impl -Kind 'Note' -Round 1 -Head $modHead }) -match 'Kind')
        Add-HarnessCase $modCases 'marker: a head in upper case is refused' $true ((Get-ThrownMessage { New-AgentMarker -Role impl -Kind note -Round 1 -Head ('A' * 40) }) -match 'Head')
        Add-HarnessCase $modCases 'marker: a role in upper case is refused' $true ((Get-ThrownMessage { New-AgentMarker -Role 'IMPL' -Kind note -Round 1 -Head $modHead }) -match 'Role')
        $modBefore = $modLog.Count
        foreach ($modLogin in @('a/b', '-x', 'x-', 'with space', 'a;b', '..')) {
            $modAnswer = & $modTry { Test-RepoWriter $modLogin }
            Add-HarnessCase $modCases "permission: the login '$modLogin' is refused without asking GitHub" $true (($modAnswer -is [bool]) -and -not $modAnswer -and $modLog.Count -eq $modBefore)
        }
        Add-HarnessCase $modCases 'permission: a login with write access' $false (-not (Test-RepoWriter 'DLsnows'))
        Add-HarnessCase $modCases 'permission: a login with read access only' $true (-not (Test-RepoWriter 'someone-else'))

        # ---- the four comment sources: review edit times, classes, answered or not -----------
        $modActivity = { param($editor) $mod.Edit = $editor; try { Get-HarnessPrActivity 7 } finally { $mod.Edit = { param($edits) } } }
        $modUpdated = { param($activity, $reviewId) [string](@($activity.Reviews | Where-Object { [string]$_.id -eq $reviewId })[0].updated_at) }
        $modLater = & $modActivity { param($edits) $nodes = $edits.data.repository.pullRequest.reviews.nodes; $nodes[0].lastEditedAt = '2026-11-01T11:30:00Z'; $nodes[1].updatedAt = '2026-11-01T12:00:00Z'; $nodes[1].lastEditedAt = '2026-11-01T11:00:00Z' }
        Add-HarnessCase $modCases 'review edits: the later of the two GraphQL times, and later than the submission, is the review''s updated_at' $false (-not ((& $modUpdated $modLater '7000000001') -eq '2026-11-01T11:30:00Z' -and (& $modUpdated $modLater '7000000002') -eq '2026-11-01T12:00:00Z'))
        $modEarlier = & $modActivity { param($edits) $edits.data.repository.pullRequest.reviews.nodes[1].updatedAt = '2026-11-01T09:00:00Z' }
        Add-HarnessCase $modCases 'review edits: an edit time older than the submission leaves the submission' $false ((& $modUpdated $modEarlier '7000000002') -ne '2026-11-01T10:25:00Z')
        $modNoEdit = Get-ThrownMessage { & $modActivity { param($edits) $edits.data.repository.pullRequest.reviews.nodes = @($edits.data.repository.pullRequest.reviews.nodes[0]) } }
        Add-HarnessCase $modCases 'review edits: a review GraphQL has no edit time for is an error' $true ($modNoEdit -match 'GraphQL has no edit time for review 7000000002')

        # a pending review is a draft: no submitted_at, no edit time in GraphQL; it stays out of the table and a note says so
        $modPendingReview = { param($state, $submitted) $r = [pscustomobject]@{ id = 7000000099; node_id = 'PRR_x'; user = [pscustomobject]@{ login = 'DLsnows' }; body = 'draft'; state = $state; html_url = 'u'; commit_id = $modHead }; if ($submitted) { $r | Add-Member -NotePropertyName submitted_at -NotePropertyValue $submitted }; $r }
        $modWithReview = {
            param($extra)
            $mod.ExtraReview = $extra
            $modErrWriter = [IO.StringWriter]::new()
            $modErrSaved = [Console]::Error
            [Console]::SetError($modErrWriter)
            try { $modSeen = & $modTry { Get-HarnessPrActivity 7 } } finally { [Console]::SetError($modErrSaved); $mod.ExtraReview = $null }
            [pscustomobject]@{ Activity = $modSeen; Err = $modErrWriter.ToString() }
        }
        $modNoReview = { param($seen) ($seen.Activity -isnot [string]) -and @($seen.Activity.Reviews | Where-Object { [string]$_.id -eq '7000000099' }).Count -eq 0 }
        $modPendingSeen = & $modWithReview (& $modPendingReview 'PENDING' $null)
        Add-HarnessCase $modCases 'pending review: left out before the edit times are looked up' $true (& $modNoReview $modPendingSeen)
        Add-HarnessCase $modCases 'pending review: a note on stderr says so' $true ($modPendingSeen.Err -match '1 pending review\(s\) on #7 are left out')
        Add-HarnessCase $modCases 'pending review: left out by its state even when it has a time' $true (& $modNoReview (& $modWithReview (& $modPendingReview 'PENDING' '2026-11-01T10:00:00Z')))
        Add-HarnessCase $modCases 'pending review: a review without a time is left out by that alone' $true (& $modNoReview (& $modWithReview (& $modPendingReview 'COMMENTED' $null)))
        Add-HarnessCase $modCases 'pending review: no note without one' $false ((& $modWithReview $null).Err -ne '')

        $modBase = & $modActivity { param($edits) }
        $modState = Get-HarnessReviewState $modBase
        $modItems = @(Get-HarnessCommentItems -Activity $modBase -State $modState)
        $modKind = { param($source, $id) [string](@($modItems | Where-Object { $_.Source -eq $source -and $_.Id -eq $id })[0].Kind) }
        Add-HarnessCase $modCases 'classes: the summary of the bot' $false ((& $modKind 'issue' '9000000001') -ne 'bot-summary')
        Add-HarnessCase $modCases 'classes: a marked comment of the maintainer is an agent comment' $false ((& $modKind 'issue' '9000000002') -ne 'agent')
        Add-HarnessCase $modCases 'classes: an inline comment of the bot' $false ((& $modKind 'review-comment' '8000000001') -ne 'bot')
        Add-HarnessCase $modCases 'classes: an inline reply of the maintainer' $false ((& $modKind 'review-comment' '8000000002') -ne 'agent')
        Add-HarnessCase $modCases 'classes: an empty review of the bot with an inline comment of the bot stays the bot''s' $false ((& $modKind 'review' '7000000001') -ne 'bot')
        Add-HarnessCase $modCases 'classes: an empty review that only holds our replies is ours' $false ((& $modKind 'review' '7000000002') -ne 'agent')

        $modReview = { param($id, $state, $login, $at) [pscustomobject]@{ id = $id; state = $state; body = 'text'; user = [pscustomobject]@{ login = $login }; submitted_at = $at; updated_at = $at; html_url = 'u' } }
        $modApproved = {
            param($approval)
            $found = [pscustomobject]@{ Issue = @(); Review = @(); Threads = @(); Reviews = @((& $modReview 1 'CHANGES_REQUESTED' 'DLsnows' '2026-11-01T10:00:00Z'), $approval) }
            [bool](@(Get-HarnessCommentItems -Activity $found -State $null | Where-Object { $_.Source -eq 'review' -and $_.Id -eq '1' })[0].ApprovedLater)
        }
        Add-HarnessCase $modCases 'approval: a later approval of the same person lifts the change request' $false (-not (& $modApproved (& $modReview 2 'APPROVED' 'DLsnows' '2026-11-01T11:00:00Z')))
        Add-HarnessCase $modCases 'approval: an approval from before the change request lifts nothing' $true (-not (& $modApproved (& $modReview 2 'APPROVED' 'DLsnows' '2026-11-01T09:00:00Z')))
        Add-HarnessCase $modCases 'approval: an approval by another person lifts nothing' $true (-not (& $modApproved (& $modReview 2 'APPROVED' 'someone-else' '2026-11-01T11:00:00Z')))
        Add-HarnessCase $modCases 'approval: a comment review after the change request lifts nothing' $true (-not (& $modApproved (& $modReview 2 'COMMENTED' 'DLsnows' '2026-11-01T11:00:00Z')))
        # an approval or a dismissed review with a body is an opinion like any other; without a body there is nothing to read
        $modReviewTable = {
            param($state, $login, $text)
            $found = [pscustomobject]@{ Issue = @(); Review = @(); Threads = @(); Reviews = @([pscustomobject]@{ id = 40; state = $state; body = $text; user = [pscustomobject]@{ login = $login }; submitted_at = '2026-11-01T10:00:00Z'; updated_at = '2026-11-01T10:00:00Z'; html_url = 'u' }) }
            @(Get-HarnessCommentItems -Activity $found -State $null)
        }
        foreach ($modBodyState in 'APPROVED', 'DISMISSED') {
            $modMine = @(& $modReviewTable $modBodyState 'DLsnows' 'Looks fine, but see the naming.')
            Add-HarnessCase $modCases "reviews: a $modBodyState review with a body is in the table, as the maintainer's opinion" $true ($modMine.Count -eq 1 -and $modMine[0].Kind -eq 'user')
            Add-HarnessCase $modCases "reviews: a $modBodyState review with a body needs an answer" $true ($modMine.Count -eq 1 -and -not (Test-HarnessResponded -Item $modMine[0] -Items $modMine -State $null))
            $modTheirs = @(& $modReviewTable $modBodyState 'someone-else' 'Please change this.')
            Add-HarnessCase $modCases "reviews: a $modBodyState review with a body by an outsider is external" $true ($modTheirs.Count -eq 1 -and $modTheirs[0].Kind -eq 'external')
            Add-HarnessCase $modCases "reviews: an empty $modBodyState review stays out of the table" $false (@(& $modReviewTable $modBodyState 'DLsnows' '').Count -ne 0)
            Add-HarnessCase $modCases "reviews: a $modBodyState review of only blanks stays out of the table" $false (@(& $modReviewTable $modBodyState 'DLsnows' "  `n ").Count -ne 0)
        }

        $modItem = {
            param($over)
            $row = [pscustomobject]@{ Source = 'issue'; Id = '1'; Author = 'x'; Kind = 'user'; Body = 'text'; Created = '2026-11-01T10:00:00Z'; Updated = '2026-11-01T10:00:00Z'
                ThreadId = $null; Resolved = $null; ReviewId = ''; InReplyTo = @(); State = ''; Comments = @(); ApprovedLater = $false }
            foreach ($key in $over.Keys) { $row.$key = $over[$key] }
            $row
        }
        $modAnswered = { param($item, $all, $state = $null) [bool](Test-HarnessResponded -Item $item -Items @($all) -State $state) }
        $modUser = & $modItem @{}
        $modReplyLater = & $modItem @{ Id = '2'; Kind = 'agent'; Created = '2026-11-01T10:10:00Z'; Updated = '2026-11-01T10:10:00Z'; InReplyTo = @('1') }
        Add-HarnessCase $modCases 'answered: a comment of the maintainer without an answer' $true (-not (& $modAnswered $modUser @($modUser)))
        Add-HarnessCase $modCases 'answered: an agent comment that names it later' $false (-not (& $modAnswered $modUser @($modUser, $modReplyLater)))
        $modReplyUser = & $modItem @{ Id = '2'; Kind = 'user'; Created = '2026-11-01T10:10:00Z'; Updated = '2026-11-01T10:10:00Z'; InReplyTo = @('1') }
        Add-HarnessCase $modCases 'answered: a comment that names it but is not an agent comment does not answer' $true (-not (& $modAnswered $modUser @($modUser, $modReplyUser)))
        $modSummary = & $modItem @{ Kind = 'bot-summary' }
        $modSummaryState = { param($runs) [pscustomobject]@{ summaries = @([pscustomobject]@{ id = '1'; runId = '55' }); dispositionRuns = $runs } }
        Add-HarnessCase $modCases 'answered: a bot summary with a disposition of its run' $false (-not (& $modAnswered $modSummary @($modSummary) (& $modSummaryState @('55'))))
        Add-HarnessCase $modCases 'answered: a bot summary without any disposition' $true (-not (& $modAnswered $modSummary @($modSummary) (& $modSummaryState @())))
        Add-HarnessCase $modCases 'answered: a bot summary whose run has no disposition' $true (-not (& $modAnswered $modSummary @($modSummary) (& $modSummaryState @('99'))))
        $modInline = & $modItem @{ Id = '10'; Source = 'review-comment'; ThreadId = 'T1' }
        $modInlineReply = { param($created) & $modItem @{ Id = '11'; Source = 'review-comment'; Kind = 'agent'; ThreadId = 'T1'; Created = $created; Updated = $created } }
        Add-HarnessCase $modCases 'answered: an inline comment with a reply of ours in its thread after the comment' $false (-not (& $modAnswered $modInline @($modInline, (& $modInlineReply '2026-11-01T10:10:00Z'))))
        Add-HarnessCase $modCases 'answered: an inline comment whose only reply of ours is older than its last edit' $true (-not (& $modAnswered $modInline @($modInline, (& $modInlineReply '2026-11-01T09:00:00Z'))))
        $modOtherThread = & $modItem @{ Id = '12'; Source = 'review-comment'; Kind = 'agent'; ThreadId = 'T2'; Created = '2026-11-01T10:10:00Z'; Updated = '2026-11-01T10:10:00Z' }
        Add-HarnessCase $modCases 'answered: a later reply of ours in another thread answers nothing here' $true (-not (& $modAnswered $modInline @($modInline, $modOtherThread)))
        Add-HarnessCase $modCases 'answered: an inline comment of the maintainer that is only resolved' $true (-not (& $modAnswered (& $modItem @{ Id = '10'; Source = 'review-comment'; ThreadId = 'T1'; Resolved = $true }) @($modInline)))
        $modBotInline = { param($resolved) & $modItem @{ Id = '10'; Source = 'review-comment'; Kind = 'bot'; ThreadId = 'T1'; Resolved = $resolved } }
        Add-HarnessCase $modCases 'answered: an inline comment of a bot in a resolved thread' $false (-not (& $modAnswered (& $modBotInline $true) @((& $modBotInline $true))))
        Add-HarnessCase $modCases 'answered: an inline comment of a bot in an open thread' $true (-not (& $modAnswered (& $modBotInline $false) @((& $modBotInline $false))))
        $modEmptyReview = & $modItem @{ Id = '20'; Source = 'review'; State = 'COMMENTED'; Body = ''; Comments = @('10') }
        Add-HarnessCase $modCases 'answered: an empty review whose inline comment has no answer' $true (-not (& $modAnswered $modEmptyReview @($modEmptyReview, $modInline)))
        Add-HarnessCase $modCases 'answered: an empty review whose inline comments are all answered' $false (-not (& $modAnswered $modEmptyReview @($modEmptyReview, $modInline, (& $modInlineReply '2026-11-01T10:10:00Z'))))
        $modChange = { param($lifted) & $modItem @{ Id = '30'; Source = 'review'; State = 'CHANGES_REQUESTED'; ApprovedLater = $lifted } }
        Add-HarnessCase $modCases 'answered: a change request that nobody lifted or answered' $true (-not (& $modAnswered (& $modChange $false) @((& $modChange $false))))
        Add-HarnessCase $modCases 'answered: a change request lifted by a later approval' $false (-not (& $modAnswered (& $modChange $true) @((& $modChange $true))))
        # bot comments: the words of a bot need an answer too; only the two pr-agent notices and an empty review without inline comments do not
        $modBot = { param($over) $base = @{ Id = '50'; Kind = 'bot'; Author = 'github-actions[bot]' }; foreach ($key in $over.Keys) { $base[$key] = $over[$key] }; & $modItem $base }
        $modBotReply = & $modItem @{ Id = '51'; Kind = 'agent'; Created = '2026-11-01T10:10:00Z'; Updated = '2026-11-01T10:10:00Z'; InReplyTo = @('50') }
        $modDeepseek = & $modBot @{ Body = "### DeepSeek PR review (``deepseek``, manual run)`n`n- Possible issue." }
        Add-HarnessCase $modCases 'answered: a manual deepseek-review comment nobody named' $true (-not (& $modAnswered $modDeepseek @($modDeepseek)))
        Add-HarnessCase $modCases 'answered: a manual deepseek-review comment named by a later agent comment' $false (-not (& $modAnswered $modDeepseek @($modDeepseek, $modBotReply)))
        Add-HarnessCase $modCases 'answered: a plain comment of a bot nobody named' $true (-not (& $modAnswered (& $modBot @{ Body = 'Some text.' }) @((& $modBot @{ Body = 'Some text.' }))))
        # the notices in their real shape
        $modNoticeCases = [ordered]@{ '[Persistent review]' = '**[Persistent review](https://github.com/o/r/pull/7#issuecomment-1)** updated to latest commit https://github.com/o/r/commit/abc1234'; 'Failed to generate' = 'Failed to generate code suggestions for PR' }
        foreach ($modNoticeName in $modNoticeCases.get_Keys()) {
            $modNotice = & $modBot @{ Body = $modNoticeCases[$modNoticeName] }
            Add-HarnessCase $modCases "answered: the pr-agent notice $modNoticeName needs no answer" $false (-not (& $modAnswered $modNotice @($modNotice)))
            $modOtherBot = & $modBot @{ Body = $modNoticeCases[$modNoticeName]; Author = 'someone[bot]' }
            Add-HarnessCase $modCases "answered: the words $modNoticeName from another bot are no notice" $true (-not (& $modAnswered $modOtherBot @($modOtherBot)))
            $modNoticeReview = & $modBot @{ Body = $modNoticeCases[$modNoticeName]; Source = 'review'; State = 'COMMENTED' }
            Add-HarnessCase $modCases "answered: the words $modNoticeName in a review body are no notice" $true (-not (& $modAnswered $modNoticeReview @($modNoticeReview)))
            $modNoticeLow = & $modBot @{ Body = "one`ntwo`nthree`nfour`nfive`n$($modNoticeCases[$modNoticeName])" }
            Add-HarnessCase $modCases "answered: the words $modNoticeName below other lines are no notice" $true (-not (& $modAnswered $modNoticeLow @($modNoticeLow)))
            $modNoticeAbove = & $modBot @{ Body = "$($modNoticeCases[$modNoticeName])`n- 【重要】a real finding" }
            Add-HarnessCase $modCases "answered: the words $modNoticeName above a list of findings are no notice" $true (-not (& $modAnswered $modNoticeAbove @($modNoticeAbove)))
        }
        $modMere = [ordered]@{ 'a link of that name in a sentence' = 'The [Persistent review] link was updated.'; 'the persistent notice without its links' = '**[Persistent review]** updated to latest commit abc1234'; 'the persistent notice without its first link' = '**[Persistent review]** updated to latest commit https://github.com/o/r/commit/abc1234'; 'the persistent notice whose commit is no link' = '**[Persistent review](https://github.com/o/r/pull/7)** updated to latest commit abc1234'; 'the persistent notice with another ending' = '**[Persistent review](https://github.com/o/r/pull/7)** updated to latest commit https://github.com/o/r/commit/abc1234 and more'; 'failed words with a reason that names things' = 'Failed to generate: a.ps1:1 is wrong'; 'failed words with a bracket' = 'Failed to generate 【重要】'; 'failed words in the middle of a line' = 'It says Failed to generate code suggestions for PR' }
        foreach ($modMereName in $modMere.get_Keys()) {
            $modMereItem = & $modBot @{ Body = $modMere[$modMereName] }
            Add-HarnessCase $modCases "answered: $modMereName is no notice" $true (-not (& $modAnswered $modMereItem @($modMereItem)))
        }
        $modBotEmpty = & $modBot @{ Source = 'review'; State = 'COMMENTED'; Body = '' }
        Add-HarnessCase $modCases 'answered: an empty review of a bot without inline comments needs no answer' $false (-not (& $modAnswered $modBotEmpty @($modBotEmpty)))
        $modBotBlank = & $modBot @{ Source = 'review'; State = 'COMMENTED'; Body = " `n " }
        Add-HarnessCase $modCases 'answered: a review of a bot of only blanks needs no answer' $false (-not (& $modAnswered $modBotBlank @($modBotBlank)))
        $modUserEmpty = & $modItem @{ Id = '52'; Source = 'review'; State = 'COMMENTED'; Body = '' }
        Add-HarnessCase $modCases 'answered: an empty review of a person without inline comments still needs an answer' $true (-not (& $modAnswered $modUserEmpty @($modUserEmpty)))
        $modBotText = & $modBot @{ Source = 'review'; State = 'COMMENTED'; Body = 'Please rename this.' }
        Add-HarnessCase $modCases 'answered: a review of a bot with a body nobody named' $true (-not (& $modAnswered $modBotText @($modBotText)))
        Add-HarnessCase $modCases 'answered: a review of a bot with a body named by a later agent comment' $false (-not (& $modAnswered $modBotText @($modBotText, $modBotReply)))
        $modBotChange = & $modBot @{ Source = 'review'; State = 'CHANGES_REQUESTED'; Body = '' }
        Add-HarnessCase $modCases 'answered: an empty change request of a bot is still a change request' $true (-not (& $modAnswered $modBotChange @($modBotChange)))
        $modBotInline = { param($resolved) & $modItem @{ Id = '53'; Source = 'review-comment'; Kind = 'bot'; ThreadId = 'T3'; Resolved = $resolved } }
        $modBotHolder = & $modBot @{ Source = 'review'; State = 'COMMENTED'; Body = ''; Comments = @('53') }
        Add-HarnessCase $modCases 'answered: an empty review of a bot is judged by its inline comments: an open thread' $true (-not (& $modAnswered $modBotHolder @($modBotHolder, (& $modBotInline $false))))
        Add-HarnessCase $modCases 'answered: an empty review of a bot is judged by its inline comments: a resolved thread' $false (-not (& $modAnswered $modBotHolder @($modBotHolder, (& $modBotInline $true))))

        # ---- the framework ---------------------------------------------------------------------
        $modErrWriter = [IO.StringWriter]::new()
        $modErrSaved = [Console]::Error
        [Console]::SetError($modErrWriter)
        try { Write-HarnessFailedCases @([pscustomobject]@{ Label = 'red one'; Bad = $true; Passed = $false }, [pscustomobject]@{ Label = 'green one'; Bad = $false; Passed = $true }) } finally { [Console]::SetError($modErrSaved) }
        Add-HarnessCase $modCases 'framework: the cases that are red are named, the green ones are not' $false ($modErrWriter.ToString() -notmatch 'self-test failed: red one' -or $modErrWriter.ToString() -match 'green one')

        # ---- check runs ----------------------------------------------------------------------
        $mod.Runs = [pscustomobject]@{ total_count = 1; workflow_runs = @([pscustomobject]@{ id = 5000000002 }) }
        $modRun = { param($id, $checkName, $conclusion) [pscustomobject]@{ id = $id; name = $checkName; status = 'completed'; conclusion = $conclusion; app = [pscustomobject]@{ slug = 'github-actions' }; details_url = "https://github.com/$(Get-HarnessRepo)/actions/runs/5000000002/job/$id" } }
        foreach ($modOrder in @(@(5, 9), @(9, 5))) {
            $mod.CheckRuns = [pscustomobject]@{ check_runs = @(($modOrder | ForEach-Object { & $modRun $_ 'harness-gate' $(if ($_ -eq 9) { 'success' } else { 'failure' }) }) + @(& $modRun 7 'branch-gate' 'success')) }
            $modLatest = Get-HarnessCheckRuns $modHead
            Add-HarnessCase $modCases "check runs: of two runs of one check the newer counts (listed $($modOrder -join ' then '))" $false (-not ((Get-HarnessProp $modLatest['harness-gate'] 'conclusion') -eq 'success' -and (Get-HarnessProp $modLatest['branch-gate'] 'id') -eq 7))
        }
        # a check run of GitHub Actions counts only when its run belongs to the pull_request event on this head: fixtures in the shape of the real responses
        $modPrRuns = Read-HarnessFixture 'pr-runs.json'
        $modActionsRun = { param($id, $conclusion, $runId) [pscustomobject]@{ id = $id; name = 'harness-gate'; status = 'completed'; conclusion = $conclusion; head_sha = $modHead; app = [pscustomobject]@{ slug = 'github-actions' }; details_url = "https://github.com/$(Get-HarnessRepo)/actions/runs/$runId/job/$($id + 1000)" } }
        $modGate = { param($runs) $mod.CheckRuns = [pscustomobject]@{ total_count = @($runs).Count; check_runs = @($runs) }; (Get-HarnessCheckRuns $modHead)['harness-gate'] }
        $mod.Runs = $modPrRuns
        $modDispatched = & $modGate @((& $modActionsRun 101 'failure' 5000000002), (& $modActionsRun 909 'success' 5000000777))
        Add-HarnessCase $modCases 'check runs: a failed PR run and a successful dispatch with a larger id: the PR run counts' $true ($modDispatched.conclusion -eq 'failure')
        $modDispatchOnly = & $modGate @(& $modActionsRun 909 'success' 5000000777)
        Add-HarnessCase $modCases 'check runs: only a dispatch on this head: no result at all' $true ($null -eq $modDispatchOnly)
        $modRerun = & $modGate @((& $modActionsRun 101 'failure' 5000000002), (& $modActionsRun 102 'success' 5000000003))
        Add-HarnessCase $modCases 'check runs: two runs of the pull_request event: the newer counts' $false ($modRerun.conclusion -ne 'success')
        # only GitHub Actions takes part: another app can name a check the same and point its link at a real PR run
        $modOtherApp = { param($link, $slug = 'some-other-app') [pscustomobject]@{ id = 909; name = 'harness-gate'; status = 'completed'; conclusion = 'success'; head_sha = $modHead; app = [pscustomobject]@{ slug = $slug }; details_url = $link } }
        Add-HarnessCase $modCases 'check runs: a successful check of another app does not cover a failed one' $true ((& $modGate @((& $modActionsRun 101 'failure' 5000000002), (& $modOtherApp 'https://example.invalid/report/909'))).conclusion -eq 'failure')
        Add-HarnessCase $modCases 'check runs: another app pointing its link at a real PR run does not cover a failed one' $true ((& $modGate @((& $modActionsRun 101 'failure' 5000000002), (& $modOtherApp "https://github.com/$(Get-HarnessRepo)/actions/runs/5000000002/job/5000000021"))).conclusion -eq 'failure')
        Add-HarnessCase $modCases 'check runs: another app alone: no result at all' $true ($null -eq (& $modGate @(& $modOtherApp "https://github.com/$(Get-HarnessRepo)/actions/runs/5000000002/job/5000000021")))
        Add-HarnessCase $modCases 'check runs: a check run without an app: no result at all' $true ($null -eq (& $modGate @([pscustomobject]@{ id = 909; name = 'harness-gate'; status = 'completed'; conclusion = 'success'; head_sha = $modHead; details_url = "https://github.com/$(Get-HarnessRepo)/actions/runs/5000000002/job/5000000021" })))
        Add-HarnessCase $modCases 'check runs: a check run of GitHub Actions that names no run: no result at all' $true ($null -eq (& $modGate @(& $modOtherApp 'https://example.invalid/report/909' 'github-actions')))
        $modLog.Clear()
        & $modGate @(& $modActionsRun 101 'success' 5000000002) | Out-Null
        Add-HarnessCase $modCases 'check runs: the runs are asked for this head and the pull_request event, every page' $false (@($modLog | Where-Object { $_ -match "^gh api --paginate --slurp repos/\S+/actions/runs\?head_sha=$modHead&event=pull_request&per_page=100$" }).Count -ne 1)
        $mod.Runs = @{ Code = 0; Out = '[{"workflow_runs":[{"id":1}]},{"workflow_runs":[{"id":5000000002}]}]'; Err = '' }
        Add-HarnessCase $modCases 'check runs: a run listed on the second page counts' $false ($null -eq (& $modGate @(& $modActionsRun 101 'success' 5000000002)))
        $mod.Runs = @{ Code = 1; Out = ''; Err = 'gh: Bad Gateway (HTTP 502)' }
        Add-HarnessCase $modCases 'check runs: the list of runs cannot be fetched: an error, never all runs or none' $true ((Get-ThrownMessage { & $modGate @(& $modActionsRun 101 'success' 5000000002) }) -match 'Bad Gateway')
        $mod.Runs = @{ total_count = 0; workflow_runs = @() }

        # ---- locks (named mutexes; a private scope while the observer is set) ----------------
        $modLockName = Get-HarnessLockName 'merge'
        Add-HarnessCase $modCases 'lock: only merge and git exist' $true ((Get-ThrownMessage { Get-HarnessLockName 'other' }) -match 'Unknown lock other')
        Add-HarnessCase $modCases 'lock: while the observer is set the name lives in a private scope' $false ($modLockName -notmatch 'selftest' -or $modLockName -notmatch '^Local\\')
        $modReady = [System.Threading.ManualResetEventSlim]::new($false)
        $modHolder = Start-ThreadJob -ArgumentList $modLockName, $modReady -ScriptBlock {
            param($heldName, $signal)
            $held = [System.Threading.Mutex]::new($false, $heldName)
            [void]$held.WaitOne()
            $signal.Set()
            Start-Sleep -Seconds 2
            $held.ReleaseMutex()
            $held.Dispose()
        }
        [void]$modReady.Wait(10000)
        $modRan = @{ Count = 0 }
        $modTimeout = Get-ThrownMessage { Invoke-WithHarnessLock -Name merge -ScriptBlock { $modRan.Count++ } -TimeoutSeconds 0.3 }
        Add-HarnessCase $modCases 'lock: one that is held elsewhere is an error after the timeout, and the block does not run' $true ($modTimeout -match 'Waited more than' -and $modRan.Count -eq 0)
        $null = Receive-Job -Job $modHolder -Wait -AutoRemoveJob
        $modAfter = Invoke-WithHarnessLock -Name merge -ScriptBlock { 'ran' } -TimeoutSeconds 5
        Add-HarnessCase $modCases 'lock: once the holder is gone the block runs' $false ($modAfter -ne 'ran')
        $modFree = {
            Receive-Job -Wait -AutoRemoveJob -Job (Start-ThreadJob -ArgumentList $modLockName -ScriptBlock {
                    param($probeName)
                    $probe = [System.Threading.Mutex]::new($false, $probeName)
                    $got = $probe.WaitOne(1500)
                    if ($got) { $probe.ReleaseMutex() }
                    $probe.Dispose()
                    $got
                })
        }
        Add-HarnessCase $modCases 'lock: released after the block' $false (-not (& $modFree))
        $null = Get-ThrownMessage { Invoke-WithHarnessLock -Name merge -ScriptBlock { throw 'inside the lock' } }
        Add-HarnessCase $modCases 'lock: released after a block that threw' $false (-not (& $modFree))
        # a real process holds the lock and is killed (this child only). With no other handle on the mutex the kernel drops it; with the handle of a waiter open the next one gets it as abandoned
        # The child waits a bounded time: when this process still holds the lock (a lock that is not released) it says so, and the case turns red instead of the self-test hanging for ever
        foreach ($modWaiterOpen in @($false, $true)) {
            $modChildStart = [System.Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
            foreach ($modChildArg in @('-NoProfile', '-NonInteractive', '-Command', "`$held = [System.Threading.Mutex]::new(`$false, '$modLockName'); if (`$held.WaitOne(15000)) { [Console]::Out.WriteLine('held'); [Console]::Out.Flush(); Start-Sleep -Seconds 120 } else { [Console]::Out.WriteLine('not held'); [Console]::Out.Flush() }")) { $modChildStart.ArgumentList.Add($modChildArg) }
            $modChildStart.RedirectStandardOutput = $true
            $modChildStart.UseShellExecute = $false
            $modChild = [System.Diagnostics.Process]::Start($modChildStart)
            $modWaiter = $null
            try {
                $modChildSaid = $modChild.StandardOutput.ReadLine()
                if ($modWaiterOpen) { $modWaiter = [System.Threading.Mutex]::new($false, $modLockName) }
                $modChild.Kill()
                $modChild.WaitForExit()
                $modTaken = & $modTry { Invoke-WithHarnessLock -Name merge -ScriptBlock { 'ran' } -TimeoutSeconds 10 }
            } finally {
                if ($modWaiter) { $modWaiter.Dispose() }
                if (-not $modChild.HasExited) { $modChild.Kill() }
                $modChild.Dispose()
            }
            $modHow = if ($modWaiterOpen) { 'another handle stays open, the lock comes back as abandoned' } else { 'no other handle' }
            Add-HarnessCase $modCases "lock: a holder that was killed ($modHow): the lock is taken over and the block runs" $false ($modChildSaid -ne 'held' -or $modTaken -ne 'ran')
            Add-HarnessCase $modCases "lock: released after a takeover ($modHow)" $false (-not (& $modFree))
        }

        # ---- the personal needles handed to the tools ----------------------------------------
        Set-HarnessNeedles -Mode ci-optional -NeedleFile 'other-needles.txt'
        $modNeedleArgs = (Get-HarnessNeedleArgs) -join ' '
        Set-HarnessNeedles -Mode ci
        $modNeedleArgsPlain = (Get-HarnessNeedleArgs) -join ' '
        Set-HarnessNeedles -Mode local -NeedleFile $modNeedleFile
        Add-HarnessCase $modCases 'needles: the mode and the needle file are handed on to the tools' $false ($modNeedleArgs -ne '--needles ci-optional --needles-file other-needles.txt')
        Add-HarnessCase $modCases 'needles: without a needle file only the mode is handed on' $false ($modNeedleArgsPlain -ne '--needles ci')

        # ---- the memo of real answers (self-test only) ---------------------------------------
        # two directories with the same two scripts that print a random number: the same answer twice means the memo answered
        $modNodeExe = Get-HarnessNode
        $modMemoRoots = @(Join-Path $modTmp 'memo-a'; Join-Path $modTmp 'memo-b')
        foreach ($modMemoRoot in $modMemoRoots) {
            New-Item -ItemType Directory -Force -Path (Join-Path $modMemoRoot 'scripts') | Out-Null
            foreach ($modMemoName in @('p', 'q')) { [IO.File]::WriteAllText((Join-Path $modMemoRoot "scripts/$modMemoName.mjs"), "console.log('$modMemoName ' + Math.random());`n", [Text.UTF8Encoding]::new($false)) }
        }
        $modMemoAsk = { param($scriptName, $key) (Invoke-HarnessNodeScript "scripts/$scriptName.mjs" @() -MemoKey $key).Out }
        $modNodeEnvMemo = $env:HARNESS_NODE
        try {
            $env:HARNESS_NODE = $modNodeExe
            Set-HarnessFake (New-HarnessFake -Routes ([ordered]@{}) -Log $modLog)
            Set-HarnessRepoRoot $modMemoRoots[0]
            $modMemoFirst = & $modMemoAsk 'p' 'k'
            Add-HarnessCase $modCases 'memo: with a fake set, the real answer to the same question is remembered' $false ((& $modMemoAsk 'p' 'k') -ne $modMemoFirst)
            Add-HarnessCase $modCases 'memo: another key is another question' $true ((& $modMemoAsk 'p' 'k2') -ne $modMemoFirst)
            Add-HarnessCase $modCases 'memo: a key that differs only by letter case is another question' $true ((& $modMemoAsk 'p' 'K') -ne $modMemoFirst)
            Add-HarnessCase $modCases 'memo: another script with the same key is another question' $true ((& $modMemoAsk 'q' 'k') -ne $modMemoFirst)
            Set-HarnessRepoRoot $modMemoRoots[1]
            Add-HarnessCase $modCases 'memo: another checkout with the same script and key is another question' $true ((& $modMemoAsk 'p' 'k') -ne $modMemoFirst)
            Set-HarnessRepoRoot $modMemoRoots[0]
            Set-HarnessNeedles -Mode local -NeedleFile $modNeedleFile
            Add-HarnessCase $modCases 'memo: new needles forget the remembered answers' $true ((& $modMemoAsk 'p' 'k') -ne $modMemoFirst)
            Set-HarnessFake $null
            Add-HarnessCase $modCases 'memo: without a fake nothing is remembered' $true ((& $modMemoAsk 'p' 'k') -ne (& $modMemoAsk 'p' 'k'))
        } finally {
            $env:HARNESS_NODE = $modNodeEnvMemo
            Set-HarnessRepoRoot $modRoot
            Set-HarnessFake (New-HarnessFake -Routes $modRoutes -Log $modLog)
        }

        # ---- the Node of the repository scripts ----------------------------------------------
        # an empty directory is the repository root here: the pin is exactly the .node-version this test writes into it
        $mod.Node = @{ Version = 'v22.4.1'; Config = $null; Crashes = $false }
        $modNodeRoutes = [ordered]@{
            '^node --version$'            = {
                if ($mod.Node.Crashes) { return @{ Code = 1; Out = $mod.Node.Version; Err = 'node crashed' } }
                if ($mod.Node.Version) { $mod.Node.Version } else { @{ Code = 127; Out = ''; Err = 'node: not found' } }
            }
            'config --get harness\.node$' = { if ($mod.Node.Config) { $mod.Node.Config } else { @{ Code = 1; Out = ''; Err = '' } } }
        }
        $modNodeLog = [System.Collections.Generic.List[string]]::new()
        $modNodeDir = Join-Path $modTmp 'node-pin'
        New-Item -ItemType Directory -Force -Path $modNodeDir | Out-Null
        $modNodeEnv = $env:HARNESS_NODE
        $modNodeGet = { try { Get-HarnessNode } catch { "threw: $($_.Exception.Message)" } }
        try {
            Set-HarnessFake (New-HarnessFake -Routes $modNodeRoutes -Log $modNodeLog)
            Set-HarnessRepoRoot $modNodeDir
            $env:HARNESS_NODE = 'configured-by-environment'
            Add-HarnessCase $modCases 'node: HARNESS_NODE is used as it is, without asking any node' $false ((& $modNodeGet) -ne 'configured-by-environment' -or @($modNodeLog | Where-Object { $_ -match '--version' }).Count -gt 0)
            $env:HARNESS_NODE = $null
            $mod.Node.Config = 'configured-by-git-config'
            Add-HarnessCase $modCases 'node: git config harness.node is used when the variable is not set' $false ((& $modNodeGet) -ne 'configured-by-git-config')
            $mod.Node.Config = $null
            $modNodeWith = { param($version) $mod.Node.Version = $version; Get-ThrownMessage { Get-HarnessNode } }
            Add-HarnessCase $modCases 'node: without .node-version the pin is unknown, which is an error even when the PATH node would do' $true ((& $modNodeWith 'v22.4.1') -match '^\.node-version is missing in this checkout')
            Set-Content -LiteralPath (Join-Path $modNodeDir '.node-version') -Value "22.4.1`n"
            Add-HarnessCase $modCases 'node: a PATH node of the pinned major version is used' $false ((& $modNodeGet) -ne 'node')
            Add-HarnessCase $modCases 'node: a newer PATH node is refused, never used silently' $true ((& $modNodeWith 'v25.1.0') -match '^The node on PATH is v25\.1\.0, the pinned major version is 22: set HARNESS_NODE')
            Add-HarnessCase $modCases 'node: an older PATH node is refused' $true ((& $modNodeWith 'v20.9.0') -match 'pinned major version is 22')
            Add-HarnessCase $modCases 'node: a major version that only starts like the pinned one is refused' $true ((& $modNodeWith 'v220.1.0') -match 'pinned major version is 22')
            Add-HarnessCase $modCases 'node: a major version that is only a prefix of the pinned one is refused' $true ((& $modNodeWith 'v2.1.0') -match 'pinned major version is 22')
            Add-HarnessCase $modCases 'node: a PATH node that answers something else is refused' $true ((& $modNodeWith 'not a version') -match 'does not answer --version')
            Add-HarnessCase $modCases 'node: no node on PATH is refused' $true ((& $modNodeWith $null) -match 'does not answer --version')
            $mod.Node.Crashes = $true
            Add-HarnessCase $modCases 'node: a PATH node that exits with an error is refused even when it printed a good version' $true ((& $modNodeWith 'v22.4.1') -match 'does not answer --version')
            $mod.Node.Crashes = $false
            Set-Content -LiteralPath (Join-Path $modNodeDir '.node-version') -Value "20.11.0`n"
            Add-HarnessCase $modCases 'node: the pin is the major version of .node-version' $true ((& $modNodeWith 'v22.4.1') -match 'pinned major version is 20')
            Add-HarnessCase $modCases 'node: a PATH node of the major version in .node-version is used' $false ($null -ne (& $modNodeWith 'v20.9.0'))
            Set-Content -LiteralPath (Join-Path $modNodeDir '.node-version') -Value "v20`n"
            Add-HarnessCase $modCases 'node: .node-version may be written as v20' $false ($null -ne (& $modNodeWith 'v20.9.0'))
            Set-Content -LiteralPath (Join-Path $modNodeDir '.node-version') -Value "lts/iron`n"
            Add-HarnessCase $modCases 'node: a .node-version that holds no version is an error' $true ((& $modNodeWith 'v22.4.1') -match '^\.node-version does not hold a Node version: lts/iron$')
        } finally {
            $env:HARNESS_NODE = $modNodeEnv
            Set-HarnessRepoRoot $modRoot
            Set-HarnessFake (New-HarnessFake -Routes $modRoutes -Log $modLog)
        }
    } catch {
        # a crash does not hide what already turned red by name
        Write-HarnessFailedCases $modCases
        throw
    } finally {
        Set-HarnessFake $null
        Set-HarnessLockImpl $null
        Set-HarnessRepoRoot $modRoot
        Set-HarnessNeedles
        Clear-HarnessPermCache
        Remove-Item -LiteralPath $modTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    , $modCases
}

$work = @($Scripts | Where-Object { -not $Only.Count -or $Only -contains $_ })
$pwshExe = [Environment]::ProcessPath
$results = [System.Collections.Generic.List[object]]::new()
foreach ($wrapper in $work) {
    $results.Add((Invoke-Child -Name $wrapper -Exe $pwshExe -Arguments @('-NoProfile', '-File', (Join-Path $PSScriptRoot "$wrapper.ps1"), '-SelfTest')))
}
if (-not $Only.Count -or $Only -contains 'maint') {
    $results.Add((Invoke-Child -Name 'maint.mjs' -Exe (Get-HarnessNode) -Arguments @((Join-Path $PSScriptRoot 'lib/maint.mjs'), '--self-test')))
}

$cases = Test-HygieneRules
foreach ($moduleCase in (Test-ModuleRules)) { $cases.Add($moduleCase) }
$files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.mjs' })
foreach ($file in $files) {
    $relative = $file.FullName.Substring($PSScriptRoot.Length).TrimStart('\', '/') -replace '\\', '/'
    $text = Get-Content -Raw -LiteralPath $file.FullName
    if ($file.Extension -eq '.mjs') {
        $header = @(($text -split "`r?`n") | Select-Object -First 3 | Where-Object { $_ -match 'SPDX-License-Identifier: MIT' }).Count -gt 0
        $found = (-not $header) -or ($text -match '(?i)\b[a-z]:[\\/](?:users|home|dev|claude|work)')
        Add-HarnessCase $cases "hygiene: $relative" $false $found
    } else {
        $problems = @(Get-HarnessSourceProblems -Text $text -Name $relative)
        foreach ($p in $problems) { [Console]::Error.WriteLine($p) }
        Add-HarnessCase $cases "hygiene: $relative" $false ($problems.Count -gt 0)
    }
}
$hygieneCode = Complete-HarnessSelfTest $cases 'shared rules (source hygiene and the module)'

$failed = @($results | Where-Object { $_.Code -ne 0 })
foreach ($r in $results) {
    Write-Output ("{0,-14} rc={1} {2,6}s  {3}" -f $r.Name, $r.Code, $r.Seconds, ($r.Lines | Select-Object -Last 1))
    if ($r.Code -ne 0) { foreach ($line in $r.Lines) { Write-Output "    $line" } }
}
if ($failed.Count -or $hygieneCode -ne 0) { Write-Output 'self-test: FAIL'; exit 1 }
Write-Output 'self-test: PASS'
exit 0

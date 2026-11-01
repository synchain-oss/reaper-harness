#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
#
# Run every self-test of the maintainer wrappers, offline: the -SelfTest of each script (in a child pwsh, so one failing
# script cannot hide another), the Node helper's own self-test, the criteria of the shared module that no single script
# owns, and the source-hygiene rules over every file of this directory together with the rules' own good and bad
# samples. Exit code 0 only when everything passed.
#   pwsh scripts/maintainer/self-test.ps1 [-Only push,pr-merge]    (-Only none: just the shared rules)
# Node comes from HARNESS_NODE / git config harness.node (the pinned Node 22), otherwise the one on PATH.

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
  External commands are faked; node (lib/maint.mjs) runs for real.
#>
function Test-ModuleRules {
    $modCases = New-HarnessCases
    $modTmp = Join-Path ([IO.Path]::GetTempPath()) "harness-module-selftest-$PID"
    New-Item -ItemType Directory -Force -Path $modTmp | Out-Null
    $modLog = [System.Collections.Generic.List[string]]::new()
    $modRoot = Get-HarnessRepoRoot
    $modSign = Get-HarnessSignoff
    $modHead = 'a' * 40
    $mod = @{ Privacy = @{ Code = 0; Out = ''; Err = '' }; GraphQl = $null; CheckRuns = $null; Edit = { param($edits) } }
    $modRoutes = [ordered]@{
        'check-privacy\.mjs --text'        = { $mod.Privacy }
        '^gh api boom$'                    = { @{ Code = 2; Out = ''; Err = "boom`nsecond line" } }
        'collaborators/DLsnows/permission' = { 'admin' }
        'collaborators/[^/]+/permission'   = { @{ Code = 0; Out = 'read'; Err = '' } }
        'commits/\S+/check-runs'           = { $mod.CheckRuns }
        'pulls/7/comments'                 = { Read-HarnessFixture 'review-comments.json' }
        'pulls/7/reviews'                  = { Read-HarnessFixture 'reviews.json' }
        'issues/7/comments'                = { Read-HarnessFixture 'issue-comments.json' }
        'api -X POST graphql'              = {
            param($argv)
            if ($mod.GraphQl) { return $mod.GraphQl }
            if ((Get-Content -Raw ($argv[-1]) | ConvertFrom-Json).query -match 'reviews\(') { $modEdits = Read-HarnessFixture 'review-edits.json'; & $mod.Edit $modEdits; return $modEdits }
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
        Add-HarnessCase $modCases 'external: a non-zero exit code is an error naming the command, the code and the first stderr line' $true ($modFailed -match '^gh api boom failed \(exit code 2\): boom$')
        Add-HarnessCase $modCases 'external: -AllowFail hands the answer back instead' $false ((Invoke-HarnessExternal gh @('api', 'boom') -AllowFail).Code -ne 2)
        Add-HarnessCase $modCases 'api read: a failing call is an error' $true ($null -ne (Get-ThrownMessage { Get-HarnessApi 'boom' }))
        Add-HarnessCase $modCases 'api read: -AllowFail turns a failing call into null' $false ($null -ne (Get-HarnessApi 'boom' -AllowFail))
        $mod.GraphQl = @{ errors = @(@{ message = 'bad query' }) }
        Add-HarnessCase $modCases 'graphql: errors in the answer are an error' $true ((Get-ThrownMessage { Invoke-HarnessGraphQL -Query 'query { x }' }) -match '^GraphQL error: bad query$')
        $mod.GraphQl = @{ data = @{ ok = $true }; errors = $null }
        Add-HarnessCase $modCases 'graphql: an answer without errors passes through' $false (-not (Invoke-HarnessGraphQL -Query 'query { x }').data.ok)
        $mod.GraphQl = $null
        Add-HarnessCase $modCases 'PowerShell 7.4 and older are refused (-DateKind)' $true ((-not (Test-HarnessPwshVersion 7 4)) -and (-not (Test-HarnessPwshVersion 6 9)))
        Add-HarnessCase $modCases 'PowerShell 7.5 and newer are accepted' $false (-not ((Test-HarnessPwshVersion 7 5) -and (Test-HarnessPwshVersion 7 6) -and (Test-HarnessPwshVersion 8 0)))

        # ---- the privacy tool and lib/maint.mjs ----------------------------------------------
        $modEmpty = Join-Path $modTmp 'empty'
        New-Item -ItemType Directory -Force -Path $modEmpty | Out-Null
        Set-HarnessFake $null
        Set-HarnessRepoRoot $modEmpty
        $modMissing = Get-ThrownMessage { Test-PublicText 'plain text' }
        Set-HarnessRepoRoot $modRoot
        Set-HarnessFake (New-HarnessFake -Routes $modRoutes -Log $modLog)
        Add-HarnessCase $modCases 'privacy tool: a checkout without scripts/check-privacy.mjs is an error, never a pass' $true ($modMissing -match 'check-privacy\.mjs is missing in this checkout')
        $modMaintBad = Get-ThrownMessage { Invoke-HarnessMaint -Command 'review-state' -Content 'not json' }
        Add-HarnessCase $modCases 'maint.mjs: an error answer is an error' $true ($modMaintBad -match '^maint\.mjs review-state: ')
        $modMaintOk = Invoke-HarnessMaint -Command 'review-state' -Content '[]'
        Add-HarnessCase $modCases 'maint.mjs: a real answer is parsed' $false ($modMaintOk.rounds -ne 0 -or $null -ne $modMaintOk.summary)
        $modAi = 'Co-Authored' + '-By: a <a@b.c>'
        $modSession = 'Cla' + 'ude-Session: https://example.invalid/s'
        $mod.Privacy = @{ Code = 1; Out = '[stand-in] finding'; Err = '' }
        $modPub = Test-PublicText 'plain text'
        Add-HarnessCase $modCases 'public text: a finding of the privacy tool is a finding' $true ((-not $modPub.Ok) -and ($modPub.Findings -join ';') -match 'privacy check failed \(exit 1\).*stand-in')
        $mod.Privacy = @{ Code = 2; Out = ''; Err = 'Cannot find module' }
        $modCrash = Test-PublicText 'plain text'
        Add-HarnessCase $modCases 'public text: a crashed privacy tool is a finding, not a pass' $true ((-not $modCrash.Ok) -and ($modCrash.Findings -join ';') -match 'Cannot find module')
        $mod.Privacy = @{ Code = 0; Out = ''; Err = '' }
        Add-HarnessCase $modCases 'public text: a clean text passes' $false (-not (Test-PublicText 'plain text').Ok)
        Add-HarnessCase $modCases 'public text: an AI attribution trailer is a finding even when the privacy tool is clean' $true (-not (Test-PublicText "text`n$modAi").Ok)
        Add-HarnessCase $modCases 'public text: Assert-PublicText stops with the label' $true ((Get-ThrownMessage { Assert-PublicText "text`n$modAi" 'my label' }) -match '^my label failed the public-text check, not sent')

        # ---- commit messages and PR texts ----------------------------------------------------
        $modOk = "feat(example): add it`n`nBody text.`n`n$modSign"
        $modErr = { param($text, $merge = $false, $exactly = $false) (@(Get-MessageErrors $text -Merge:$merge -ExactlyOne:$exactly)) -join ' | ' }
        Add-HarnessCase $modCases 'message: a clean message has no problem' $false ((& $modErr $modOk) -ne '')
        Add-HarnessCase $modCases 'message: an AI attribution trailer' $true ((& $modErr "$modOk`n$modAi") -match 'AI attribution trailer')
        Add-HarnessCase $modCases 'message: an AI session trailer' $true ((& $modErr "$modOk`n$modSession") -match 'AI attribution trailer')
        Add-HarnessCase $modCases 'message: an AI trailer in other letter case' $true ((& $modErr "$modOk`n$($modAi.ToUpperInvariant())") -match 'AI attribution trailer')
        Add-HarnessCase $modCases 'message: the sign-off of the maintainer in other letter case' $true ((& $modErr "feat(example): add it`n`nSigned-off-by: dlsnows <noreply@synchain.ca>") -match 'every Signed-off-by line')
        Add-HarnessCase $modCases 'message: the sign-off key in lower case' $true ((& $modErr "feat(example): add it`n`nsigned-off-by: DLsnows <noreply@synchain.ca>") -match 'every Signed-off-by line')
        Add-HarnessCase $modCases 'message: no sign-off' $true ((& $modErr "feat(example): add it`n`nBody.") -match 'Signed-off-by is missing')
        Add-HarnessCase $modCases 'message: a foreign trailer in a paragraph that is a quarter trailers and holds the sign-off' $true ((& $modErr "feat(example): add it`n`nBody.`n`nReviewed-by: Someone`nprose`nmore prose`nand more`n$modSign") -match 'only Signed-off-by is allowed')
        Add-HarnessCase $modCases 'message: a colon line in a prose paragraph is no trailer block' $false ((& $modErr "feat(example): add it`n`n$modSign`n`nNote: x`nprose`nprose`nprose`nprose") -match 'only Signed-off-by')
        Add-HarnessCase $modCases 'message: the type in upper case' $true ((& $modErr "Feat(example): add it`n`n$modSign") -match 'subject must be')
        Add-HarnessCase $modCases 'message: a subject without a scope' $true ((& $modErr "feat: add it`n`n$modSign") -match 'subject must be')
        Add-HarnessCase $modCases 'message: the default subject of git revert' $false ((& $modErr "Revert `"feat(example): add it`"`n`n$modSign") -ne '')
        Add-HarnessCase $modCases 'message: a merge commit needs neither subject nor sign-off' $false ((& $modErr "Merge branch 'feature/v1' into feat/example" $true) -ne '')
        Add-HarnessCase $modCases 'message: two sign-offs where exactly one is required' $true ((& $modErr "$modOk`n$modSign" $false $true) -match 'exactly one Signed-off-by')
        Add-HarnessCase $modCases 'message: two sign-offs where several are allowed' $false ((& $modErr "$modOk`n$modSign") -ne '')
        $modPrErr = { param($title, $body) (@(Get-PrTextErrors -Title $title -Body $body)) -join ' | ' }
        Add-HarnessCase $modCases 'PR text: a clean title and body' $false ((& $modPrErr 'feat(example): add it' "Body.`n`n$modSign") -ne '')
        Add-HarnessCase $modCases 'PR text: the type of the title in upper case' $true ((& $modPrErr 'Feat(example): add it' "Body.`n`n$modSign") -match 'PR title must be')
        Add-HarnessCase $modCases 'PR text: the sign-off on the last line in lower case' $true ((& $modPrErr 'feat(example): add it' "Body.`n`nsigned-off-by: DLsnows <noreply@synchain.ca>") -match 'last line of the PR body')

        # ---- agent markers and the permission lookup -----------------------------------------
        $modMarker = { param($extra) Get-ThrownMessage { New-AgentMarker -Role impl -Kind note -Round 1 -Head $modHead -Extra $extra } }
        foreach ($modField in @([ordered]@{ 'bad key' = 'x' }, [ordered]@{ Bot = 'x' }, [ordered]@{ 'bot-run' = 'a b' }, [ordered]@{ 'bot-run' = 'a>b' }, [ordered]@{ 'bot-run' = '' })) {
            Add-HarnessCase $modCases "marker: the invalid field '$(@($modField.Keys)[0])=$(@($modField.Values)[0])'" $true ((& $modMarker $modField) -match 'Invalid marker field')
        }
        Add-HarnessCase $modCases 'marker: two valid fields' $false ((New-AgentMarker -Role review -Kind disposition -Round 2 -Head $modHead -Extra ([ordered]@{ 'bot-run' = '77'; 'in-reply-to' = '1,2' })) -ne '<!-- harness-agent v1 role=review kind=disposition round=2 head=aaaaaaa bot-run=77 in-reply-to=1,2 -->')
        Add-HarnessCase $modCases 'marker: a kind in upper case is refused' $true ((Get-ThrownMessage { New-AgentMarker -Role impl -Kind 'Note' -Round 1 -Head $modHead }) -match 'Kind')
        Add-HarnessCase $modCases 'marker: a head in upper case is refused' $true ((Get-ThrownMessage { New-AgentMarker -Role impl -Kind note -Round 1 -Head ('A' * 40) }) -match 'Head')
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

        # ---- check runs ----------------------------------------------------------------------
        $modRun = { param($id, $checkName, $conclusion) [pscustomobject]@{ id = $id; name = $checkName; status = 'completed'; conclusion = $conclusion; details_url = 'u' } }
        foreach ($modOrder in @(@(5, 9), @(9, 5))) {
            $mod.CheckRuns = [pscustomobject]@{ check_runs = @(($modOrder | ForEach-Object { & $modRun $_ 'harness-gate' $(if ($_ -eq 9) { 'success' } else { 'failure' }) }) + @(& $modRun 7 'branch-gate' 'success')) }
            $modLatest = Get-HarnessCheckRuns $modHead
            Add-HarnessCase $modCases "check runs: of two runs of one check the newer counts (listed $($modOrder -join ' then '))" $false (-not ($modLatest['harness-gate'].conclusion -eq 'success' -and $modLatest['branch-gate'].id -eq 7))
        }

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

        # ---- the Node of the repository scripts ----------------------------------------------
        # an empty directory is the repository root here, so a .node-version of the real checkout cannot change the pin
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
            Add-HarnessCase $modCases 'node: a PATH node of the pinned major version is used (22 without .node-version)' $false ((& $modNodeGet) -ne 'node')
            $modNodeWith = { param($version) $mod.Node.Version = $version; Get-ThrownMessage { Get-HarnessNode } }
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
            Add-HarnessCase $modCases 'node: the pin of .node-version replaces the built-in one' $true ((& $modNodeWith 'v22.4.1') -match 'pinned major version is 20')
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
    } finally {
        Set-HarnessFake $null
        Set-HarnessLockImpl $null
        Set-HarnessRepoRoot $modRoot
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

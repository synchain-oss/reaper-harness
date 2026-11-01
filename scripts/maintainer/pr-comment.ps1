#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
#
# Read and write the comments of a PR. Writing: our comments, thread replies and the review disposition go out only through
# here; every one passes the public-text gate and gets the hidden agent marker on its first line.
#   -List -Pr <n> [-Since <ISO>] [-Json]
#        the four sources (issue comments, review comments, reviews, GraphQL review threads) as one table: author class
#        (agent / bot-summary / bot / pr-agent / user / external, by repository permission), new by updated_at, answered or
#        not; plus every finding listed inside the bot summaries (also those without a thread) and the pr-agent output
#   -Footer -Pr <n> [-Head <sha40>]
#        footer of the newest bot summary; missing, more than one line, counts that do not match the body, or a summary of
#        another head -> "bot verdict unusable", exit 2
#   -Wait -Pr <n> -Head <sha40> [-TimeoutMin 9]
#        wait until the required checks and claude-pr-review have finished on that head (and pr-agent-claude when the head
#        already has that check). One call waits at most 9 minutes: exit 0 done, exit 3 still running, exit 4 the head moved
#   -Post -Pr <n> -BodyFile <f> -Role <impl|review|orchestrator> -Kind <kind> -Round <n> -Head <sha> [-BotRun <id>] [-InReplyTo <id,...>]
#        an issue comment; -Kind disposition (the review disposition) needs -BotRun; -InReplyTo names the comments it
#        answers (written into the marker's in-reply-to, which pr-merge reads and nothing else)
#   -Reply -Pr <n> -To <comment id> -BodyFile <f> -Role -Round -Head
#        answer: a review comment is answered inside its thread; an issue comment or a review gets a new comment that
#        links the original; the marker names it in in-reply-to
#   -Resolve -Pr <n> -Thread <thread id> -BodyFile <f> -Role -Round -Head
#        check that the thread belongs to this PR, reply in the thread (in-reply-to = its first comment), then resolve it
#   -SelfTest
#
# The review disposition (-Kind disposition) carries a markdown table that pr-merge.ps1 reads, so its vocabulary is fixed (Chinese,
# as in the contributing guide of the repository). Header row: 级别 | 位置 | 摘要 | 处置. A column is found by the name its header
# cell starts with, never by position, so extra columns (#, source, basis, commit or reason / issue) and a note after the name
# ("处置（采纳 / 不改 / 挂账）") are fine. 级别 is 【红旗】 / 【重要】 / 【建议】. Decision words in 处置: 已修 修复 采纳 (a fix needs a
# commit hash in that column or right of it) and 不改 不采纳 挂账 暂不 维持 (a red-flag or important finding judged so needs the
# user's waiver before the merge). Write the table in these words: an English table is not recognised as a deferral.

[CmdletBinding()]
param(
    [switch]$List, [switch]$Footer, [switch]$Wait, [switch]$Post, [switch]$Reply, [switch]$Resolve, [switch]$SelfTest,
    [int]$Pr, [string]$Head, [string]$Since, [switch]$Json, [int]$TimeoutMin = 9,
    [string]$BodyFile, [string]$Role, [string]$Kind, [int]$Round = -1, [string]$BotRun,
    [string]$To, [string]$Thread, [string[]]$InReplyTo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/HarnessGh.psm1') -Force

$PollSeconds = 20

# ---- read -----------------------------------------------------------------------------------

function Get-ListReport {
    param([int]$Number, [string]$SinceTime)
    $activity = Get-HarnessPrActivity $Number
    $state = Get-HarnessReviewState $activity
    $items = @(Get-HarnessCommentItems -Activity $activity -State $state -Since $SinceTime)
    $rows = foreach ($i in $items) {
        [pscustomobject]@{
            Source = $i.Source; Id = $i.Id; Author = $i.Author; Kind = $i.Kind; Updated = $i.Updated; IsNew = $i.IsNew
            Responded = Test-HarnessResponded -Item $i -Items $items -State $state; Thread = $i.ThreadId; Resolved = $i.Resolved
            Url = $i.Url; Body = $i.Body
        }
    }
    $findings = foreach ($s in @($state.summaries)) {
        foreach ($f in @($s.items)) { [pscustomobject]@{ Summary = [string]$s.id; Run = $s.runId; Head = $s.head; Level = $f.level; Text = $f.text } }
    }
    # pr-agent output is listed next to the bot findings, each marked answered or not
    $prAgent = foreach ($r in @($rows | Where-Object Kind -eq 'pr-agent')) {
        [pscustomobject]@{ Id = $r.Id; Author = $r.Author; Updated = $r.Updated; Responded = $r.Responded; Url = $r.Url }
    }
    [pscustomobject]@{
        Pr = $Number; Items = @($rows); BotFindings = @($findings); PrAgent = @($prAgent)
        OpenThreads = @($activity.Threads | Where-Object { -not $_.isResolved }).Count
        External = @($rows | Where-Object Kind -eq 'external').Count
        Unanswered = @($rows | Where-Object { -not $_.Responded }).Count
    }
}

<# Footer of the newest bot summary. Usable: @{ Ok = $true; Red; Important; Suggest; Run; Head }, else @{ Ok = $false; Reason }. #>
function Get-FooterResult {
    param([int]$Number, [string]$HeadSha)
    $activity = Get-HarnessPrActivity $Number
    $s = (Get-HarnessReviewState $activity).summary
    if (-not $s) { return @{ Ok = $false; Reason = 'no bot review summary yet' } }
    if ($HeadSha -and $s.head -ne $HeadSha) { return @{ Ok = $false; Reason = "the newest summary reviewed $(([string]$s.head).Substring(0, [Math]::Min(7, ([string]$s.head).Length)))), not $($HeadSha.Substring(0, 7))" } }
    if (-not $s.ok) { return @{ Ok = $false; Reason = $s.reason } }
    @{ Ok = $true; Red = $s.red; Important = $s.important; Suggest = $s.suggest; Run = $s.runId; Head = $s.head }
}

function Get-WaitState {
    param([int]$Number, [string]$HeadSha)
    $pull = Get-HarnessApi "repos/$(Get-HarnessRepo)/pulls/$Number"
    if ($pull.head.sha -ne $HeadSha) { return [pscustomobject]@{ State = 'moved'; Head = $pull.head.sha; Checks = @() } }
    $runs = Get-HarnessCheckRuns $HeadSha
    $want = @(Get-HarnessRequiredChecks) + @(Get-HarnessBotCheck)
    # pr-agent-claude is not required: wait for it only when this head already has that check; any completed conclusion will do
    $prAgentCheck = Get-HarnessPrAgentCheck
    if ($runs.ContainsKey($prAgentCheck)) { $want += $prAgentCheck }
    $checks = foreach ($n in $want) {
        $c = if ($runs.ContainsKey($n)) { $runs[$n] } else { $null }
        [pscustomobject]@{ Name = $n; Status = $(if ($c) { $c.status } else { 'missing' }); Conclusion = $(if ($c) { $c.conclusion } else { $null }) }
    }
    $allDone = @($checks | Where-Object Status -ne 'completed').Count -eq 0
    [pscustomobject]@{ State = $(if ($allDone) { 'done' } else { 'pending' }); Head = $HeadSha; Checks = @($checks) }
}

<# One call waits at most 9 minutes whatever -TimeoutMin says: a longer wait would outlive the caller's own time limit. #>
function Get-WaitDeadline {
    param([int]$Minutes)
    [datetime]::UtcNow.AddMinutes([Math]::Min([Math]::Max($Minutes, 0), 9))
}

function Wait-Until {
    param([scriptblock]$Probe, [scriptblock]$Finished, [int]$Minutes)
    $deadline = Get-WaitDeadline $Minutes
    while ($true) {
        $r = & $Probe
        if ((& $Finished $r) -or [datetime]::UtcNow -ge $deadline) { return $r }
        Start-Sleep -Seconds $PollSeconds
    }
}

# ---- write ----------------------------------------------------------------------------------

function Read-BodyText {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { throw '-BodyFile (UTF-8 text) is required' }
    $content = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    if (-not $content.Trim()) { throw 'The body is empty' }
    $content
}

function Assert-WriteArgs {
    param([string]$AgentRole, [int]$AgentRound, [string]$HeadSha)
    if (-not $AgentRole -or $AgentRound -lt 0 -or $HeadSha -notmatch '^[0-9a-f]{7,40}$') { throw 'Writing a comment needs -Role, -Round and -Head (the head in the marker is the current head)' }
}

<#
  Which comments ours answers is written in the marker's in-reply-to (comma-separated comment ids); pr-merge reads only
  that, never numbers that merely occur in the text.
#>
function Get-ReplyExtra {
    param([string[]]$ReplyTo, [System.Collections.Specialized.OrderedDictionary]$Seed)
    $ids = @($ReplyTo | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($id in $ids) { if ($id -notmatch '^\d+$') { throw "-InReplyTo takes numeric comment ids: $id" } }
    if (-not $Seed) { $Seed = [ordered]@{} }
    if ($ids.Count) { $Seed['in-reply-to'] = $ids -join ',' }
    if ($Seed.Count) { $Seed } else { $null }
}

function Invoke-Post {
    param([int]$Number, [string]$Text, [string]$AgentRole, [string]$CommentKind, [int]$AgentRound, [string]$HeadSha, [string]$Run, [string[]]$ReplyTo)
    $fields = [ordered]@{}
    if ($CommentKind -eq 'disposition') {
        if ($Run -notmatch '^\d+$') { throw 'A disposition must reference the bot run of this round with -BotRun' }
        $fields['bot-run'] = $Run
    }
    $fields = Get-ReplyExtra -ReplyTo $ReplyTo -Seed $fields
    $full = Format-AgentText -Text $Text -Role $AgentRole -Kind $CommentKind -Round $AgentRound -Head $HeadSha -Extra $fields
    $r = Invoke-HarnessApiWrite -Method POST -Path "repos/$(Get-HarnessRepo)/issues/$Number/comments" -Body @{ body = $full }
    Write-Output "Posted $($r.html_url)"
}

function Invoke-Reply {
    param([int]$Number, [string]$Target, [string]$Text, [string]$AgentRole, [int]$AgentRound, [string]$HeadSha)
    if ($Target -notmatch '^\d+$') { throw '-To is the numeric id of a comment' }
    $slug = Get-HarnessRepo
    $fields = Get-ReplyExtra -ReplyTo @($Target)
    $rc = Get-HarnessApi "repos/$slug/pulls/comments/$Target" -AllowFail
    if ($rc) {
        if ([string]$rc.pull_request_url -notmatch "/pulls/$Number$") { throw "Review comment $Target is not on #$Number" }
        $full = Format-AgentText -Text $Text -Role $AgentRole -Kind 'reply' -Round $AgentRound -Head $HeadSha -Extra $fields
        $r = Invoke-HarnessApiWrite -Method POST -Path "repos/$slug/pulls/$Number/comments/$Target/replies" -Body @{ body = $full }
        return "Replied in the thread $($r.html_url)"
    }
    $ic = Get-HarnessApi "repos/$slug/issues/comments/$Target" -AllowFail
    $url = if ($ic) {
        if ([string]$ic.html_url -notmatch "/(pull|issues)/$Number#") { throw "Comment $Target is not on #$Number" }
        $ic.html_url
    } else {
        $all = Get-HarnessApi "repos/$slug/pulls/$Number/reviews?per_page=100" -Paginate
        $rv = $all | Where-Object { [string]$_.id -eq $Target } | Select-Object -First 1
        if (-not $rv) { throw "No comment $Target found on #$Number" }
        $rv.html_url
    }
    $full = Format-AgentText -Text "> Reply to $url`n`n$Text" -Role $AgentRole -Kind 'reply' -Round $AgentRound -Head $HeadSha -Extra $fields
    $r = Invoke-HarnessApiWrite -Method POST -Path "repos/$slug/issues/$Number/comments" -Body @{ body = $full }
    "Replied $($r.html_url)"
}

$ThreadQuery = 'query($thread: ID!) { node(id: $thread) { ... on PullRequestReviewThread { id pullRequest { number repository { nameWithOwner } } comments(first: 1) { nodes { databaseId } } } } }'
$ReplyMutation = 'mutation($thread: ID!, $body: String!) { addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $thread, body: $body }) { comment { url } } }'
$ResolveMutation = 'mutation($thread: ID!) { resolveReviewThread(input: { threadId: $thread }) { thread { id isResolved } } }'

function Invoke-Resolve {
    param([int]$Number, [string]$ThreadId, [string]$Text, [string]$AgentRole, [int]$AgentRound, [string]$HeadSha)
    if ($ThreadId -notmatch '^[A-Za-z0-9_=-]+$') { throw '-Thread is the node id of a review thread' }
    # the thread must belong to this PR: a mistyped id must not reply in or close a thread of another PR
    $node = (Invoke-HarnessGraphQL -Query $ThreadQuery -Variables @{ thread = $ThreadId }).data.node
    $prNumber = Get-HarnessProp (Get-HarnessProp $node 'pullRequest') 'number'
    $slug = Get-HarnessProp (Get-HarnessProp (Get-HarnessProp $node 'pullRequest') 'repository') 'nameWithOwner'
    if ($null -eq $prNumber -or [int]$prNumber -ne $Number -or $slug -ne (Get-HarnessRepo)) { throw "Thread $ThreadId is not on #$Number" }
    $firstId = @($node.comments.nodes)[0].databaseId
    $full = Format-AgentText -Text $Text -Role $AgentRole -Kind 'reply' -Round $AgentRound -Head $HeadSha -Extra (Get-ReplyExtra -ReplyTo @([string]$firstId))
    $r = Invoke-HarnessGraphQL -Query $ReplyMutation -Variables @{ thread = $ThreadId; body = $full }
    $closed = Invoke-HarnessGraphQL -Query $ResolveMutation -Variables @{ thread = $ThreadId }
    if (-not $closed.data.resolveReviewThread.thread.isResolved) { throw "Thread $ThreadId was not resolved" }
    "Replied and resolved the thread $($r.data.addPullRequestReviewThreadReply.comment.url)"
}

# ---- self-test ------------------------------------------------------------------------------

function Invoke-SelfTest {
    $cases = New-HarnessCases
    $savedToken = $env:GH_TOKEN
    try {
        # identity: GH_TOKEN of the maintainer account in this process, login verified, never gh auth switch / login
        $id = @{ Token = 'tok-selftest'; Login = 'DLsnows' }
        $idLog = [System.Collections.Generic.List[string]]::new()
        Set-HarnessFake (New-HarnessFake -Log $idLog -Routes ([ordered]@{
                    '^gh auth token --user DLsnows$' = { @{ Code = $(if ($id.Token) { 0 } else { 1 }); Out = $id.Token; Err = '' } }
                    '^gh api user --jq \.login$'     = { $id.Login }
                }))
        Initialize-HarnessIdentity
        Add-HarnessCase $cases 'identity: GH_TOKEN comes from the maintainer account and the login is verified' $false ($env:GH_TOKEN -ne 'tok-selftest')
        $id.Login = 'someone-else'
        Add-HarnessCase $cases 'identity: the token resolves to another account' $true (Test-Throws { Initialize-HarnessIdentity })
        $id.Token = ''
        Add-HarnessCase $cases 'identity: no token for the maintainer account' $true (Test-Throws { Initialize-HarnessIdentity })
        Add-HarnessCase $cases 'identity: never gh auth switch / login' $false (@($idLog | Where-Object { $_ -match '^gh auth (switch|login)' }).Count -gt 0)
        Add-HarnessCase $cases 'marker: format and head cut to 7 characters' $false ((New-AgentMarker -Role orchestrator -Kind reply -Round 3 -Head ('f' * 40)) -ne '<!-- harness-agent v1 role=orchestrator kind=reply round=3 head=fffffff -->')
        Add-HarnessCase $cases 'marker: invalid kind' $true (Test-Throws { New-AgentMarker -Role review -Kind 'Bad Kind' -Round 1 -Head ('f' * 40) })
        Add-HarnessCase $cases 'marker: parse round trip with extras' $false (-not (
                (Get-AgentMarker '<!-- harness-agent v1 role=impl kind=disposition round=2 head=abcdef0 bot-run=77 in-reply-to=1,2 -->').Extra['bot-run'] -eq '77' -and
                @((Get-AgentMarker '<!-- harness-agent v1 role=impl kind=reply round=2 head=abcdef0 in-reply-to=1,2 -->').InReplyTo).Count -eq 2))
        Add-HarnessCase $cases 'marker: not on the first line is no marker' $true ($null -eq (Get-AgentMarker "text`n<!-- harness-agent v1 role=impl kind=reply round=2 head=abcdef0 -->"))
        Clear-HarnessPermCache
        $issue = Read-HarnessFixture 'issue-comments.json'
        $pull = Read-HarnessFixture 'pull.json'
        $sha = $pull.head.sha
        $posted = [System.Collections.Generic.List[object]]::new()
        $log = [System.Collections.Generic.List[string]]::new()
        $checks = Read-HarnessFixture 'check-runs.json'
        $threadMode = @{ Unresolved = $false }
        $routes = [ordered]@{
            'check-privacy\.mjs --text'          = Get-HarnessPrivacyStandIn
            'collaborators/DLsnows/permission'   = { 'admin' }
            'collaborators/ghost/permission'     = { @{ Code = 1; Out = ''; Err = 'gh: Not Found (HTTP 404)' } }
            'collaborators/flaky/permission'     = { @{ Code = 1; Out = ''; Err = 'gh: Bad Gateway (HTTP 502)' } }
            'collaborators/[^/]+/permission'     = { @{ Code = 0; Out = 'read'; Err = '' } }
            'pulls/comments/8000000001'          = { $c = (Read-HarnessFixture 'review-comments.json')[0]; $c | Add-Member -NotePropertyName pull_request_url -NotePropertyValue 'https://api.github.com/repos/synchain-oss/reaper-harness/pulls/7'; $c }
            'pulls/comments/\d+$'                = { @{ Code = 1; Out = ''; Err = 'Not Found' } }
            'issues/comments/9000000001'         = { $issue[0] }
            'issues/comments/9000000009'         = { @{ id = 9000000009; html_url = 'https://github.com/synchain-oss/reaper-harness/pull/5#issuecomment-9000000009' } }
            'api -X POST \S+/(comments|replies) --input' = { param($argv) $posted.Add((Get-Content -Raw ($argv[-1]) | ConvertFrom-Json)); @{ html_url = 'https://github.com/x/y/pull/7#c' } }
            'pulls/7/comments'                   = { Read-HarnessFixture 'review-comments.json' }
            'pulls/7/reviews'                    = { Read-HarnessFixture 'reviews.json' }
            'pulls/7$'                           = { $pull }
            'issues/7/comments'                  = { $issue }
            'api -X POST graphql'                = {
                param($argv)
                $q = (Get-Content -Raw ($argv[-1]) | ConvertFrom-Json)
                $posted.Add($q)
                if ($q.query -match 'resolveReviewThread') { return @{ data = @{ resolveReviewThread = @{ thread = @{ id = 'T'; isResolved = ($q.variables.thread -ne 'PRRT_stubborn') } } } } }
                if ($q.query -match 'addPullRequestReviewThreadReply') { return @{ data = @{ addPullRequestReviewThreadReply = @{ comment = @{ url = 'u' } } } } }
                if ($q.query -match 'node\(id') {
                    $num = if ($q.variables.thread -eq 'PRRT_other') { 5 } else { 7 }
                    $owner = if ($q.variables.thread -eq 'PRRT_foreign') { 'someone/else' } else { 'synchain-oss/reaper-harness' }
                    return @{ data = @{ node = @{ id = $q.variables.thread; pullRequest = @{ number = $num; repository = @{ nameWithOwner = $owner } }; comments = @{ nodes = @(@{ databaseId = 8000000001 }) } } } }
                }
                if ($q.query -match 'reviews\(') { return Read-HarnessFixture 'review-edits.json' }
                $threadPage = Read-HarnessFixture 'threads.json'
                if ($threadMode.Unresolved) { $threadPage.data.repository.pullRequest.reviewThreads.nodes[0].isResolved = $false }
                $threadPage
            }
            'check-runs'                         = { $checks }
        }
        Set-HarnessFake (New-HarnessFake -Routes $routes -Log $log)
        Add-HarnessCase $cases 'permission: the maintainer has write access' $false (-not (Test-RepoWriter 'DLsnows'))
        Add-HarnessCase $cases 'permission: a read-only account does not' $true (-not (Test-RepoWriter 'someone'))
        Add-HarnessCase $cases 'permission: unknown account (404) does not' $true (-not (Test-RepoWriter 'ghost'))
        Add-HarnessCase $cases 'permission: an API failure is not silently "no permission"' $true (Test-Throws { Test-RepoWriter 'flaky' })

        $rep = Get-ListReport 7 '2026-11-01T10:10:00Z'
        Add-HarnessCase $cases '-List: all four sources are in the table' $false (-not ((@($rep.Items | Where-Object Source -eq 'issue').Count -eq 2) -and (@($rep.Items | Where-Object Source -eq 'review-comment').Count -eq 2) -and (@($rep.Items | Where-Object Source -eq 'review').Count -eq 2)))
        Add-HarnessCase $cases '-List: marked comments of the maintainer are agents (by permission, not association)' $false (@($rep.Items | Where-Object { $_.Author -eq 'DLsnows' -and $_.Kind -ne 'agent' }).Count -gt 0)
        Add-HarnessCase $cases '-List: new is decided by updated_at' $false (-not (@($rep.Items | Where-Object IsNew).Count -gt 0 -and @($rep.Items | Where-Object { -not $_.IsNew }).Count -gt 0))
        Add-HarnessCase $cases '-List: findings inside the bot summary are listed' $false (@($rep.BotFindings).Count -ne 1)
        Add-HarnessCase $cases '-List: everything answered, every thread resolved' $false ($rep.Unanswered -ne 0 -or $rep.OpenThreads -ne 0)

        $f = Get-FooterResult 7 $sha
        Add-HarnessCase $cases '-Footer: parses the footer' $false (-not ($f.Ok -and $f.Red -eq 0 -and $f.Important -eq 0 -and $f.Suggest -eq 1 -and $f.Run -eq '5000000001'))
        Add-HarnessCase $cases '-Footer: the summary reviewed another head' $true (-not (Get-FooterResult 7 ('a' * 40)).Ok)
        $summary = $issue[0]
        $orig = $summary.body
        $summary.body = "$orig`n<!-- harness-review v1 red=0 important=0 suggest=1 -->"
        Add-HarnessCase $cases '-Footer: footer on more than one line is unusable' $true (-not (Get-FooterResult 7 $sha).Ok)
        $summary.body = ($orig -split "`n" | Select-Object -SkipLast 1) -join "`n"
        Add-HarnessCase $cases '-Footer: footer missing is unusable' $true (-not (Get-FooterResult 7 $sha).Ok)
        $summary.body = $orig -replace 'suggest=1 -->$', 'suggest=5 -->'
        Add-HarnessCase $cases '-Footer: counts that do not match the body are unusable' $true (-not (Get-FooterResult 7 $sha).Ok)
        $summary.body = $orig -replace '(?s)^<!-- harness-review-head[^\n]*\n', ''
        Add-HarnessCase $cases '-Footer: summary without the head marker is no summary' $true (-not (Get-FooterResult 7 $sha).Ok)
        $summary.body = $orig

        $savedChecks = Copy-HarnessObject $checks
        $w = Get-WaitState 7 $sha
        Add-HarnessCase $cases '-Wait: all checks completed' $false ($w.State -ne 'done')
        Add-HarnessCase $cases '-Wait: the head moved' $true ((Get-WaitState 7 ('b' * 40)).State -eq 'moved')
        $checks.check_runs = @($checks.check_runs | Where-Object name -ne 'claude-pr-review')
        Add-HarnessCase $cases '-Wait: the bot check has not appeared yet' $true ((Get-WaitState 7 $sha).State -eq 'pending')
        $checks.check_runs = @($savedChecks.check_runs | ForEach-Object { Copy-HarnessObject $_ })
        $checks.check_runs[2].status = 'in_progress'
        Add-HarnessCase $cases '-Wait: the bot check is still running' $true ((Get-WaitState 7 $sha).State -eq 'pending')
        $checks.check_runs = @($savedChecks.check_runs | ForEach-Object { Copy-HarnessObject $_ })
        $checks.check_runs = @($checks.check_runs | Where-Object name -ne 'harness-gate')
        Add-HarnessCase $cases '-Wait: a required check is missing' $true ((Get-WaitState 7 $sha).State -eq 'pending')
        # pr-agent-claude is not required: awaited only when it is on this head; any completed conclusion is accepted
        $checks.check_runs = @($savedChecks.check_runs | ForEach-Object { Copy-HarnessObject $_ })
        $checks.check_runs += [pscustomobject]@{ id = 9; name = 'pr-agent-claude / pr-agent'; status = 'in_progress'; conclusion = $null; head_sha = $sha; details_url = 'u' }
        Add-HarnessCase $cases '-Wait: waits for a running pr-agent check' $true ((Get-WaitState 7 $sha).State -eq 'pending')
        $checks.check_runs[-1].status = 'completed'; $checks.check_runs[-1].conclusion = 'failure'
        Add-HarnessCase $cases '-Wait: a finished pr-agent check (failure too) is accepted' $false ((Get-WaitState 7 $sha).State -ne 'done')
        $checks.check_runs = @($savedChecks.check_runs | ForEach-Object { Copy-HarnessObject $_ })
        Add-HarnessCase $cases '-Wait: no pr-agent check on the head, none required' $false ((Get-WaitState 7 $sha).State -ne 'done')
        Add-HarnessCase $cases '-Wait: a head that is not 40 hex is refused by the command line' $true ('abc1234' -notmatch '^[0-9a-f]{40}$')
        $minutesAhead = { param($asked) ((Get-WaitDeadline $asked) - [datetime]::UtcNow).TotalMinutes }
        Add-HarnessCase $cases '-Wait: a one hour timeout is cut to nine minutes' $true ((& $minutesAhead 60) -le 9.01)
        Add-HarnessCase $cases '-Wait: a three minute timeout is kept' $false (-not ((& $minutesAhead 3) -gt 2.9 -and (& $minutesAhead 3) -le 3.01))
        Add-HarnessCase $cases '-Wait: a negative timeout does not wait' $true ((& $minutesAhead -5) -le 0.01)
        # a probe whose first answer is already final is asked once and returns without sleeping
        $probes = @{ Count = 0 }
        $ended = Wait-Until { $probes.Count++; 'now' } { param($s) $true } 9
        Add-HarnessCase $cases '-Wait: a finished probe returns at once' $false ($ended -ne 'now' -or $probes.Count -ne 1)

        # pr-agent output is its own class: markers and headings in the first 5 lines; notices are exempt; answered only by in-reply-to later than updated_at
        $prAgent = { param($id, $markdown, $updated = '2026-11-01T11:00:00Z') [pscustomobject]@{ id = [long]$id; user = @{ login = 'github-actions[bot]'; type = 'Bot' }; author_association = 'NONE'; created_at = '2026-11-01T11:00:00Z'; updated_at = $updated; body = $markdown; html_url = "https://github.com/x/y/pull/7#issuecomment-$id" } }
        $agentReply = { param($id, $answered, $created) [pscustomobject]@{ id = [long]$id; user = @{ login = 'DLsnows'; type = 'User' }; author_association = 'OWNER'; created_at = $created; updated_at = $created; body = "<!-- harness-agent v1 role=review kind=reply round=2 head=3f9c2e1 in-reply-to=$answered -->`nChecked."; html_url = 'u' } }
        $reviewText = "<!-- pr-agent:review:full -->`n## PR Reviewer Guide`n`n**Recommended focus areas**`n`n- Possible Issue: x"
        $issue += & $prAgent 7000000101 $reviewText
        $issue += & $prAgent 7000000102 $reviewText '2026-11-01T11:20:00Z'
        $issue += & $agentReply 7000000202 7000000102 '2026-11-01T11:10:00Z'
        $issue += & $prAgent 7000000103 $reviewText
        $issue += & $agentReply 7000000203 7000000103 '2026-11-01T11:10:00Z'
        $issue += & $prAgent 7000000104 "<!-- pr-agent:review:full -->`n**[Persistent review]** updated to latest commit abc1234"
        $issue += & $prAgent 7000000105 "Failed to generate PR review: timeout`n<!-- pr-agent:improve:summary -->"
        $issue += & $prAgent 7000000106 "one`ntwo`nthree`nfour`nfive`n<!-- pr-agent:review:full -->`n## PR Reviewer Guide"
        $issue += & $prAgent 7000000107 "[pr-agent:improve:summary]: https://example.invalid/pr-agent`n## PR Code Suggestions"
        $rep = Get-ListReport 7 '2026-11-01T10:50:00Z'
        $byId = { param($i) @($rep.Items | Where-Object { [string]$_.Id -eq "$i" })[0] }
        Add-HarnessCase $cases '-List: an unanswered pr-agent comment is marked unanswered' $false (-not ((& $byId 7000000101).Kind -eq 'pr-agent' -and -not (& $byId 7000000101).Responded))
        Add-HarnessCase $cases '-List: an answer naming the id but sent before updated_at does not count' $false (-not ((& $byId 7000000102).Kind -eq 'pr-agent' -and -not (& $byId 7000000102).Responded))
        Add-HarnessCase $cases '-List: an answer after updated_at counts' $false (-not ((& $byId 7000000103).Kind -eq 'pr-agent' -and (& $byId 7000000103).Responded))
        Add-HarnessCase $cases '-List: the two pr-agent notices stay exempt plain bot comments' $false (-not ((& $byId 7000000104).Kind -eq 'bot' -and (& $byId 7000000104).Responded -and (& $byId 7000000105).Kind -eq 'bot' -and (& $byId 7000000105).Responded))
        Add-HarnessCase $cases '-List: a marker below the first 5 lines (a quote) is not pr-agent' $false ((& $byId 7000000106).Kind -eq 'pr-agent')
        Add-HarnessCase $cases '-List: the link-reference form of the marker is recognised' $false ((& $byId 7000000107).Kind -ne 'pr-agent')
        Add-HarnessCase $cases '-List: pr-agent output is listed with the findings' $false (@($rep.PrAgent | Where-Object { [string]$_.Id -eq '7000000101' -and -not $_.Responded }).Count -ne 1)
        $unansweredIds = @($rep.Items | Where-Object { -not $_.Responded } | ForEach-Object { [string]$_.Id } | Sort-Object) -join ','
        Add-HarnessCase $cases '-List: the unanswered comments are counted (the three pr-agent outputs without a later answer)' $true ($unansweredIds -eq '7000000101,7000000102,7000000107' -and $rep.Unanswered -eq 3)
        Add-HarnessCase $cases '-List: every thread resolved, none counted as open' $false ($rep.OpenThreads -ne 0)
        $threadMode.Unresolved = $true
        $withOpen = Get-ListReport 7 ''
        $threadMode.Unresolved = $false
        Add-HarnessCase $cases '-List: an unresolved review thread is counted as open' $true ($withOpen.OpenThreads -eq 1)

        Invoke-Post -Number 7 -Text "## Disposition`nAll taken." -AgentRole review -CommentKind disposition -AgentRound 2 -HeadSha $sha -Run '5000000001' | Out-Null
        $b = $posted[-1].body
        Add-HarnessCase $cases '-Post: marker added on the first line (with bot-run)' $false (-not ($b -match '^<!-- harness-agent v1 role=review kind=disposition round=2 head=3f9c2e1 bot-run=5000000001 -->\n'))
        Add-HarnessCase $cases '-Post: a disposition without -BotRun' $true (Test-Throws { Invoke-Post -Number 7 -Text 'x' -AgentRole review -CommentKind disposition -AgentRound 2 -HeadSha $sha })
        Add-HarnessCase $cases '-Post: a disposition with a non-numeric -BotRun' $true (Test-Throws { Invoke-Post -Number 7 -Text 'x' -AgentRole review -CommentKind disposition -AgentRound 2 -HeadSha $sha -Run 'abc' })
        Add-HarnessCase $cases '-Post: a local path in the text' $true (Test-Throws { Invoke-Post -Number 7 -Text ('log in C:' + '\Users\someone\a.log') -AgentRole review -CommentKind note -AgentRound 1 -HeadSha $sha })
        Add-HarnessCase $cases '-Post: an AI attribution trailer in the text' $true (Test-Throws { Invoke-Post -Number 7 -Text "ok`nCo-Authored-By: a <a@b.c>" -AgentRole review -CommentKind note -AgentRound 1 -HeadSha $sha })
        Add-HarnessCase $cases '-Post: a card number in the text' $true (Test-Throws { Invoke-Post -Number 7 -Text ('see R' + 'H-02') -AgentRole review -CommentKind note -AgentRound 1 -HeadSha $sha })
        Add-HarnessCase $cases '-Post: a personal needle in the text' $true (Test-Throws { Invoke-Post -Number 7 -Text 'harness-selftest-fake-needle-7c1e' -AgentRole review -CommentKind note -AgentRound 1 -HeadSha $sha })
        Add-HarnessCase $cases '-Post: a body carrying its own marker' $true (Test-Throws { Invoke-Post -Number 7 -Text '<!-- harness-review v1 red=0 important=0 suggest=0 -->' -AgentRole review -CommentKind note -AgentRound 1 -HeadSha $sha })
        Add-HarnessCase $cases '-Post: an unknown role' $true (Test-Throws { Invoke-Post -Number 7 -Text 'x' -AgentRole user -CommentKind note -AgentRound 1 -HeadSha $sha })
        $n = $posted.Count
        Add-HarnessCase $cases '-Post: nothing was sent while the checks failed' $true ($posted.Count -eq $n)
        Invoke-Post -Number 7 -Text 'Both are handled.' -AgentRole review -CommentKind note -AgentRound 2 -HeadSha $sha -ReplyTo @('9000000001', '8000000002') | Out-Null
        Add-HarnessCase $cases '-Post: -InReplyTo is written into the marker' $false (-not ($posted[-1].body -match '^<!-- harness-agent v1 role=review kind=note round=2 head=3f9c2e1 in-reply-to=9000000001,8000000002 -->'))
        Add-HarnessCase $cases '-Post: -InReplyTo that is not an id' $true (Test-Throws { Invoke-Post -Number 7 -Text 'x' -AgentRole review -CommentKind note -AgentRound 2 -HeadSha $sha -ReplyTo @('abc') })

        # the body file and the marker arguments are checked before anything is sent
        $bodyDir = Join-Path ([IO.Path]::GetTempPath()) "harness-pr-comment-selftest-$PID"
        New-Item -ItemType Directory -Force -Path $bodyDir | Out-Null
        try {
            $blankFile = Join-Path $bodyDir 'blank.md'
            $textFile = Join-Path $bodyDir 'text.md'
            [IO.File]::WriteAllText($blankFile, "  `n`n  ", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($textFile, "Done.`n", [Text.UTF8Encoding]::new($false))
            Add-HarnessCase $cases 'body file: a file with text is read' $false ((Read-BodyText $textFile) -ne "Done.`n")
            Add-HarnessCase $cases 'body file: an empty body is refused as empty' $true ((Get-ThrownMessage { Read-BodyText $blankFile }) -match 'body is empty')
            Add-HarnessCase $cases 'body file: no file given' $true ((Get-ThrownMessage { Read-BodyText '' }) -match '-BodyFile')
            Add-HarnessCase $cases 'body file: a file that does not exist' $true ((Get-ThrownMessage { Read-BodyText (Join-Path $bodyDir 'nope.md') }) -match '-BodyFile')
        } finally {
            Remove-Item -LiteralPath $bodyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $writeArgs = { param($r, $n, $h) Get-ThrownMessage { Assert-WriteArgs $r $n $h } }
        Add-HarnessCase $cases 'marker arguments: role, round and head given' $false ($null -ne (& $writeArgs 'review' 2 $sha))
        Add-HarnessCase $cases 'marker arguments: round 0 is a round' $false ($null -ne (& $writeArgs 'impl' 0 $sha))
        Add-HarnessCase $cases 'marker arguments: no role' $true ((& $writeArgs '' 2 $sha) -match 'needs -Role, -Round and -Head')
        Add-HarnessCase $cases 'marker arguments: no round (the default is -1)' $true ((& $writeArgs 'review' -1 $sha) -match 'needs -Role, -Round and -Head')
        Add-HarnessCase $cases 'marker arguments: no head' $true ((& $writeArgs 'review' 2 '') -match 'needs -Role, -Round and -Head')
        Add-HarnessCase $cases 'marker arguments: a head that is not hex' $true ((& $writeArgs 'review' 2 'main') -match 'needs -Role, -Round and -Head')
        Add-HarnessCase $cases 'marker arguments: a head shorter than 7 characters' $true ((& $writeArgs 'review' 2 'abc123') -match 'needs -Role, -Round and -Head')

        $n = $posted.Count
        Invoke-Reply -Number 7 -Target '8000000001' -Text 'Fixed.' -AgentRole review -AgentRound 2 -HeadSha $sha | Out-Null
        Add-HarnessCase $cases '-Reply: a review comment is answered in its thread, the marker names it' $false (-not ($posted.Count -eq $n + 1 -and ($log[-1] -match 'pulls/7/comments/8000000001/replies') -and $posted[-1].body -match 'in-reply-to=8000000001 -->'))
        Add-HarnessCase $cases '-Reply: the comment is not on this PR' $true (Test-Throws { Invoke-Reply -Number 5 -Target '8000000001' -Text 'x' -AgentRole review -AgentRound 2 -HeadSha $sha })
        $n = $posted.Count
        $looked = $log.Count
        Add-HarnessCase $cases '-Reply: a target that is not a numeric id is refused before anything is looked up' $true ((Get-ThrownMessage { Invoke-Reply -Number 7 -Target 'abc' -Text 'x' -AgentRole review -AgentRound 2 -HeadSha $sha }) -match 'numeric id of a comment' -and $log.Count -eq $looked)
        Add-HarnessCase $cases '-Reply: an issue comment of another PR' $true ((Get-ThrownMessage { Invoke-Reply -Number 7 -Target '9000000009' -Text 'x' -AgentRole review -AgentRound 2 -HeadSha $sha }) -match 'Comment 9000000009 is not on #7' -and $posted.Count -eq $n)
        Add-HarnessCase $cases '-Reply: no comment or review with that id' $true ((Get-ThrownMessage { Invoke-Reply -Number 7 -Target '123456' -Text 'x' -AgentRole review -AgentRound 2 -HeadSha $sha }) -match 'No comment 123456 found on #7' -and $posted.Count -eq $n)
        Invoke-Reply -Number 7 -Target '7000000001' -Text 'Seen.' -AgentRole review -AgentRound 2 -HeadSha $sha | Out-Null
        Add-HarnessCase $cases '-Reply: a review gets a new comment that links it, the marker names it' $false (-not ($posted.Count -eq $n + 1 -and $posted[-1].body -match 'in-reply-to=7000000001 -->' -and $posted[-1].body.Contains('#pullrequestreview-7000000001')))
        Invoke-Reply -Number 7 -Target '9000000001' -Text 'Noted.' -AgentRole review -AgentRound 2 -HeadSha $sha | Out-Null
        Add-HarnessCase $cases '-Reply: an issue comment gets a new comment that links it, the marker names it' $false (-not ($posted[-1].body -match 'kind=reply round=2 head=3f9c2e1 in-reply-to=9000000001 -->' -and $posted[-1].body.Contains('#issuecomment-9000000001')))
        Invoke-Resolve -Number 7 -ThreadId 'PRRT_kwDOexample01' -Text 'Fixed.' -AgentRole review -AgentRound 2 -HeadSha $sha | Out-Null
        $mut = @($posted | Select-Object -Last 2)
        Add-HarnessCase $cases '-Resolve: checks the thread, replies first, then resolves' $false (-not ($mut[0].query -match 'addPullRequestReviewThreadReply' -and $mut[1].query -match 'resolveReviewThread' -and $mut[0].variables.body -match '^<!-- harness-agent v1 role=review kind=reply round=2 head=3f9c2e1 in-reply-to=8000000001 -->'))
        $n = $posted.Count
        Add-HarnessCase $cases '-Resolve: the thread is on another PR (only the lookup is sent)' $true ((Test-Throws { Invoke-Resolve -Number 7 -ThreadId 'PRRT_other' -Text 'a' -AgentRole review -AgentRound 2 -HeadSha $sha }) -and $posted.Count -eq $n + 1)
        Add-HarnessCase $cases '-Resolve: invalid thread id' $true (Test-Throws { Invoke-Resolve -Number 7 -ThreadId 'x y' -Text 'a' -AgentRole review -AgentRound 2 -HeadSha $sha })
        Add-HarnessCase $cases '-Resolve: a text with a local path is not sent' $true ((Test-Throws { Invoke-Resolve -Number 7 -ThreadId 'PRRT_kwDOexample01' -Text ('C:' + '\Users\someone') -AgentRole review -AgentRound 2 -HeadSha $sha }) -and -not @($posted | Select-Object -Skip ($n + 1) | Where-Object { $_.PSObject.Properties.Name -contains 'query' -and $_.query -match 'addPullRequestReviewThreadReply' }).Count)

        $n = $posted.Count
        $foreign = Get-ThrownMessage { Invoke-Resolve -Number 7 -ThreadId 'PRRT_foreign' -Text 'a' -AgentRole review -AgentRound 2 -HeadSha $sha }
        Add-HarnessCase $cases '-Resolve: a thread of another repository with the same PR number (only the lookup is sent)' $true ($foreign -match 'Thread PRRT_foreign is not on #7' -and $posted.Count -eq $n + 1)
        $stubborn = Get-ThrownMessage { Invoke-Resolve -Number 7 -ThreadId 'PRRT_stubborn' -Text 'a' -AgentRole review -AgentRound 2 -HeadSha $sha }
        Add-HarnessCase $cases '-Resolve: GitHub reports the thread still unresolved after the mutation' $true ($stubborn -match 'Thread PRRT_stubborn was not resolved')

        $mod = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'lib/HarnessGh.psm1')
        $selfText = Get-Content -Raw -LiteralPath $PSCommandPath
        Add-HarnessCase $cases 'source hygiene: pr-comment.ps1 and HarnessGh.psm1' $false ((@(Get-HarnessSourceProblems -Text $selfText -Name 'pr-comment.ps1').Count + @(Get-HarnessSourceProblems -Text $mod -Name 'HarnessGh.psm1').Count) -gt 0)
        # the checker itself must catch its bad examples
        $badSource = "# no header`n`$Head = 1`n`$head = 2`n`$p = 'C:' + '\Users\x'"
        Add-HarnessCase $cases 'source hygiene: case-only variable difference is caught' $true (@(Get-HarnessSourceProblems -Text $badSource -Name 'x').Count -ge 3)
        Add-HarnessCase $cases 'source hygiene: a header-less file without StrictMode is caught' $true (@(Get-HarnessSourceProblems -Text "Write-Output 1" -Name 'x') -match 'SPDX' -and @(Get-HarnessSourceProblems -Text "Write-Output 1" -Name 'x') -match 'StrictMode')
    } finally {
        Set-HarnessFake $null
        $env:GH_TOKEN = $savedToken
    }
    Complete-HarnessSelfTest $cases 'pr-comment'
}

# ---- entry ----------------------------------------------------------------------------------

if ($SelfTest) { exit (Invoke-SelfTest) }
$modes = @($List, $Footer, $Wait, $Post, $Reply, $Resolve | Where-Object { $_ })
if ($modes.Count -ne 1) { throw 'Usage: exactly one of -List | -Footer | -Wait | -Post | -Reply | -Resolve (see the header of this file)' }
if ($Pr -le 0) { throw '-Pr <n> is required' }
Initialize-HarnessIdentity

if ($List) {
    $rep = Get-ListReport $Pr $Since
    if ($Json) { Write-Output (ConvertTo-HarnessJsonText $rep); exit 0 }
    foreach ($i in $rep.Items) {
        $flag = @($(if ($i.IsNew) { 'new' }), $(if (-not $i.Responded) { 'unanswered' }), $(if ($i.Kind -eq 'external') { 'external' })) | Where-Object { $_ }
        Write-Output ('{0,-14} {1,-12} {2,-16} {3,-11} {4} {5}' -f $i.Source, $i.Id, $i.Author, $i.Kind, $i.Updated, ($flag -join ' '))
    }
    foreach ($f in $rep.BotFindings) { Write-Output "  bot finding (run $($f.Run)) [$($f.Level)] $($f.Text)" }
    foreach ($a in @($rep.PrAgent)) { Write-Output "  pr-agent comment $($a.Id) ($($a.Updated)) $(if ($a.Responded) { 'answered' } else { 'unanswered' }) $($a.Url)" }
    Write-Output "open threads $($rep.OpenThreads), unanswered $($rep.Unanswered), external $($rep.External)"
    exit 0
}
if ($Footer) {
    $f = Get-FooterResult $Pr $Head
    if (-not $f.Ok) { Write-Output "bot verdict unusable: $($f.Reason)"; exit 2 }
    Write-Output "red=$($f.Red) important=$($f.Important) suggest=$($f.Suggest) run=$($f.Run)"
    exit 0
}
if ($Wait) {
    if ($Head -notmatch '^[0-9a-f]{40}$') { throw '-Wait needs a 40-character -Head' }
    $r = Wait-Until { Get-WaitState $Pr $Head } { param($s) $s.State -ne 'pending' } $TimeoutMin
    Write-Output (ConvertTo-HarnessJsonText $r)
    exit $(switch ($r.State) { 'done' { 0 } 'moved' { 4 } default { 3 } })
}
$bodyText = Read-BodyText $BodyFile
Assert-WriteArgs $Role $Round $Head
if ($Post) {
    if (-not $Kind) { throw '-Post needs -Kind (for example disposition, note, reply)' }
    Invoke-Post -Number $Pr -Text $bodyText -AgentRole $Role -CommentKind $Kind -AgentRound $Round -HeadSha $Head -Run $BotRun -ReplyTo $InReplyTo
} elseif ($Reply) {
    Write-Output (Invoke-Reply -Number $Pr -Target $To -Text $bodyText -AgentRole $Role -AgentRound $Round -HeadSha $Head)
} else {
    Write-Output (Invoke-Resolve -Number $Pr -ThreadId $Thread -Text $bodyText -AgentRole $Role -AgentRound $Round -HeadSha $Head)
}

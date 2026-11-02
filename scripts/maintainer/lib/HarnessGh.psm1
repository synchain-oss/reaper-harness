# SPDX-License-Identifier: MIT
#
# Shared module of the maintainer wrappers (scripts/maintainer/*.ps1): identity, the single entry point for external
# commands, public-text gate, agent markers, "who has write access" lookup, the four comment sources, merge/git locks and
# the self-test framework.
# - GitHub writes go through these scripts only. The identity is fixed to the maintainer account: GH_TOKEN is taken
#   from `gh auth token --user <maintainer>` inside this process and verified with `gh api user`; the global gh account
#   is never switched.
# - Local settings come from environment variables or git config only; there is no local path in any script:
#   HARNESS_ROOT / harness.root (workspace root that holds wt/, used by new-worktree only), HARNESS_NODE / harness.node
#   (without either, the node on PATH is used only when its major version is the one in .node-version), HARNESS_GITLEAKS /
#   harness.gitleaks. The personal privacy needles are read by scripts/check-privacy.mjs itself.
# - The repository's rules are not rewritten here: public text goes through scripts/check-privacy.mjs, commit messages and
#   PR texts through scripts/check-commits.mjs, bot summaries through scripts/review-bot.mjs, the infrastructure list is
#   scripts/lib/infra-paths.mjs; lib/maint.mjs is the bridge to the last three.
# - gh, git and node all go through Invoke-HarnessExternal; -SelfTest swaps in a fake that reads fixtures
#   (Set-HarnessFake), so self-tests never touch the network or GitHub.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$script:RepoSlug = 'synchain-oss/reaper-harness'
$script:Maintainer = 'DLsnows'
$script:Signoff = 'Signed-off-by: DLsnows <noreply@synchain.ca>'
$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$script:Fake = $null
$script:LockImpl = $null
$script:LockScope = 'ReaperHarness'
$script:PermCache = @{}
$script:InfraModule = $null
$script:InfraAnswers = @{}
# the memo of real answers is case-sensitive: two texts that differ only by letter case are two questions
$script:RealAnswers = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
# checks that must be success on the head of a PR into feature/v1
$script:RequiredChecks = @('harness-gate', 'branch-gate')
$script:BotCheck = 'claude-pr-review'
$script:PrAgentCheck = 'pr-agent-claude / pr-agent'
$script:ReviewWorkflow = '.github/workflows/claude-review.yml'

# ConvertFrom-Json -DateKind (timestamps kept as strings) exists from PowerShell 7.5 on; older versions fail halfway
function Test-HarnessPwshVersion { param([int]$Major, [int]$Minor) $Major -gt 7 -or ($Major -eq 7 -and $Minor -ge 5) }
if (-not (Test-HarnessPwshVersion $PSVersionTable.PSVersion.Major $PSVersionTable.PSVersion.Minor)) {
    throw "The maintainer scripts need PowerShell 7.5 or later (ConvertFrom-Json -DateKind); this is $($PSVersionTable.PSVersion)"
}

function Get-HarnessRepo { $script:RepoSlug }
function Get-HarnessMaintainer { $script:Maintainer }
function Get-HarnessSignoff { $script:Signoff }
function Get-HarnessRepoRoot { $script:RepoRoot }
# self-test only: point the repo root at a temporary directory (PR template, privacy tool)
function Set-HarnessRepoRoot { param([string]$Path) $script:RepoRoot = if ($Path) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')) } }
function Get-HarnessReviewWorkflow { $script:ReviewWorkflow }
function Get-HarnessBotCheck { $script:BotCheck }
function Get-HarnessPrAgentCheck { $script:PrAgentCheck }
function Get-HarnessRequiredChecks { @($script:RequiredChecks) }

# ---- local settings -------------------------------------------------------------------------

function Get-HarnessSetting {
    param([Parameter(Mandatory)][string]$Env, [Parameter(Mandatory)][string]$GitKey)
    $v = [Environment]::GetEnvironmentVariable($Env)
    if ($v) { return $v }
    $r = Invoke-HarnessExternal git @('-C', $script:RepoRoot, 'config', '--get', $GitKey) -AllowFail
    if ($r.Code -eq 0 -and $r.Out.Trim()) { return $r.Out.Trim() }
    return $null
}

function Get-HarnessRoot {
    $root = Get-HarnessSetting -Env 'HARNESS_ROOT' -GitKey 'harness.root'
    if (-not $root) { throw 'Workspace root not configured: set HARNESS_ROOT or git config harness.root' }
    return [IO.Path]::GetFullPath($root)
}

# ---- external commands ----------------------------------------------------------------------

<#
  Run gh / git / node and return @{ Code; Out; Err }. In a self-test $script:Fake gets the first look (it receives the
  executable, the argument array and an options object); returning $null lets the real command run (node and local git
  config reads do). A non-zero exit code throws unless -AllowFail. A self-test asks the same question of the repository's own
  scripts again and again (the same PR text is scanned in every counter-example): with a -MemoKey the answer of the real
  command is remembered for the rest of the self-test; the fake still looks first, and a run outside a self-test never remembers.
#>
function Invoke-HarnessExternal {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @(), [string]$Cwd, [string]$MemoKey, [switch]$AllowFail)
    $r = $null
    if ($script:Fake) { $r = & $script:Fake $Exe $Arguments ([pscustomobject]@{ Cwd = $Cwd }) }
    $memo = [bool]($script:Fake -and $MemoKey)
    if ($null -eq $r -and $memo -and $script:RealAnswers.ContainsKey($MemoKey)) { $r = $script:RealAnswers[$MemoKey] }
    if ($null -eq $r) {
        $errFile = [IO.Path]::GetTempFileName()
        $pushed = $false
        try {
            if ($Cwd) { Push-Location -LiteralPath $Cwd; $pushed = $true }
            $out = & $Exe @Arguments 2> $errFile
            $code = $LASTEXITCODE
        } finally {
            if ($pushed) { Pop-Location }
        }
        $r = @{ Code = $code; Out = (@($out) -join "`n"); Err = [IO.File]::ReadAllText($errFile) }
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
        if ($memo) { $script:RealAnswers[$MemoKey] = $r }
    }
    if ($r.Code -ne 0 -and -not $AllowFail) {
        $first = (($r.Err -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
        throw "$Exe $(@($Arguments | Select-Object -First 2) -join ' ') failed (exit code $($r.Code)): $first"
    }
    return $r
}

function Invoke-HarnessGh {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFail)
    Invoke-HarnessExternal gh $Arguments -AllowFail:$AllowFail
}

function Invoke-HarnessGit {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$Repo = $script:RepoRoot, [switch]$AllowFail)
    Invoke-HarnessExternal git (@('-C', $Repo) + $Arguments) -AllowFail:$AllowFail
}

<# REST GET. -Paginate collects every page with --slurp and flattens it into one array; null when it fails with -AllowFail. #>
function Get-HarnessApi {
    param([Parameter(Mandatory)][string]$Path, [switch]$Paginate, [switch]$AllowFail)
    $argv = @('api') + $(if ($Paginate) { @('--paginate', '--slurp') } else { @() }) + @($Path)
    $r = Invoke-HarnessGh $argv -AllowFail:$AllowFail
    if ($r.Code -ne 0) { return $null }
    if ($Paginate) { return (ConvertFrom-Json -InputObject $r.Out -Depth 100 -DateKind String -NoEnumerate | ForEach-Object { $_ } | ForEach-Object { $_ }) }
    return ConvertFrom-Json -InputObject $r.Out -Depth 100 -DateKind String
}

<# API timestamps (ISO 8601, Z or offset) compared as UTC; JSON keeps them as strings (-DateKind String). #>
function ConvertTo-HarnessUtc {
    param([Parameter(Mandatory)][string]$Value)
    [datetimeoffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

<# Read a property that may not exist (StrictMode); works for objects and dictionaries. #>
function Get-HarnessProp {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $(if ($Object.Contains($Name)) { $Object[$Name] } else { $null }) }
    if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

<# Write: the request body goes through a temporary JSON file and --input, never through the command line. #>
function Invoke-HarnessApiWrite {
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Body)
    $file = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $Body -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        $r = Invoke-HarnessGh @('api', '-X', $Method, $Path, '--input', $file)
        if ($r.Out.Trim()) { return ConvertFrom-Json -InputObject $r.Out -Depth 100 -DateKind String }
        return $null
    } finally {
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    }
}

function Invoke-HarnessGraphQL {
    param([Parameter(Mandatory)][string]$Query, [hashtable]$Variables = @{})
    $data = Invoke-HarnessApiWrite -Method POST -Path 'graphql' -Body @{ query = $Query; variables = $Variables }
    if ($data.PSObject.Properties.Name -contains 'errors' -and $data.errors) {
        throw "GraphQL error: $(@($data.errors | ForEach-Object { $_.message }) -join '; ')"
    }
    return $data
}

#  The pinned major version of Node is the first number of .node-version in the checkout; the file is required.
function Get-HarnessNodeMajorPin {
    $pinFile = Join-Path $script:RepoRoot '.node-version'
    if (-not (Test-Path -LiteralPath $pinFile -PathType Leaf)) { throw ".node-version is missing in this checkout: the pinned Node version is unknown" }
    $pinText = (Get-Content -Raw -LiteralPath $pinFile).Trim()
    if ($pinText -match '^v?(\d+)(?:\.\d+){0,2}$') { return [int]$Matches[1] }
    throw ".node-version does not hold a Node version: $pinText"
}

<#
  The Node of the repository scripts: HARNESS_NODE / harness.node when set. Without either, the node on PATH is used only when
  its major version is the one of .node-version; another version (a newer global install) is an error, never a silent fallback.
#>
function Get-HarnessNode {
    $n = Get-HarnessSetting -Env 'HARNESS_NODE' -GitKey 'harness.node'
    if ($n) { return $n }
    $pin = Get-HarnessNodeMajorPin
    $found = ''
    try {
        $r = Invoke-HarnessExternal node @('--version') -AllowFail
        if ($r.Code -eq 0) { $found = $r.Out.Trim() }
    } catch { }
    if ($found -cnotmatch '^v(\d+)\.\d+\.\d+') { throw 'Node is not configured (HARNESS_NODE or git config harness.node) and the node on PATH does not answer --version' }
    $pathMajor = [int]([regex]::Match($found, '^v(\d+)').Groups[1].Value)
    if ($pathMajor -ne $pin) { throw "The node on PATH is $found, the pinned major version is ${pin}: set HARNESS_NODE or git config harness.node to the pinned Node" }
    return 'node'
}

<# A Node script of the repository (repo-relative path), run in the repo root so git config settings resolve per repository. #>
function Invoke-HarnessNodeScript {
    param([Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @(), [string]$MemoKey, [switch]$AllowFail)
    $scriptPath = Join-Path $script:RepoRoot $Script
    if (-not $script:Fake -and -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "$Script is missing in this checkout: the check it provides is unavailable, nothing is sent" }
    $memo = if ($MemoKey) { "$script:RepoRoot|$Script|$MemoKey" } else { '' }
    Invoke-HarnessExternal (Get-HarnessNode) (@($scriptPath) + $Arguments) -Cwd $script:RepoRoot -MemoKey $memo -AllowFail:$AllowFail
}

<# One subcommand of lib/maint.mjs; the input goes through a temporary file; returns the parsed JSON line. #>
function Invoke-HarnessMaint {
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][AllowEmptyString()][string]$Content, [string[]]$Extra = @())
    $file = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($file, $Content, [Text.UTF8Encoding]::new($false))
        $r = Invoke-HarnessNodeScript 'scripts/maintainer/lib/maint.mjs' (@($Command, '--file', $file) + $Extra) -MemoKey "$Command|$($Extra -join ' ')|$Content" -AllowFail
        $last = (($r.Out -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if (-not $last) { throw "maint.mjs $Command produced no output: $($r.Err.Trim())" }
        $v = ConvertFrom-Json -InputObject $last -Depth 100 -DateKind String
        if ($v.PSObject.Properties.Name -contains 'error') { throw "maint.mjs ${Command}: $($v.error)" }
        return $v
    } finally {
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    }
}

function ConvertTo-HarnessJsonText {
    param($Value)
    ConvertTo-Json -InputObject $Value -Depth 100 -Compress
}

# ---- identity -------------------------------------------------------------------------------

<# GH_TOKEN of the maintainer account inside this process, verified to resolve to the maintainer; the global gh account is not switched. #>
function Initialize-HarnessIdentity {
    $r = Invoke-HarnessGh @('auth', 'token', '--user', $script:Maintainer) -AllowFail
    $token = $r.Out.Trim()
    if ($r.Code -ne 0 -or -not $token) { throw "No gh credential for $($script:Maintainer) on this machine (run gh auth login for that account first)" }
    $env:GH_TOKEN = $token
    $actual = (Invoke-HarnessGh @('api', 'user', '--jq', '.login')).Out.Trim()
    if ($actual -ne $script:Maintainer) { throw "The gh credential resolves to $actual, not $($script:Maintainer)" }
}

# ---- text rules -----------------------------------------------------------------------------

# None of the rules below is written out here: commit messages, PR texts and AI attribution trailers are judged by
# scripts/check-commits.mjs (through lib/maint.mjs) and privacy by scripts/check-privacy.mjs. A missing tool, a crash and an
# answer that cannot be read are errors, never a pass.

$script:NeedlesMode = 'local'
$script:NeedlesFile = $null

<# Where the privacy tool and the message rules take the personal needles from: the mode, and for local a needle file (the self-tests use their own). #>
function Set-HarnessNeedles {
    param([ValidateSet('local', 'ci', 'ci-optional')][string]$Mode = 'local', [string]$NeedleFile)
    $script:NeedlesMode = $Mode
    $script:NeedlesFile = $NeedleFile
    $script:RealAnswers.Clear()
}

function Get-HarnessNeedleArgs {
    $needleArgs = @('--needles', $script:NeedlesMode)
    if ($script:NeedlesFile) { $needleArgs += @('--needles-file', $script:NeedlesFile) }
    $needleArgs
}

<# A commit or squash message under the same-repository rules of check-commits.mjs. Returns the problems (empty = fine). #>
function Get-MessageErrors {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [switch]$Merge, [switch]$ExactlyOne)
    $flags = @(Get-HarnessNeedleArgs)
    if ($Merge) { $flags += '--merge' }
    if ($ExactlyOne) { $flags += '--exactly-one' }
    @((Invoke-HarnessMaint -Command 'message' -Content $Message -Extra $flags).errors)
}

<# A PR title and body under checkPrText of check-commits.mjs (title format, sign-off on the last line, privacy rules). #>
function Get-PrTextErrors {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title, [Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    $json = ConvertTo-HarnessJsonText ([ordered]@{ title = $Title; body = $Body })
    @((Invoke-HarnessMaint -Command 'pr-text' -Content $json -Extra @(Get-HarnessNeedleArgs)).errors)
}

<# Public-text gate: AI attribution trailers (any author) plus scripts/check-privacy.mjs --text (exit 0 clean). A missing tool is an error, never a pass. #>
function Test-PublicText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($n in @((Invoke-HarnessMaint -Command 'text' -Content $Text).aiTrailerLines)) { $findings.Add("line $n [ai-trailer]") }
    $file = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($file, $Text, [Text.UTF8Encoding]::new($false))
        $needleArgs = @(Get-HarnessNeedleArgs)
        $r = Invoke-HarnessNodeScript 'scripts/check-privacy.mjs' (@('--text', $file) + $needleArgs) -MemoKey "$($needleArgs -join ' ')|$Text" -AllowFail
        if ($r.Code -ne 0) {
            $detail = @((($r.Out + "`n" + $r.Err) -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 5)
            $findings.Add("privacy check failed (exit $($r.Code)): $($detail -join ' | ')")
        }
    } finally {
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ Ok = ($findings.Count -eq 0); Findings = $findings.ToArray() }
}

function Assert-PublicText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Label = 'text')
    $t = Test-PublicText $Text
    if (-not $t.Ok) { throw "$Label failed the public-text check, not sent: $($t.Findings -join '; ')" }
}

# ---- agent markers --------------------------------------------------------------------------

$script:MarkerPattern = '^<!-- harness-agent v1 role=(impl|review|orchestrator) kind=([a-z][a-z-]*) round=(\d+) head=([0-9a-f]{7,40})((?: [a-z-]+=[^\s>]+)*) -->$'

<# <!-- harness-agent v1 role=<impl|review|orchestrator> kind=<...> round=<n> head=<sha7> [key=value ...] --> #>
function New-AgentMarker {
    param(
        [Parameter(Mandatory)][ValidateSet('impl', 'review', 'orchestrator')][string]$Role,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z-]*$', Options = 'None')][string]$Kind,
        [Parameter(Mandatory)][ValidateRange(0, 99)][int]$Round,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{7,40}$', Options = 'None')][string]$Head,
        [System.Collections.Specialized.OrderedDictionary]$Extra
    )
    $tail = ''
    if ($Extra) {
        foreach ($k in $Extra.Keys) {
            $val = [string]$Extra[$k]
            if ($k -cnotmatch '^[a-z][a-z-]*$' -or $val -notmatch '^[^\s>]+$') { throw "Invalid marker field: $k=$val" }
            $tail += " $k=$val"
        }
    }
    "<!-- harness-agent v1 role=$Role kind=$Kind round=$Round head=$($Head.Substring(0, 7))$tail -->"
}

function Get-AgentMarker {
    param([AllowEmptyString()][AllowNull()][string]$Body)
    $first = (($Body ?? '') -split "`r?`n", 2)[0]
    $m = [regex]::Match($first, $script:MarkerPattern)
    if (-not $m.Success) { return $null }
    $fields = @{}
    foreach ($kv in ($m.Groups[5].Value.Trim() -split '\s+' | Where-Object { $_ })) {
        $k, $v = $kv -split '=', 2
        $fields[$k] = $v
    }
    $replyTo = if ($fields.ContainsKey('in-reply-to')) { @($fields['in-reply-to'] -split ',' | Where-Object { $_ }) } else { @() }
    [pscustomobject]@{
        Role = $m.Groups[1].Value; Kind = $m.Groups[2].Value; Round = [int]$m.Groups[3].Value; Head = $m.Groups[4].Value
        Extra = $fields; InReplyTo = $replyTo
    }
}

<# Text an agent sends: marker on the first line, whole text through the public-text gate. A caller-written marker is refused so marker and identity cannot disagree. #>
function Format-AgentText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][int]$Round, [Parameter(Mandatory)][string]$Head,
        [System.Collections.Specialized.OrderedDictionary]$Extra, [string]$Label = 'comment'
    )
    if ($Text -match '<!--\s*harness-') { throw "A $Label must not contain a harness- hidden marker; the script adds it" }
    $marker = New-AgentMarker -Role $Role -Kind $Kind -Round $Round -Head $Head -Extra $Extra
    $full = "$marker`n$($Text.TrimEnd())"
    Assert-PublicText $full $Label
    return $full
}

# ---- who has write access -------------------------------------------------------------------

<#
  Write or admin permission on this repo (collaborators/<login>/permission; maintain is reported as write). Not
  author_association: it is NONE when org membership is private and the maintainer would look like an outsider. Cached per login.
#>
function Test-RepoWriter {
    param([Parameter(Mandatory)][string]$Login)
    if ($Login -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$') { return $false }
    if (-not $script:PermCache.ContainsKey($Login)) {
        $r = Invoke-HarnessGh @('api', "repos/$($script:RepoSlug)/collaborators/$Login/permission", '--jq', '.permission') -AllowFail
        # 404 means "no such collaborator"; rate limits, 5xx or a token without the right scope must not silently read as "no write access"
        if ($r.Code -ne 0 -and $r.Err -notmatch 'HTTP 404|Not Found') { throw "Could not check the permission of ${Login}: $(($r.Err -split "`n")[0])" }
        $script:PermCache[$Login] = ($r.Code -eq 0 -and @('admin', 'write') -contains $r.Out.Trim())
    }
    return $script:PermCache[$Login]
}

function Clear-HarnessPermCache { $script:PermCache = @{} }

# ---- infrastructure paths -------------------------------------------------------------------

<#
  The list and the matching rule live in scripts/lib/infra-paths.mjs only (called through maint.mjs infra). The review bot
  runs the PR's own review-bot.mjs, so a PR that weakens the review could judge itself clean; touching these paths
  therefore never self-merges. The merge command runs from a clone sitting on origin/feature/v1, so it reads the list
  from the target line, not from the PR. Set-HarnessInfraModule swaps the list module (self-test only).
#>
function Set-HarnessInfraModule { param([string]$Path) $script:InfraModule = $Path; $script:InfraAnswers = @{} }

<# files: [{ filename; status; previous_filename? }]. Every path involved counts, old and new name of a rename. #>
function Get-HarnessChangedPaths {
    param([object[]]$Files = @())
    @(foreach ($f in $Files) {
            $f.filename
            $prev = Get-HarnessProp $f 'previous_filename'
            if ($prev) { $prev }
        }) | Select-Object -Unique
}

function Get-InfraTouches {
    param([object[]]$Files = @())
    $paths = @(Get-HarnessChangedPaths $Files)
    if (-not $paths) { return }
    $moduleArgs = if ($script:InfraModule) { @('--module', $script:InfraModule) } else { @() }
    # one answer per path set in this process (a failed lookup is never remembered): a run asks about the same files repeatedly
    $json = ConvertTo-HarnessJsonText @($paths)
    if (-not $script:InfraAnswers.ContainsKey($json)) {
        $script:InfraAnswers[$json] = @((Invoke-HarnessMaint -Command 'infra' -Content $json -Extra $moduleArgs).hits)
    }
    @($script:InfraAnswers[$json])
}

# ---- comments on a PR: four sources ---------------------------------------------------------

$script:ThreadsQuery = @'
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line
          comments(first: 100) { nodes { databaseId author { login } body createdAt updatedAt url } }
        }
      }
    }
  }
}
'@

function Get-HarnessReviewThreads {
    param([Parameter(Mandatory)][int]$Pr)
    $owner, $repoName = $script:RepoSlug.Split('/')
    $nodes = [System.Collections.Generic.List[object]]::new()
    $after = $null
    do {
        $vars = @{ owner = $owner; name = $repoName; number = $Pr; after = $after }
        $page = (Invoke-HarnessGraphQL -Query $script:ThreadsQuery -Variables $vars).data.repository.pullRequest.reviewThreads
        foreach ($n in @($page.nodes)) { $nodes.Add($n) }
        $after = $page.pageInfo.endCursor
    } while ($page.pageInfo.hasNextPage)
    $nodes.ToArray()
}

$script:ReviewEditsQuery = @'
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviews(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { databaseId updatedAt lastEditedAt }
      }
    }
  }
}
'@

<# REST reviews have no updated_at: an edited review body is only visible through GraphQL lastEditedAt / updatedAt. Returns id -> the later of the two. #>
function Get-HarnessReviewEdits {
    param([Parameter(Mandatory)][int]$Pr)
    $owner, $repoName = $script:RepoSlug.Split('/')
    $edits = @{}
    $after = $null
    do {
        $vars = @{ owner = $owner; name = $repoName; number = $Pr; after = $after }
        $page = (Invoke-HarnessGraphQL -Query $script:ReviewEditsQuery -Variables $vars).data.repository.pullRequest.reviews
        foreach ($n in @($page.nodes)) {
            $times = @($n.updatedAt, (Get-HarnessProp $n 'lastEditedAt')) | Where-Object { $_ } | Sort-Object { ConvertTo-HarnessUtc $_ }
            $edits[[string]$n.databaseId] = [string]($times | Select-Object -Last 1)
        }
        $after = $page.pageInfo.endCursor
    } while ($page.pageInfo.hasNextPage)
    $edits
}

<#
  Issue comments, review comments, reviews and GraphQL review threads, all of them. Each review gets updated_at: the later
  of its submission and its GraphQL edit time (a review whose body changed after our reply needs a new reply).
#>
function Get-HarnessPrActivity {
    param([Parameter(Mandatory)][int]$Pr)
    $r = $script:RepoSlug
    $reviews = @(Get-HarnessApi "repos/$r/pulls/$Pr/reviews?per_page=100" -Paginate)
    $edits = Get-HarnessReviewEdits $Pr
    foreach ($rv in $reviews) {
        $id = [string]$rv.id
        if (-not $edits.ContainsKey($id)) { throw "GraphQL has no edit time for review $id, cannot tell whether it was edited" }
        $updated = @([string]$rv.submitted_at, $edits[$id]) | Where-Object { $_ } | Sort-Object { ConvertTo-HarnessUtc $_ } | Select-Object -Last 1
        $rv | Add-Member -NotePropertyName updated_at -NotePropertyValue $updated -Force
    }
    [pscustomobject]@{
        Issue   = @(Get-HarnessApi "repos/$r/issues/$Pr/comments?per_page=100" -Paginate)
        Review  = @(Get-HarnessApi "repos/$r/pulls/$Pr/comments?per_page=100" -Paginate)
        Reviews = $reviews
        Threads = @(Get-HarnessReviewThreads $Pr)
    }
}

<# Non-bot authors of comments that have write access to this repo (handed to maint.mjs review-state to recognise dispositions). #>
function Get-HarnessWriters {
    param([Parameter(Mandatory)]$Activity)
    $logins = @($Activity.Issue) + @($Activity.Review) + @($Activity.Reviews) |
        ForEach-Object { Get-HarnessProp (Get-HarnessProp $_ 'user') 'login' } |
        Where-Object { $_ -and $_ -notmatch '\[bot\]$' } | Select-Object -Unique
    $logins | Where-Object { Test-RepoWriter $_ }
}

<# Newest bot summary, all summaries (footer, run id, items) and the dispositions; the criteria live in maint.mjs. #>
function Get-HarnessReviewState {
    param([Parameter(Mandatory)]$Activity, [string]$Bot = 'claude')
    $writers = Get-HarnessWriters $Activity
    $json = ConvertTo-HarnessJsonText @($Activity.Issue)
    Invoke-HarnessMaint -Command 'review-state' -Content $json -Extra @('--writers', ($writers -join ','), '--bot', $Bot)
}

<#
  pr-agent review output: author github-actions[bot] and, within the first 5 lines, a pr-agent:review / pr-agent:improve
  marker (HTML comment or link reference) or one of its two headings. A marker that only shows up further down (a quote of
  somebody else's output) does not count; the two notices (persistent-review update, generation failure) stay plain bot comments.
#>
function Test-HarnessPrAgentComment {
    param([AllowEmptyString()][AllowNull()][string]$Body)
    $lines = @((($Body ?? '') -split "`r?`n") | Select-Object -First 5)
    if (@($lines | Where-Object { $_ -match '\[Persistent review\]' -or $_ -match '^\s*Failed to generate\b' }).Count) { return $false }
    if (@($lines | Where-Object {
                $_ -match '^\s*<!--\s*pr-agent:(?:review|improve)\b' -or
                $_ -match '^\s*\[pr-agent:(?:review|improve)[^\]]*\]:\s*\S+' -or
                $_ -match 'PR Reviewer Guide|PR Code Suggestions'
            }).Count) { return $true }
    return $false
}

<# Log of a workflow run (gh run view --log; one job with -JobId). $null when unavailable (still running, expired, no access). #>
function Get-HarnessRunLog {
    param([Parameter(Mandatory)][string]$RunId, [string]$JobId)
    if ($RunId -notmatch '^\d+$') { return $null }
    $argv = @('run', 'view', $RunId, '--repo', $script:RepoSlug, '--log')
    if ($JobId -match '^\d+$') { $argv += @('--job', $JobId) }
    $r = Invoke-HarnessGh $argv -AllowFail
    if ($r.Code -ne 0) { return $null }
    $r.Out
}

<#
  The four sources as one table. Kind: agent (write access and an agent marker on the first line), bot-summary, bot,
  pr-agent (github-actions[bot] review output), user (write access, no marker: the maintainer's own opinion) and external
  (neither bot nor write access; a deleted account with an empty login too).
  Review comments carry their thread, whether it is resolved and their review. Only COMMENTED and CHANGES_REQUESTED reviews
  are collected (empty bodies too: inline comments hang under an empty COMMENTED review); an empty review that only holds
  our replies counts as ours. IsNew: updated_at later than Since. InReplyTo: ids named by the marker's in-reply-to.
#>
function Get-HarnessCommentItems {
    param([Parameter(Mandatory)]$Activity, $State, [string]$Since)
    $summaryIds = if ($State) { @($State.summaries | ForEach-Object { [string]$_.id }) } else { @() }
    $threadOf = @{}
    foreach ($t in @($Activity.Threads)) {
        foreach ($c in @($t.comments.nodes)) { $threadOf[[string]$c.databaseId] = $t }
    }
    $table = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($source, $c, $created, $more)
        $who = [string](Get-HarnessProp (Get-HarnessProp $c 'user') 'login')
        $commentBody = [string](Get-HarnessProp $c 'body')
        $id = [string]$c.id
        $marker = Get-AgentMarker $commentBody
        $class = if (-not $who) { 'external' }
        elseif ($who -match '\[bot\]$') {
            if ($source -eq 'issue' -and $summaryIds -contains $id) { 'bot-summary' }
            elseif ($source -eq 'issue' -and $who -eq 'github-actions[bot]' -and (Test-HarnessPrAgentComment $commentBody)) { 'pr-agent' }
            else { 'bot' }
        } elseif (Test-RepoWriter $who) {
            if ($marker) { 'agent' } else { 'user' }
        } else { 'external' }
        $updated = [string](Get-HarnessProp $c 'updated_at'); if (-not $updated) { $updated = $created }
        $thread = if ($source -eq 'review-comment') { $threadOf[$id] } else { $null }
        $row = [pscustomobject]@{
            Source = $source; Id = $id; Author = $(if ($who) { $who } else { '(deleted account)' }); Kind = $class; Body = $commentBody
            Created = $created; Updated = $updated; Url = [string](Get-HarnessProp $c 'html_url')
            IsNew = (-not $Since) -or ((ConvertTo-HarnessUtc $updated) -gt (ConvertTo-HarnessUtc $Since))
            ThreadId = $(if ($thread) { $thread.id } else { $null })
            Resolved = $(if ($thread) { [bool]$thread.isResolved } else { $null })
            ReviewId = [string](Get-HarnessProp $c 'pull_request_review_id')
            InReplyTo = $(if ($marker) { @($marker.InReplyTo) } else { @() })
            State = [string](Get-HarnessProp $c 'state'); Comments = @(); ApprovedLater = $false
        }
        if ($more) { foreach ($k in $more.Keys) { $row.$k = $more[$k] } }
        $table.Add($row)
    }
    foreach ($c in @($Activity.Issue)) { & $add 'issue' $c ([string]$c.created_at) $null }
    foreach ($c in @($Activity.Review)) { & $add 'review-comment' $c ([string]$c.created_at) $null }
    $reviews = @($Activity.Reviews)
    foreach ($c in $reviews) {
        $reviewState = [string](Get-HarnessProp $c 'state')
        if (@('COMMENTED', 'CHANGES_REQUESTED') -notcontains $reviewState) { continue }
        $rid = [string]$c.id
        $inline = @($table | Where-Object { $_.Source -eq 'review-comment' -and $_.ReviewId -eq $rid })
        $author = [string](Get-HarnessProp (Get-HarnessProp $c 'user') 'login')
        $approved = $reviewState -eq 'CHANGES_REQUESTED' -and @($reviews | Where-Object {
                (Get-HarnessProp $_ 'state') -eq 'APPROVED' -and [string](Get-HarnessProp (Get-HarnessProp $_ 'user') 'login') -eq $author -and
                (ConvertTo-HarnessUtc $_.submitted_at) -gt (ConvertTo-HarnessUtc $c.submitted_at) }).Count -gt 0
        & $add 'review' $c ([string]$c.submitted_at) @{ Comments = @($inline | ForEach-Object Id); ApprovedLater = $approved }
        $last = $table[$table.Count - 1]
        if (-not $last.Body.Trim() -and $inline.Count -and @($inline | Where-Object Kind -ne 'agent').Count -eq 0) { $last.Kind = 'agent' }
    }
    $table.ToArray()
}

<#
  Has a comment been answered. "Later" is always measured against the original comment's updated_at: edited after our
  reply means unanswered.
  - agent items and bot notices (receipts and the like): nothing needed;
  - bot review summary: a disposition after it references its run id;
  - pr-agent review output: like the maintainer's opinions, a later agent comment must name it in in-reply-to;
  - review comment: if the thread holds a reply of ours it must be later than the last edit; the maintainer's own inline
    comment needs such a reply (resolving alone is not an answer); a bot inline comment nobody replied to counts as
    handled when its thread is resolved (the disposition table dealt with it);
  - everything else (issue comment, review body, CHANGES_REQUESTED): one of our comments names it in in-reply-to
    (numbers that merely occur in the text do not count). An empty review that only holds inline comments is judged by
    those; CHANGES_REQUESTED can also be lifted by a later APPROVED of the same author.
#>
function Test-HarnessResponded {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, $State)
    $edited = ConvertTo-HarnessUtc $Item.Updated
    $explicit = @($Items | Where-Object {
            $_.Kind -eq 'agent' -and @($_.InReplyTo) -contains $Item.Id -and (ConvertTo-HarnessUtc $_.Created) -gt $edited }).Count -gt 0
    switch ($Item.Kind) {
        'agent' { return $true }
        'bot-summary' {
            $s = @($State.summaries) | Where-Object { [string]$_.id -eq $Item.Id } | Select-Object -First 1
            return [bool]($s -and $s.runId -and (@($State.dispositionRuns) -contains [string]$s.runId))
        }
        'pr-agent' { return $explicit }
    }
    if ($Item.Source -eq 'review-comment') {
        $replies = @($Items | Where-Object { $_.Kind -eq 'agent' -and $_.ThreadId -and $_.ThreadId -eq $Item.ThreadId -and $_.Id -ne $Item.Id })
        $later = @($replies | Where-Object { (ConvertTo-HarnessUtc $_.Created) -gt $edited }).Count -gt 0
        if ($replies.Count -or $Item.Kind -ne 'bot') { return $explicit -or $later }
        return $explicit -or [bool]$Item.Resolved
    }
    if ($Item.Kind -eq 'bot') { return $true }
    if ($Item.Source -eq 'review') {
        if ($Item.State -eq 'CHANGES_REQUESTED') { return $explicit -or [bool]$Item.ApprovedLater }
        if (-not $Item.Body.Trim() -and @($Item.Comments).Count) {
            foreach ($cid in @($Item.Comments)) {
                $c = $Items | Where-Object { $_.Source -eq 'review-comment' -and $_.Id -eq $cid } | Select-Object -First 1
                if ($c -and -not (Test-HarnessResponded -Item $c -Items $Items -State $State)) { return $false }
            }
            return $true
        }
    }
    return $explicit
}

<# Latest result of each check on a head: name -> { status; conclusion; details_url }. #>
function Get-HarnessCheckRuns {
    param([Parameter(Mandatory)][string]$Sha)
    $pages = Get-HarnessApi "repos/$($script:RepoSlug)/commits/$Sha/check-runs?per_page=100" -Paginate
    $latest = @{}
    foreach ($c in @($pages | ForEach-Object { $_.check_runs } | ForEach-Object { $_ })) {
        if (-not $latest.ContainsKey($c.name) -or [long]$c.id -gt [long]$latest[$c.name].id) { $latest[$c.name] = $c }
    }
    return $latest
}

# ---- locks ----------------------------------------------------------------------------------

<#
  Local named mutexes held by the kernel: a killed holder releases them and the next waiter takes over (AbandonedMutex).
  There is no owner file and no "steal after a timeout": a lock that cannot be had is an error, never an unlocked run.
    merge  one merge at a time on this machine (-Merge and -After hold it for their whole run)
    git    anything that changes the shared .git (fetch, worktree, branch), around single git operations only
  Order is merge, then git; nothing inside a git lock takes another lock. Local\ is shared by one login session only; run
  the maintainer scripts from the same desktop session.
#>
function Get-HarnessLockName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notin 'merge', 'git') { throw "Unknown lock $Name (merge / git only)" }
    "Local\$script:LockScope-$Name"
}

function Enter-HarnessLock {
    param([Parameter(Mandatory)][string]$Name, [double]$TimeoutSeconds = 1800)
    $full = Get-HarnessLockName $Name
    $m = [System.Threading.Mutex]::new($false, $full)
    try { $got = $m.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
    catch [System.Threading.AbandonedMutexException] { $got = $true; Write-Host "  [lock] the previous holder of $full exited without releasing it; taken over" }
    if (-not $got) { $m.Dispose(); return $null }
    [pscustomobject]@{ Name = $full; Mutex = $m }
}

function Exit-HarnessLock {
    param($Handle)
    if ($null -eq $Handle) { return }
    try { $Handle.Mutex.ReleaseMutex() } catch { Write-Host "  [lock] releasing $($Handle.Name) failed: $($_.Exception.Message)" }
    $Handle.Mutex.Dispose()
}

function Invoke-WithHarnessLock {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$ScriptBlock, [double]$TimeoutSeconds = 1800)
    $held = Enter-HarnessLock -Name $Name -TimeoutSeconds $TimeoutSeconds
    if (-not $held) { throw [System.TimeoutException]::new("Waited more than $TimeoutSeconds s for $(Get-HarnessLockName $Name)") }
    try { & $ScriptBlock } finally { Exit-HarnessLock $held }
}

<# Run a block under a lock. A self-test observer (Set-HarnessLockImpl) sees the lock name and a block that holds the real lock and runs the code. #>
function Invoke-HarnessLocked {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Script, [double]$TimeoutSeconds = 1800)
    $real = { Invoke-WithHarnessLock -Name $Name -ScriptBlock $Script -TimeoutSeconds $TimeoutSeconds }.GetNewClosure()
    if ($script:LockImpl) { return & $script:LockImpl $Name $real }
    & $real
}

function Invoke-HarnessGitLocked { param([Parameter(Mandatory)][scriptblock]$Script) Invoke-HarnessLocked -Name git -Script $Script -TimeoutSeconds 600 }
function Invoke-HarnessMergeLocked { param([Parameter(Mandatory)][scriptblock]$Script) Invoke-HarnessLocked -Name merge -Script $Script }

<# Self-test: while an observer is set the lock names use a private scope, so a self-test never waits for (or blocks) a real merge. #>
function Set-HarnessLockImpl {
    param([scriptblock]$Impl)
    $script:LockScope = if ($Impl) { "ReaperHarness-selftest-$PID" } else { 'ReaperHarness' }
    $script:LockImpl = $Impl
}

# ---- self-test framework --------------------------------------------------------------------

function Set-HarnessFake { param([scriptblock]$Handler) $script:Fake = $Handler }

function Read-HarnessFixture {
    param([Parameter(Mandatory)][string]$Name)
    $fixturePath = Join-Path $PSScriptRoot "../fixtures/$Name"
    , (ConvertFrom-Json -InputObject (Get-Content -Raw -LiteralPath $fixturePath) -Depth 100 -DateKind String -NoEnumerate)
}

<# Deep copy (a self-test edits a copy of a fixture to build a counter-example). Arrays stay arrays. #>
function Copy-HarnessObject {
    param($Value)
    , (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100) -Depth 100 -DateKind String -NoEnumerate)
}

<#
  Fake external commands: routes is an ordered table, key = regex over the whole command line ("exe arg ..."), value = a
  scriptblock (argv, opts) returning an object (turned into JSON), a string or @{ Code; Out; Err }. Unmatched node commands
  (the repository's own scripts: privacy tool, message rules, maint.mjs) and local git config reads fall through to the real
  command (no network); everything else fails, so a self-test shows which command it forgot. Log records every command line.
#>
function New-HarnessFake {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Specialized.OrderedDictionary]$Routes, [System.Collections.Generic.List[string]]$Log)
    return {
        param($cmd, $argv, $opts)
        $line = "$cmd $($argv -join ' ')"
        if ($null -ne $Log) { $Log.Add($line) }
        foreach ($k in $Routes.Keys) {
            if ($line -match $k) {
                $v = & $Routes[$k] $argv $opts
                if ($v -is [hashtable] -and $v.ContainsKey('Code')) { return $v }
                $out = if ($v -is [string]) { $v } elseif ($null -eq $v) { '' } else { ConvertTo-Json -InputObject $v -Depth 100 -Compress }
                if ($argv -contains '--slurp') { $out = "[$out]" }
                return @{ Code = 0; Out = $out; Err = '' }
            }
        }
        if ($cmd -match '(^|[\\/])node(\.exe)?$') { return $null }
        if ($line -match '^git (-C \S+ config --get harness\.|config --file )') { return $null }
        return @{ Code = 1; Out = ''; Err = "no fixture for: $line" }
    }.GetNewClosure()
}

# A needle that cannot occur by accident (the same word as FAKE_NEEDLE in scripts/lib/privacy-needles.mjs; a self-test that
# expects it to be refused fails if the two ever differ).
$script:FakeNeedle = 'harness-selftest-fake-needle-5d2a'
function Get-HarnessFakeNeedle { $script:FakeNeedle }

<#
  The self-tests run the repository's own privacy tool and message rules for real. This writes the needle file they use as the
  personal needle source (never the maintainer's own file) into the given directory and makes the module use it.
#>
function New-HarnessSelfTestNeedles {
    param([Parameter(Mandatory)][string]$Directory)
    $needlePath = Join-Path $Directory 'selftest-needles.txt'
    [IO.File]::WriteAllText($needlePath, "$($script:FakeNeedle)`n", [Text.UTF8Encoding]::new($false))
    Set-HarnessNeedles -Mode local -NeedleFile $needlePath
    $needlePath
}

function New-HarnessCases { , [System.Collections.Generic.List[object]]::new() }

<# Bad: the example must be caught. Flagged: this run caught it (for a good example: flagged it by mistake). #>
function Add-HarnessCase {
    param([Parameter(Mandatory)]$Cases, [Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][bool]$Bad, [Parameter(Mandatory)][bool]$Flagged)
    $Cases.Add([pscustomobject]@{ Label = $Label; Bad = $Bad; Passed = $(if ($Bad) { $Flagged } else { -not $Flagged }) })
}

function Complete-HarnessSelfTest {
    param([Parameter(Mandatory)]$Cases, [Parameter(Mandatory)][string]$Name)
    $badCount = @($Cases | Where-Object Bad).Count
    $good = $Cases.Count - $badCount
    $failed = @($Cases | Where-Object { -not $_.Passed })
    foreach ($f in $failed) { [Console]::Error.WriteLine("self-test failed: $($f.Label)") }
    $ok = $failed.Count -eq 0 -and $badCount -gt 0 -and $good -gt 0
    [Console]::Out.WriteLine("$Name -SelfTest: $(if ($ok) { 'PASS' } else { 'FAIL' }) (bad $badCount, good $good)")
    if ($ok) { return 0 } else { return 1 }
}

<# Run a block in a self-test; a throw counts as "caught". #>
function Test-Throws { param([scriptblock]$Script) try { & $Script | Out-Null; return $false } catch { return $true } }

<# Run a block in a self-test and return what it throws ($null when it does not throw): a case can then tell the reason apart. #>
function Get-ThrownMessage { param([scriptblock]$Script) try { & $Script | Out-Null; return $null } catch { return $_.Exception.Message } }

# ---- source hygiene (checked by every self-test) --------------------------------------------

<#
  Rules every maintainer script obeys: SPDX header in the first lines, Set-StrictMode and $ErrorActionPreference = 'Stop',
  no local or drive path, no task-card number form, and no variable whose spelling differs only by case (PowerShell treats
  $Head and $head as one variable). Returns the list of problems.
#>
function Get-HarnessSourceProblems {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Name)
    $problems = [System.Collections.Generic.List[string]]::new()
    if (@(($Text -split "`r?`n") | Select-Object -First 3 | Where-Object { $_ -match 'SPDX-License-Identifier: MIT' }).Count -eq 0) { $problems.Add("${Name}: no SPDX-License-Identifier: MIT in the first lines") }
    if ($Text -notmatch 'Set-StrictMode -Version Latest') { $problems.Add("${Name}: no Set-StrictMode -Version Latest") }
    if ($Text -notmatch '\$ErrorActionPreference = ''Stop''') { $problems.Add("${Name}: no `$ErrorActionPreference = 'Stop'") }
    if ($Text -match '(?i)\b[a-z]:[\\/](?:users|home|dev|claude|work)') { $problems.Add("${Name}: a local drive path is hard-coded") }
    if ($Text -match '(?i)/(?:users|home)/[a-z0-9_.-]+/') { $problems.Add("${Name}: a home-directory path is hard-coded") }
    if ($Text -match '\b(?:R' + 'N|R' + 'H)-?\d{2}[a-z]?\b') { $problems.Add("${Name}: a task-card number form appears") }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { $problems.Add("${Name}: does not parse: $($errors[0].Message)"); return $problems.ToArray() }
    # a hashtable ignores the case of its keys, as PowerShell ignores the case of variable names; the sets (ordinal comparer) keep every spelling seen
    $spellings = @{}
    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $n = $v.VariablePath.UserPath
        if ($n -match '^(?:env|script|global|local|private|using):') { $n = $n -replace '^[a-z]+:', '' }
        if (-not $spellings.ContainsKey($n)) { $spellings[$n] = [System.Collections.Generic.HashSet[string]]::new() }
        [void]$spellings[$n].Add($n)
    }
    foreach ($key in $spellings.Keys) {
        if ($spellings[$key].Count -gt 1) { $problems.Add("${Name}: variable spelled differently only by case: $(@($spellings[$key] | Sort-Object) -join ' / ')") }
    }
    return $problems.ToArray()
}

Export-ModuleMember -Function *-Harness*, *-AgentMarker, *-MessageErrors, *-PrTextErrors,
    Format-AgentText, Test-PublicText, Assert-PublicText, Test-RepoWriter, Get-InfraTouches, Test-Throws, Get-ThrownMessage, Invoke-WithHarnessLock

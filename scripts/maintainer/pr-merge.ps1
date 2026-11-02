#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
#
# Merge a sub-PR (only into feature/v1, squash). Three steps; any failure stops and prints the state, nothing is retried:
#   -Check -Pr <n> [-WaiverFile <f>]
#       go through the "clean" criteria one by one and print one JSON line: Code = ready | needs-user | not-ready (exit code
#       0 / 2 / 1) with Failures, Needs, Warnings and ReliedOn (every user record the verdict leans on, verbatim)
#   -Merge -Pr <n> -SummaryFile <f> [-WaiverFile <f>]
#       check again; only "ready" is merged: squash, sha pinned to the checked head, explicit subject "<PR title> (#n)" and
#       body (summary paragraph, blank line, the one sign-off line); the merge commit is read back (title, body, author)
#   -After -Pr <n> -Worktree <path>
#       read back the squash commit on origin/feature/v1 and compare before anything is deleted: the remote tip and the local
#       tip (where they exist) must be the head of the PR that was merged, the worktree must have no changes and no untracked
#       files, must not be locked and must not hold the current directory (git could not remove it), and the branch must not be
#       checked out anywhere but at that path. Any mismatch or failed command throws and nothing is deleted. Then delete the remote
#       sub-branch, remove exactly that worktree (not recursively, nothing derived from it) and the local branch; the last line says
#       what was there and what was not, and names the ignored files that went with the worktree. A run again after one that stopped
#       halfway finishes the rest: git may have unregistered the worktree and left a directory with no file in it, only empty directories
#   -SelfTest
#       run offline on the recorded responses in fixtures/, with a counter-example for every criterion
# The criteria are read from the checkout this script runs from, so that checkout must sit exactly on the freshly fetched
# origin/feature/v1 with a clean tree: the rules come from the target line, never from the PR under review. core.hooksPath
# must resolve to scripts/hooks of that checkout (relative or absolute spelling), otherwise the commit and push guards are off.
# Run it from the main checkout: a shared core.hooksPath names the main checkout's hooks, so another worktree reports it.
#
# The user's decisions live in one JSON record file, handed in with -WaiverFile only (no environment variable, no config).
# Every record needs "by": "user" and a full 40-character head; after another push it no longer applies and the user has to
# register the new head:
#   { "waivers":          { "<pr>": [{ "head": "<sha40>", "by": "user", "red": 0, "important": 1, "deferred": false, "note": "..." }] },
#     "approvals":        { "<pr>": [{ "head": "<sha40>", "by": "user", "note": "..." }] },
#     "external-handled": { "<pr>": [{ "head": "<sha40>", "by": "user", "comments": [{ "id": "<comment id>", "updated_at": "<its updated_at when handled>" }], "note": "..." }] } }
# waivers let a footer with red / important pass ("deferred": true, a JSON boolean, also lets severe findings that are not
# handled pass, see below; "summaryHash": true, a JSON boolean, also lets a bot summary whose hash does not match the posted
# record pass); approvals approve a change to the infrastructure paths; external-handled names external comments the user dealt
# with (bound to the comment's updated_at, an edit voids it). More than one record of a kind for the same head is a failure
# that names the file and the kind: which one was meant is the user's to say.
# Trust model: a record binds a decision to one head and leaves a written trace; it is not authentication. "by" is a label,
# anything that can write the file can write "user". So records are written only on the maintainer's explicit instruction,
# and -Check / -Merge print every record they rely on. The file must live outside the repository and all of its worktrees
# (judged by the final path the system reports: junctions, symlinks and short names are resolved; device and UNC spellings,
# reparse points on the path and files with more than one hard link are refused).
# The bot summary is create-only: updated_at different from created_at is red; when the run log holds the review bot's
# posted record (comment id and body sha256) the summary must match it, otherwise the check degrades to updated_at only and
# says so in Warnings.
# Disposition tables are read the way markdown renders them: HTML comments do not count, a line indented by 4 columns is no table row,
# code fences follow CommonMark and a header row is one only with a delimiter row right below it. They are read default-deny. In the
# level column only 建议, 总结 and 信息 are not severe; any other value is. A severe row counts as handled only when its disposition starts with 已修, 修复 or 采纳 (markdown marks removed), holds no refusal word, does not go on
# to say the fix is not done, and has a commit hash in that column or right of it; anything else, other words, an empty cell, a row
# inside a code fence and a table without a disposition column included, needs a user waiver. A commit hash stands on its own (not
# part of a longer word, of a file name or of a link other than /commit/) and has a letter and a digit: only letters read as a word, only digits as an
# id, so such a hash is written longer. Only the form is checked, not that the commit exists. Every 【红旗】 and 【重要】 finding of a bot
# summary needs a row of that level, with its own location and summary, in the disposition comments that reference the summary's
# run: a shortfall is a failure that says how many rows are missing.

[CmdletBinding()]
param(
    [switch]$Check, [switch]$Merge, [switch]$After, [switch]$SelfTest,
    [int]$Pr, [string]$SummaryFile, [string]$Worktree, [string]$WaiverFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/HarnessGh.psm1') -Force

$MergeablePoll = @{ Tries = 5; Seconds = 2 }
$AllowedCommitters = @('noreply@synchain.ca', 'noreply@github.com')
$PostedRecordPattern = 'harness-review-posted id=(\d+) sha256=([0-9a-f]{64})'

# ---- the records file -----------------------------------------------------------------------

<#
  Identity of a path in the file system (Windows): Final is the final path the system reports after opening a handle
  (junctions, symlinks and short names resolved, \\?\ prefix removed), Links the hard-link count. $null when the path does
  not exist. Elsewhere only GetFullPath, link count 1.
#>
function Get-PathIdentity {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not $IsWindows) { return [pscustomobject]@{ Final = [IO.Path]::GetFullPath($Path); Links = 1 } }
    if (-not ('ReaperHarness.PathIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace ReaperHarness {
    public static class PathIdentity {
        [StructLayout(LayoutKind.Sequential)]
        struct Info { public uint Attributes, CreatedLow, CreatedHigh, AccessedLow, AccessedHigh, WrittenLow, WrittenHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle h, StringBuilder buf, uint size, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle h, out Info info);
        // attributes only: access 0, share read/write/delete; BACKUP_SEMANTICS opens directories too; links are followed
        static SafeFileHandle Open(string path) {
            var h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
            if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            return h;
        }
        public static string Final(string path) {
            using (var h = Open(path)) {
                var sb = new StringBuilder(32768);
                uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
                if (n == 0 || n >= sb.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
                return sb.ToString();
            }
        }
        public static uint Links(string path) {
            using (var h = Open(path)) {
                Info i;
                if (!GetFileInformationByHandle(h, out i)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return i.Links;
            }
        }
    }
}
'@
    }
    $final = [ReaperHarness.PathIdentity]::Final($Path) -replace '^\\\\\?\\UNC\\', '\\' -replace '^\\\\\?\\', ''
    [pscustomobject]@{ Final = $final; Links = [ReaperHarness.PathIdentity]::Links($Path) }
}

<# The path itself or the first of its parent directories that is a reparse point (junction, symlink, mount point); $null when none. #>
function Find-ReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    for ($p = [IO.Path]::GetFullPath($Path); $p; $p = [IO.Path]::GetDirectoryName($p)) {
        if ((Test-Path -LiteralPath $p) -and ([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint)) { return $p }
    }
    $null
}

<#
  Where the records file lives; returns the problems (empty = fine). It must be outside the repository and every worktree
  (Roots), because a PR can write into those. A plain prefix comparison is not enough: a junction, a hard link or a \\?\
  spelling would pass it. -IdentityOf is the seam a self-test uses to fake the file system's answer.
#>
function Test-RecordsLocation {
    param(
        [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$ExcludedRoots,
        [scriptblock]$IdentityOf = { param($p) Get-PathIdentity $p }
    )
    $real = { param($p) $id = & $IdentityOf $p; ($id ? $id.Final : [IO.Path]::GetFullPath($p)).TrimEnd('\', '/') }
    $under = { param($p, $dir) $p.StartsWith((& $real $dir) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { return @("-WaiverFile must be an absolute path: $Path") }
    if ($Path -match '^[\\/]{2}') { return @("-WaiverFile must not be a device path or a UNC path (two leading slashes): $Path") }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @("-WaiverFile does not point at an existing file: $Path") }
    $link = Find-ReparsePoint $Path
    if ($link) { return @("The path of the records file has a reparse point (junction, symlink, ...), its location cannot be judged: $link") }
    $id = & $IdentityOf $Path
    if ($id.Links -ne 1) { return @("The records file has $($id.Links) hard links (it must have exactly 1, the other name may sit in a worktree): $Path") }
    # a drive letter can be an alias of a share (net use, DefineDosDevice): the final path is then UNC and cannot be compared with local roots
    if ($id.Final -match '^[\\/]{2}') { return @("The final path of the records file is not on a local volume ($($id.Final)), its location cannot be judged: $Path") }
    foreach ($root in $ExcludedRoots) {
        if (& $under $id.Final $root) { return @("The records file must be outside the repository and all of its worktrees: $Path") }
    }
    return @()
}

<# Worktree paths of this repository (git worktree list --porcelain). #>
function Get-RegisteredWorktrees {
    $out = (Invoke-HarnessGit @('worktree', 'list', '--porcelain')).Out
    @(($out -split "`r?`n") | Where-Object { $_ -match '^worktree ' } | ForEach-Object { [IO.Path]::GetFullPath($_.Substring(9).Trim()) })
}

<# Records of one PR; an unusable location (Usable false) reads as no records, never as permission. A damaged file is an error. #>
function Read-Records {
    param([int]$Number, [string]$Path, [bool]$Usable)
    $all = if ($Usable -and $Path) { ConvertFrom-Json -InputObject (Get-Content -Raw -LiteralPath $Path) -Depth 20 -DateKind String } else { $null }
    $pick = { param($kind) @(Get-HarnessProp (Get-HarnessProp $all $kind) ([string]$Number)) | Where-Object { $_ } }
    [pscustomobject]@{ File = $(if ($Usable) { $Path } else { $null }); Waivers = @(& $pick 'waivers'); Approvals = @(& $pick 'approvals'); ExternalHandled = @(& $pick 'external-handled') }
}

<# The records by the user for this head: head must be a full 40 characters and equal, by must be user. #>
function Get-HeadRecords {
    param([object[]]$List, [string]$ForHead)
    @(@($List) | Where-Object {
            $_ -and [string](Get-HarnessProp $_ 'head') -eq $ForHead -and $ForHead -match '^[0-9a-f]{40}$' -and [string](Get-HarnessProp $_ 'by') -eq 'user'
        })
}

<# The record of one kind for this head; more than one is a failure of the verdict, never decided here. #>
function Get-HeadRecord {
    param([object[]]$List, [string]$ForHead)
    @(Get-HeadRecords -List $List -ForHead $ForHead) | Select-Object -First 1
}

<# A comment named in external-handled: same id, and the registered updated_at is the same moment as the comment's updated_at now. #>
function Test-HandledComment {
    param($Record, [Parameter(Mandatory)]$Comment)
    foreach ($c in @(Get-HarnessProp $Record 'comments')) {
        if ([string](Get-HarnessProp $c 'id') -ne $Comment.Id) { continue }
        $at = [string](Get-HarnessProp $c 'updated_at')
        try { if ($at -and (ConvertTo-HarnessUtc $at) -eq (ConvertTo-HarnessUtc $Comment.Updated)) { return $true } } catch { }
    }
    return $false
}

# ---- facts (network, local git, Node criteria; nothing of the PR is executed) ---------------

function Get-MergeFacts {
    param([Parameter(Mandatory)][int]$Number, [string]$RecordsPath)
    $slug = Get-HarnessRepo
    $pull = Get-HarnessApi "repos/$slug/pulls/$Number"
    # mergeable is computed lazily by GitHub: right after the base moved the first read is often null; wait and read again
    for ($k = 0; $k -lt $MergeablePoll.Tries -and $null -eq (Get-HarnessProp $pull 'mergeable'); $k++) {
        Start-Sleep -Seconds $MergeablePoll.Seconds
        $pull = Get-HarnessApi "repos/$slug/pulls/$Number"
    }
    $sha = [string]$pull.head.sha
    $activity = Get-HarnessPrActivity $Number
    $state = Get-HarnessReviewState $activity
    $runId = if ($state.summary) { [string]$state.summary.runId } else { '' }
    $run = if ($runId) { Get-HarnessApi "repos/$slug/actions/runs/$runId" -AllowFail } else { $null }
    $jobs = @(if ($run) { Get-HarnessApi "repos/$slug/actions/runs/$runId/jobs?per_page=100" -Paginate | ForEach-Object { $_.jobs } | ForEach-Object { $_ } })
    # posted record: the line (comment id + body sha256) the review bot prints after posting its summary, found in the run log.
    # $null when unavailable (older run, expired log): the criterion then degrades to updated_at only and Warnings says so
    $posted = $null
    if ($state.summary -and $run) {
        $job = @($jobs | Where-Object { $_.name -eq (Get-HarnessBotCheck) }) | Select-Object -First 1
        if ($job) {
            $logText = Get-HarnessRunLog -RunId $runId -JobId ([string]$job.id)
            if ($logText) {
                $found = [regex]::Matches($logText, $PostedRecordPattern)
                if ($found.Count) { $posted = [pscustomobject]@{ Id = $found[$found.Count - 1].Groups[1].Value; Sha256 = $found[$found.Count - 1].Groups[2].Value } }
            }
        }
    }
    $files = Get-HarnessApi "repos/$slug/pulls/$Number/files?per_page=100" -Paginate
    Invoke-HarnessGitLocked {
        Invoke-HarnessGit @('fetch', '--no-tags', 'origin', '+refs/heads/feature/v1:refs/remotes/origin/feature/v1', "+refs/pull/${Number}/head:refs/remotes/origin/pr/$Number") | Out-Null
    } | Out-Null
    # the state of this checkout is read after the fetch: the criteria must be the freshly fetched feature line
    $roots = @(Get-HarnessRepoRoot) + @(Get-RegisteredWorktrees)
    $recordProblems = @(if ($RecordsPath) { Test-RecordsLocation -Path $RecordsPath -ExcludedRoots $roots })
    [pscustomobject]@{
        Pr = $Number; Pull = $pull; Head = $sha; Files = @($files); Activity = $activity
        State = $state; Items = @(Get-HarnessCommentItems -Activity $activity -State $state); Threads = @($activity.Threads)
        Run = $run; Jobs = $jobs; Posted = $posted; Checks = Get-HarnessCheckRuns $sha; Required = Get-HarnessRequiredChecks
        Records = Read-Records -Number $Number -Path $RecordsPath -Usable ($recordProblems.Count -eq 0); RecordsProblems = $recordProblems
        Clone = [pscustomobject]@{
            Head = (Invoke-HarnessGit @('rev-parse', 'HEAD')).Out.Trim()
            Tip = (Invoke-HarnessGit @('rev-parse', 'origin/feature/v1')).Out.Trim()
            Dirty = [bool](Invoke-HarnessGit @('status', '--porcelain')).Out.Trim()
            Root = Get-HarnessRepoRoot
            HooksPath = (Invoke-HarnessGit @('config', '--get', 'core.hooksPath') -AllowFail).Out.Trim()
        }
        PrRef = (Invoke-HarnessGit @('rev-parse', "refs/remotes/origin/pr/$Number")).Out.Trim()
    }
}

# ---- criteria (functions of the facts; the self-test gives every one a counter-example) -----

<#
  core.hooksPath must resolve to scripts/hooks of this checkout: written relative (scripts/hooks, ./scripts/hooks) or absolute,
  compared after normalising; unset, or another directory, means the commit and push guards are not active.
#>
function Test-HooksPath {
    param([Parameter(Mandatory)][string]$CheckoutRoot, [AllowEmptyString()][string]$Value)
    if (-not $Value) { return $false }
    $normalise = { param($p) [IO.Path]::GetFullPath($p, $CheckoutRoot).TrimEnd('\', '/') }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    [string]::Equals((& $normalise $Value), (& $normalise 'scripts/hooks'), $comparison)
}

<# A table cell without markdown emphasis and code marks (*, _, backtick), then compared with the decision words. #>
function Clear-MdCell {
    param([AllowEmptyString()][string]$Value)
    (($Value ?? '') -replace '[*_`]', '').Trim()
}

<# The columns a markdown line is indented by; a tab goes to the next stop of 4. #>
function Get-MdIndent {
    param([AllowEmptyString()][string]$MdLine)
    $width = 0
    foreach ($character in $MdLine.ToCharArray()) {
        if ($character -eq [char]32) { $width++ } elseif ($character -eq [char]9) { $width += 4 - ($width % 4) } else { break }
    }
    $width
}

<# How many cells a table line has; a pipe at either end opens or closes a cell and is no cell of its own. #>
function Get-MdCellCount {
    param([AllowEmptyString()][string]$MdLine)
    (($MdLine.Trim() -replace '\\\|', '' -replace '^\|', '' -replace '\|$', '') -split '\|').Count
}

<# The delimiter row of a table: indented by less than 4 columns, with a pipe, and every cell only hyphens with an optional colon at either end. #>
function Test-MdDelimiterRow {
    param([AllowEmptyString()][string]$MdLine)
    (Get-MdIndent $MdLine) -lt 4 -and $MdLine.Contains('|') -and $MdLine.Trim() -match '^\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?$'
}

<#
  Data rows of the disposition tables, read the way markdown renders them, so that what a reader of the comment cannot see cannot
  count. An HTML comment is not there: a block that starts with one lasts up to the line with its end (or to the end of the text without
  one), an inline one is cut out of its line and, inside a paragraph, can reach over lines up to the next blank line; in a table every row
  stands alone. A line indented by 4 columns is no table row, and it ends the table. A code fence follows CommonMark: indented by less
  than 4 columns, at least 3 of one mark; only the same mark at least as long with nothing behind it closes it, an open one reaches to the
  end of the text; the info string of a backtick fence holds no backtick. A row inside a fence is marked Fenced: it renders as a sample,
  not as a table, so it can show a problem but cannot show that anything was handled.
  A header row is one only with a delimiter row of as many cells right below it. The columns level / location / summary / disposition are
  recognised by the name a header cell starts with (the vocabulary of the disposition table is Chinese: 级别 位置 摘要 处置; a note after
  the name, as in "处置（采纳 / 不改 / 挂账）", is fine), never by position: extra columns and their order do not matter. Without a
  recognised header a row is scanned cell by cell (Cols is $null). Text between tables clears the header state, the next table is
  recognised again. The agent marker on the first line is read on its own (Get-AgentMarker), here it is one more comment.
#>
function Get-DispositionRows {
    param([AllowEmptyString()][string]$Body)
    $rows = [System.Collections.Generic.List[object]]::new()
    $lines = @(($Body ?? '') -split "`r?`n")
    $cols = $null
    $inTable = $false
    $fence = $null
    $inComment = $false
    for ($at = 0; $at -lt $lines.Count; $at++) {
        $line = $lines[$at]
        $visible = $line
        $delimiterBelow = $at + 1 -lt $lines.Count -and (Test-MdDelimiterRow $lines[$at + 1])
        if ($fence) {
            $closing = [regex]::Match($line, '^ {0,3}(`+|~+)[ \t]*$')
            if ($closing.Success -and $closing.Groups[1].Value[0] -eq $fence.Mark -and $closing.Groups[1].Length -ge $fence.Length) { $fence = $null; $cols = $null; $inTable = $false; continue }
            if ($line -notmatch '^\s*\|') { $cols = $null; $inTable = $false; continue }
        } else {
            if ($inComment) {
                if ($line.Contains('-->')) { $inComment = $false }
                continue
            }
            if ((Get-MdIndent $line) -ge 4) { $cols = $null; $inTable = $false; continue }
            $opening = [regex]::Match($line, '^ {0,3}(?:(`{3,})[^`]*|(~{3,}).*)$')
            if ($opening.Success) {
                $run = if ($opening.Groups[1].Success) { $opening.Groups[1].Value } else { $opening.Groups[2].Value }
                $fence = [pscustomobject]@{ Mark = $run[0]; Length = $run.Length }
                $cols = $null; $inTable = $false
                continue
            }
            if ($line -match '^ {0,3}<!--') {
                $inComment = -not $line.Contains('-->')
                $cols = $null; $inTable = $false
                continue
            }
            $visible = [regex]::Replace($line, '<!--.*?-->', '')
            $commentAt = $visible.IndexOf('<!--')
            if ($commentAt -ge 0 -and -not $inTable -and -not $delimiterBelow) {
                for ($later = $at + 1; $later -lt $lines.Count -and $lines[$later].Trim(); $later++) {
                    if ($lines[$later].Contains('-->')) { $inComment = $true; $visible = $visible.Substring(0, $commentAt); break }
                }
            }
            if ($visible -notmatch '^\s*\|') { $cols = $null; $inTable = $false; continue }
        }
        $cells = @((($visible -replace '\\\|', '') -split '\|') | ForEach-Object { Clear-MdCell $_ })
        if (-not @($cells | Where-Object { $_ }).Count) { continue }
        if (@($cells | Where-Object { $_ -and $_ -notmatch '^:?-{2,}:?$' }).Count -eq 0) { continue }
        $isHeader = -not $inTable -and $delimiterBelow -and (Get-MdCellCount $visible) -eq (Get-MdCellCount $lines[$at + 1])
        if ($isHeader) {
            $inTable = $true
            $map = @{}
            for ($i = 0; $i -lt $cells.Count; $i++) {
                foreach ($name in '级别', '位置', '摘要', '处置') {
                    if ($cells[$i] -match "^$name" -and -not $map.ContainsKey($name)) { $map[$name] = $i }
                }
            }
            if ($map.Count) { $cols = $map; $at++; continue }
        }
        $rows.Add([pscustomobject]@{ Line = $visible.Trim(); Cells = @($cells); Cols = $cols; Fenced = [bool]$fence })
        if ($isHeader) { $at++ }
    }
    $rows.ToArray()
}

<#
  The level of a disposition row; the deferred findings and the per-run count share it. With a level column its value decides,
  brackets or not: 红旗 and 重要 are those levels, only 建议 总结 信息 are not severe, every other value (another language, 高, an empty
  cell) comes back as other and is read as severe. Without a level column the cells are scanned for 【红旗】 and 【重要】, or a cell that is
  only that word.
  Returns 红旗, 重要, other or none.
#>
function Get-DispositionLevel {
    param([Parameter(Mandatory)]$TableRow)
    if ($TableRow.Cols -and $TableRow.Cols.ContainsKey('级别')) {
        $at = $TableRow.Cols['级别']
        $levelText = if ($at -lt $TableRow.Cells.Count) { $TableRow.Cells[$at] -replace '[【】\s]', '' } else { '' }
        if (Test-HarnessTextIn $levelText @('红旗', '重要')) { return $levelText }
        if (Test-HarnessTextIn $levelText @('建议', '总结', '信息')) { return 'none' }
        return 'other'
    }
    foreach ($levelName in '红旗', '重要') {
        if (@($TableRow.Cells | Where-Object { $_ -match "【$levelName】" -or (Test-HarnessSameText $_ $levelName) }).Count) { return $levelName }
    }
    'none'
}

<#
  Which finding a row is about: location + summary (markdown marks removed); two different findings at one location do not wipe
  each other out, and a row with a rewritten summary is not the same finding, so "fixed" then cannot clear the old deferral: better to
  ask the user once more. A row with neither column is only itself.
#>
function Get-DispositionKey {
    param([Parameter(Mandatory)]$TableRow)
    $cell = { param($name) if ($TableRow.Cols -and $TableRow.Cols.ContainsKey($name) -and $TableRow.Cols[$name] -lt $TableRow.Cells.Count) { $TableRow.Cells[$TableRow.Cols[$name]] } else { $null } }
    $named = (@((& $cell '位置'), (& $cell '摘要')) | Where-Object { $_ }) -join ' | '
    if ($named) { $named } else { $TableRow.Line }
}

<#
  Severe findings a disposition table does not show as handled: the whole row, for the user to decide. Default deny: a severe row
  is handled only when the disposition column starts with 已修, 修复 or 采纳, holds no refusal word (不改 不采纳 挂账 暂不 维持 and the others in the
  pattern below), does not go on to say the fix is not done (修复中, 采纳但不修 and the others in the pattern below; only right after the word,
  further on such words describe the fix) and has a commit hash; other words, an empty cell, a fenced row and a table without a
  disposition column are not handled. A later "fixed" with a commit hash no longer needs a waiver, a later "deferred" is listed again.
  The commit proof is looked for only in the disposition column and the columns right of it, in the form the header of this script
  describes: a word (feedback, effaced), a comment or run id (only digits) or a file name (abc1234.ps1) is no proof; a full stop that ends
  the sentence (abc1234.) changes nothing.
#>
function Get-DeferredSevere {
    param([object[]]$Items)
    $comments = [System.Collections.Generic.List[object]]::new()
    $order = 0
    foreach ($i in @($Items | Where-Object { $_.Kind -eq 'agent' })) {
        $m = Get-AgentMarker $i.Body
        if (-not $m -or $m.Kind -ne 'disposition') { continue }
        $judged = foreach ($row in @(Get-DispositionRows $i.Body)) {
            if ((Get-DispositionLevel $row) -ceq 'none') { continue }
            $at = if ($row.Cols -and $row.Cols.ContainsKey('处置') -and $row.Cols['处置'] -lt $row.Cells.Count) { $row.Cols['处置'] } else { -1 }
            $decision = if ($at -ge 0) { $row.Cells[$at] } else { '' }
            $proof = $at -ge 0 -and @($row.Cells | Select-Object -Skip $at | Where-Object { $_ -cmatch '(?:(?<![0-9A-Za-z/.#-])|(?<=/commits?/))(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}(?![0-9A-Za-z/-]|\.[0-9A-Za-z])' }).Count -gt 0
            $refused = $decision -match '(?:^|[^采])(?:不改|不采纳|挂账|暂不|维持)|未采纳|不修复|未修复|未改|未修|搁置|驳回|不处理|延后|暂缓|忽略'
            $unfinished = $decision -match '^(?:已修|修复|采纳)(?:[\s，,：:、；;]*(?:不了|不修|不做|待定|但不|与否|一半|[？?]|开\s*issue)|[\s，,：:、；;]+(?:后续|跟进)|中(?:$|[\s，,：:、；;。.])|计划)'
            $handled = -not $row.Fenced -and $decision -match '^(?:已修|修复|采纳)' -and -not $refused -and -not $unfinished -and $proof
            [pscustomobject]@{ Key = Get-DispositionKey $row; Line = $row.Line; Deferred = -not $handled }
        }
        $comments.Add([pscustomobject]@{ Round = [int]$m.Round; Order = $order; Rows = @($judged) })
        $order++
    }
    # the last word on each finding with the comments in a given order. The keys are compared exactly (two findings can differ only by
    # letter case). Inside one comment a row that is not handled stays: two rows that look like one finding are not cleared by each other
    $lastWord = {
        param($ordered)
        $word = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($entry in @($ordered)) {
            foreach ($judgedRow in @($entry.Rows)) {
                if ($word.ContainsKey($judgedRow.Key) -and $word[$judgedRow.Key].Order -eq $entry.Order -and $word[$judgedRow.Key].Deferred) { continue }
                $word[$judgedRow.Key] = [pscustomobject]@{ Order = $entry.Order; Line = $judgedRow.Line; Deferred = $judgedRow.Deferred }
            }
        }
        @($word.get_Values() | Where-Object Deferred | ForEach-Object Line)
    }
    # the round in the marker is typed by hand, so it alone decides nothing: a finding is handled only when the row of the highest
    # round and the row posted last both say so (round 9 by mistake must not hide a deferral posted after it, and the other way round)
    @(@(& $lastWord @($comments | Sort-Object Round, Order)) + @(& $lastWord $comments) | Select-Object -Unique)
}

<#
  One row per finding: for every bot summary, the disposition comments that reference its run must hold at least as many rows of
  红旗 and of 重要 as the summary lists findings of that level. Rows about the same finding (same location and summary) count once and a
  row in a code fence does not count, whichever comment they stand in: the same finding written twice must not cover one that has no
  row. A summary without a run link cannot be referenced, so its severe findings are all missing. Returns one message per shortfall,
  saying how many rows are missing.
#>
function Get-DispositionShortfalls {
    param([object[]]$Summaries, [object[]]$Items)
    $rowsOfRun = @{}
    foreach ($i in @($Items | Where-Object { $_.Kind -eq 'agent' })) {
        $m = Get-AgentMarker $i.Body
        if (-not $m -or $m.Kind -ne 'disposition' -or -not $m.Extra.ContainsKey('bot-run')) { continue }
        $referenced = [string]$m.Extra['bot-run']
        $rowsOfRun[$referenced] = @($(if ($rowsOfRun.ContainsKey($referenced)) { $rowsOfRun[$referenced] })) + @(Get-DispositionRows $i.Body)
    }
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($botSummary in @($Summaries)) {
        $runKey = [string]$botSummary.runId
        $rows = @($(if ($runKey -and $rowsOfRun.ContainsKey($runKey)) { $rowsOfRun[$runKey] }))
        foreach ($levelName in '红旗', '重要') {
            $wanted = @(@(Get-HarnessProp $botSummary 'items') | Where-Object { $_ -and $_.level -ceq $levelName }).Count
            $different = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($levelRow in $rows) {
                if (-not $levelRow.Fenced -and (Get-DispositionLevel $levelRow) -ceq $levelName) { [void]$different.Add((Get-DispositionKey $levelRow)) }
            }
            $listed = $different.Count
            if ($listed -lt $wanted) { $problems.Add("The dispositions of $(if ($runKey) { "run $runKey" } else { 'a bot summary without a run link' }) hold $listed 【$levelName】 row(s) with their own location and summary, the bot summary lists ${wanted}: $($wanted - $listed) missing") }
        }
    }
    $problems.ToArray()
}

function Get-MergeVerdict {
    param([Parameter(Mandatory)]$Facts)
    $fail = [System.Collections.Generic.List[string]]::new()
    $warn = [System.Collections.Generic.List[string]]::new()
    $needs = [System.Collections.Generic.List[object]]::new()
    $need = { param($level, $kind, $reason) $needs.Add([pscustomobject]@{ Level = $level; Kind = $kind; Reason = $reason }) }
    # every user record the verdict relies on goes into the output verbatim
    $relied = [System.Collections.Generic.List[object]]::new()
    $recs = $Facts.Records
    $rely = { param($kind, $what) if (-not @($relied | Where-Object Kind -eq $kind).Count) { $relied.Add([pscustomobject]@{ Kind = $kind; File = $recs.File; Record = $what }) } }
    $pull = $Facts.Pull
    $sha = $Facts.Head
    $short = { param($raw) $text = [string]$raw; if ($text) { $text.Substring(0, [Math]::Min(7, $text.Length)) } else { '(none)' } }

    # 0. this checkout sits exactly on the freshly fetched origin/feature/v1 with a clean tree (otherwise the criteria may be stale);
    #    a records file at a bad location is a failure, and its content is not used
    if ($Facts.Clone.Head -ne $Facts.Clone.Tip) { $fail.Add('The checkout this script runs from is not on the freshly fetched origin/feature/v1 (fast-forward it first): the criteria may be stale') }
    if ($Facts.Clone.Dirty) { $fail.Add('The checkout this script runs from has uncommitted changes') }
    if (-not (Test-HooksPath -CheckoutRoot $Facts.Clone.Root -Value $Facts.Clone.HooksPath)) { $fail.Add("core.hooksPath is '$($Facts.Clone.HooksPath)', not scripts/hooks of this checkout: the commit and push guards are not active") }
    foreach ($problem in @($Facts.RecordsProblems)) { $fail.Add($problem) }
    $recordKinds = [ordered]@{ waivers = $recs.Waivers; approvals = $recs.Approvals; 'external-handled' = $recs.ExternalHandled }
    foreach ($recordKind in $recordKinds.get_Keys()) {
        $sameHead = @(Get-HeadRecords -List $recordKinds[$recordKind] -ForHead $sha)
        if ($sameHead.Count -gt 1) { $fail.Add("The records file $($recs.File) has $($sameHead.Count) records of kind $recordKind for head ${sha}: which one was meant is not guessed, keep one") }
    }

    # 1. the PR itself: open, not a draft, base feature/v1, head a feat/ sub-branch of this repository, mergeable
    if ($pull.state -ne 'open' -or [bool](Get-HarnessProp $pull 'merged')) { $fail.Add('The PR is not open') }
    if ([bool]$pull.draft) { $fail.Add('The PR is a draft') }
    if (-not (Test-HarnessSameText $pull.base.ref 'feature/v1')) { $fail.Add("base must be feature/v1: $($pull.base.ref)") }
    if ($pull.head.ref -cnotmatch '^feat/[a-z0-9][a-z0-9-]*$') { $fail.Add("head must be feat/<slug>: $($pull.head.ref)") }
    if ($pull.head.repo.full_name -ne (Get-HarnessRepo)) { $fail.Add('head is not a branch of this repository') }
    if ($Facts.PrRef -ne $sha) { $fail.Add('The PR head fetched locally differs from the API (a push just now?)') }
    if ((Get-HarnessProp $pull 'mergeable') -ne $true -or (Get-HarnessProp $pull 'mergeable_state') -in @('dirty', 'draft')) {
        $fail.Add("GitHub reports the PR as not mergeable (mergeable=$(Get-HarnessProp $pull 'mergeable'), state=$(Get-HarnessProp $pull 'mergeable_state'))")
    }

    # the list of files stops at 3000 entries: a longer change could hide an infrastructure path from criterion 8
    $changedFiles = Get-HarnessProp $pull 'changed_files'
    if ($null -eq $changedFiles -or [int]$changedFiles -ne @($Facts.Files).Count) {
        $fail.Add("GitHub reports changed_files=$changedFiles for the PR, the file list holds $(@($Facts.Files).Count): the infrastructure check would not see every path")
    }

    # 2. bot verdict: the newest summary reviewed the current head, its footer is usable, red = 0 and important = 0 (or a user waiver for this head)
    $bot = $Facts.State.summary
    $waiver = Get-HeadRecord $recs.Waivers $sha
    if (-not $bot) { $fail.Add('There is no bot review summary') }
    else {
        if ($bot.head -ne $sha) { $fail.Add("The newest bot summary reviewed $(& $short $bot.head), not the current head") }
        # the bot only creates, never edits: a different updated_at means the summary was edited after posting (for example red / important turned into 0)
        if ($bot.updatedAt -and (ConvertTo-HarnessUtc $bot.updatedAt) -ne (ConvertTo-HarnessUtc $bot.createdAt)) {
            $fail.Add("The bot summary $($bot.id) was edited after posting (created_at=$($bot.createdAt), updated_at=$($bot.updatedAt))")
        }
        if (-not $bot.ok) { $fail.Add("The bot verdict is unusable: $($bot.reason)") }
        else {
            # only red and important decide; a second run that counts the suggestions differently contradicts nothing
            $sameHeadCounts = @($Facts.State.summaries | Where-Object { $_.head -eq $sha -and $_.ok } | ForEach-Object { "$($_.red)/$($_.important)" } | Select-Object -Unique)
            if ($sameHeadCounts.Count -gt 1) { $fail.Add('The current head has several bot summaries whose footers contradict each other') }
            if ($bot.red -gt 0 -or $bot.important -gt 0) {
                if ($waiver -and $bot.red -le [int](Get-HarnessProp $waiver 'red') -and $bot.important -le [int](Get-HarnessProp $waiver 'important')) {
                    $warn.Add("Footer red=$($bot.red) important=$($bot.important), a user waiver for this head exists: $(Get-HarnessProp $waiver 'note')")
                    & $rely 'waiver' $waiver
                } else { $fail.Add("Footer red=$($bot.red) important=$($bot.important) must be 0 (or a user waiver for this head)") }
            }
        }
    }

    # 3. the summary is bound to that bot run: the link points at the review workflow, the run reviewed the current head and succeeded,
    #    the claude-pr-review check points at the same run, the comment was posted during the run. Any workflow can comment as
    #    github-actions[bot], so the author alone proves nothing.
    $botCheck = if ($Facts.Checks.ContainsKey((Get-HarnessBotCheck))) { $Facts.Checks[(Get-HarnessBotCheck)] } else { $null }
    if ($bot) {
        $run = $Facts.Run
        if (-not $bot.runId) { $fail.Add('The bot summary has no run link') }
        elseif (-not $run) { $fail.Add("The run $($bot.runId) the bot summary refers to cannot be fetched") }
        else {
            if (-not (Test-HarnessSameText $run.path (Get-HarnessReviewWorkflow))) { $fail.Add("The run the bot summary refers to is not the review workflow: $($run.path)") }
            if ($run.conclusion -ne 'success') { $fail.Add("The bot run concluded $($run.conclusion)") }
            if ($run.event -ne 'pull_request' -or $run.head_sha -ne $sha) { $fail.Add('The bot run did not review the current head') }
            $botJob = @($Facts.Jobs | Where-Object { $_.name -eq (Get-HarnessBotCheck) }) | Select-Object -First 1
            if (-not $botJob -or $botJob.conclusion -ne 'success') { $fail.Add("The $(Get-HarnessBotCheck) job of the bot run did not succeed") }
            if (-not $botCheck -or $botCheck.conclusion -ne 'success' -or [string]$botCheck.details_url -notmatch "/runs/$($bot.runId)/") {
                $fail.Add("The $(Get-HarnessBotCheck) check on the current head is not the run the summary refers to, or it did not succeed")
            }
            $created = ConvertTo-HarnessUtc $bot.createdAt
            if ($created -lt (ConvertTo-HarnessUtc $run.run_started_at) -or $created -gt (ConvertTo-HarnessUtc $run.updated_at).AddMinutes(1)) {
                $fail.Add('The bot summary was not posted during that run')
            }
            # the bot printed the comment id and the body sha256 of its post into the run log: a match proves the comment was not edited.
            # An older run without that line, an expired or unreachable log degrades to updated_at only, and says so
            if ($Facts.Posted) {
                if ([string]$Facts.Posted.Id -ne [string]$bot.id -or [string]$Facts.Posted.Sha256 -ne [string]$bot.sha256) {
                    # escape hatch: if GitHub rewrites the body it hands back (line endings, Unicode) every PR mismatches; a user waiver
                    # with "summaryHash": true for this head lets it pass, with a warning (the updated_at criterion is unaffected)
                    if ($waiver -and (Get-HarnessProp $waiver 'summaryHash') -is [bool] -and (Get-HarnessProp $waiver 'summaryHash')) {
                        $warn.Add("The comment id or body hash of the bot summary differs from the posted record; a user hash waiver for this head exists: $(Get-HarnessProp $waiver 'note')")
                        & $rely 'waiver' $waiver
                    } else {
                        $fail.Add('The comment id or body hash of the bot summary differs from the posted record in the run log (edited after posting)')
                    }
                }
            } elseif ($bot.ok) {
                $warn.Add("Hash not verified: the log of run $($bot.runId) has no posted record of the review bot (older run or log unavailable), only updated_at was checked")
            }
        }
    }

    # 4. disposition: one after the last bot summary, referencing that run; every earlier round's summary has one too
    $disposition = $Facts.State.disposition
    if (-not $disposition) { $fail.Add('There is no disposition after the last bot summary') }
    elseif ($bot -and $disposition.botRun -ne $bot.runId) { $fail.Add("The disposition refers to run $($disposition.botRun), not to run $($bot.runId) of the last bot summary") }
    foreach ($x in @($Facts.State.summaries)) {
        if ($x.runId -and @($Facts.State.dispositionRuns) -notcontains [string]$x.runId) { $fail.Add("The bot summary of run $($x.runId) has no disposition") }
    }
    foreach ($gap in @(Get-DispositionShortfalls -Summaries @($Facts.State.summaries) -Items @($Facts.Items))) { $fail.Add($gap) }

    # 5. threads and responses: open threads = 0; every bot and human comment is answered (against the original's updated_at, by in-reply-to);
    #    external comments go to the user; the ones the user dealt with (an external-handled record for this head names them and they were not edited since) pass
    $open = @($Facts.Threads | Where-Object { -not $_.isResolved }).Count
    if ($open -gt 0) { $fail.Add("$open review thread(s) are not resolved") }
    $handled = Get-HeadRecord $recs.ExternalHandled $sha
    foreach ($item in @($Facts.Items)) {
        if ($item.Kind -eq 'external') {
            if ($handled -and (Test-HandledComment $handled $item)) {
                $warn.Add("External comment $($item.Source) $($item.Id) was handled by the user: $(Get-HarnessProp $handled 'note')")
                & $rely 'external-handled' $handled
            } elseif ($handled -and @(Get-HarnessProp $handled 'comments' | Where-Object { [string](Get-HarnessProp $_ 'id') -eq $item.Id }).Count) {
                & $need 'user' 'external' "External comment $($item.Source) $($item.Id) ($($item.Author)) was edited after the user handled it (updated_at is now $($item.Updated))"
            } else { & $need 'user' 'external' "External comment $($item.Source) $($item.Id) ($($item.Author), updated_at=$($item.Updated))" }
            continue
        }
        if (-not (Test-HarnessResponded -Item $item -Items $Facts.Items -State $Facts.State)) { $fail.Add("Comment without a response: $($item.Source) $($item.Id) ($($item.Kind))") }
    }
    $deferred = @(Get-DeferredSevere $Facts.Items)
    if ($deferred.Count -gt 0) {
        if ($waiver -and (Get-HarnessProp $waiver 'deferred') -is [bool] -and (Get-HarnessProp $waiver 'deferred')) { & $rely 'waiver' $waiver }
        else { & $need 'user' 'deferred' "$($deferred.Count) severe finding(s) are not shown as handled in the newest disposition (the 处置 cell must start with 已修, 修复 or 采纳, hold no refusal word and have a commit hash with a letter and a digit: a short hash of only digits or only letters reads as an id or a word, write it longer); only the user can waive them" }
    }

    # 6. CI: the required checks are success on the current head; pr-agent is not required, but when this head already has that
    #    check it must have finished (any conclusion: it only comments)
    foreach ($context in @($Facts.Required)) {
        $c = if ($Facts.Checks.ContainsKey($context)) { $Facts.Checks[$context] } else { $null }
        if (-not $c -or $c.conclusion -ne 'success') { $fail.Add("Check $context is not success on the current head") }
    }
    $prAgentCheck = Get-HarnessPrAgentCheck
    if ($Facts.Checks.ContainsKey($prAgentCheck) -and $Facts.Checks[$prAgentCheck].status -ne 'completed') {
        $fail.Add("Check $prAgentCheck has not finished on the current head (any conclusion, completed is enough)")
    }

    # 7. rescan of the public text: the PR title and body (format, privacy, AI attribution, last-line sign-off) and every comment of ours
    foreach ($problem in @(Get-PrTextErrors -Title ([string]$pull.title) -Body ([string](Get-HarnessProp $pull 'body')))) { $fail.Add("PR title or body: $problem") }
    $ours = @($Facts.Items | Where-Object Kind -eq 'agent')
    $titleScan = Test-PublicText "$($pull.title)`n$([string](Get-HarnessProp $pull 'body'))"
    if (-not $titleScan.Ok) { $fail.Add("The PR title or body failed the public-text check: $($titleScan.Findings -join '; ')") }
    foreach ($mine in $ours) {
        $scan = Test-PublicText $mine.Body
        if (-not $scan.Ok) { $fail.Add("Our comment $($mine.Id) failed the public-text check: $($scan.Findings -join '; ')") }
    }

    # 8. infrastructure paths (list: scripts/lib/infra-paths.mjs, read from this checkout on the target line): every path counts, a rename
    #    counts old and new name; only an approval record for this head lets it through
    $infra = @(Get-InfraTouches -Files $Facts.Files)
    $approval = Get-HeadRecord $recs.Approvals $sha
    if ($infra.Count -gt 0) {
        if ($approval) { $warn.Add("Touches infrastructure paths, the user approved this head: $(Get-HarnessProp $approval 'note')"); & $rely 'approval' $approval }
        else { & $need 'user' 'infra' "Touches infrastructure paths, for the user to approve (register an approval record for head $sha): $($infra -join ', ')" }
    }

    $code = if ($fail.Count) { 'not-ready' } elseif ($needs.Count) { 'needs-user' } else { 'ready' }
    [pscustomobject]@{
        Code = $code; Pr = $Facts.Pr; Head = $sha
        Failures = $fail.ToArray(); Needs = $needs.ToArray(); Warnings = $warn.ToArray(); ReliedOn = $relied.ToArray()
        Infra = $infra; Deferred = $deferred
        Command = "pwsh scripts/maintainer/pr-merge.ps1 -Merge -Pr $($Facts.Pr) -SummaryFile <summary file>"
    }
}

function Invoke-MergeCheck {
    param([Parameter(Mandatory)][int]$Number, [string]$RecordsPath)
    Get-MergeVerdict (Get-MergeFacts -Number $Number -RecordsPath $RecordsPath)
}

function Get-CheckExitCode {
    param([Parameter(Mandatory)][string]$Outcome)
    switch ($Outcome) { 'ready' { 0 } 'needs-user' { 2 } default { 1 } }
}

# ---- the squash commit ----------------------------------------------------------------------

<# Squash message: subject "<PR title> (#n)", the summary paragraph, a blank line, the one sign-off line; all through the message rules of scripts/check-commits.mjs (which include the privacy rules). #>
function New-MergeMessage {
    param([Parameter(Mandatory)]$PrData, [Parameter(Mandatory)][string]$Summary)
    # the read-back compares with LF line endings, and that is what GitHub stores
    $text = ($Summary -replace "`r`n", "`n").Trim()
    if (-not $text) { throw 'The summary paragraph is empty' }
    $title = "$($PrData.title) (#$($PrData.number))"
    $full = "$title`n`n$text`n`n$(Get-HarnessSignoff)"
    # the script adds the only sign-off, so a trailer of the summary shows up as a second one (or as an AI attribution)
    $checked = Get-HarnessMessageCheck $full -ExactlyOne
    $problems = @($checked.errors)
    if ($problems.Count) { throw "The squash message failed the message rules (the summary paragraph carries no trailers, the script adds the sign-off): $($problems -join '; ')" }
    # what goes out is what the rules read: the message without invisible characters, for good in the history of the line
    $sentParts = $checked.text -split "`n`n", 2
    $sentBody = $sentParts[1].Trim()
    if (Test-HarnessSameText $sentBody (Get-HarnessSignoff)) { throw 'The summary paragraph is empty' }
    @{ Title = $sentParts[0]; Body = $sentBody }
}

<# What a squash commit on the feature line must look like (same-repo tier): author, committer, one sign-off, subject ending in (#n), public text. #>
function Get-SquashProblems {
    param(
        [Parameter(Mandatory)][string]$Number, [Parameter(Mandatory)][string]$AuthorName, [Parameter(Mandatory)][string]$AuthorEmail,
        [Parameter(Mandatory)][string]$CommitterEmail, [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    # GitHub writes the web-flow squash as the account's numbered noreply address; the allow list of scripts/check-commits.mjs is the only copy
    if (-not (Test-HarnessSameText $AuthorName (Get-HarnessMaintainer)) -or -not (Test-HarnessTextIn $AuthorEmail.ToLowerInvariant() @(Get-HarnessSameAuthors))) { $problems.Add("author is $AuthorName <$AuthorEmail>, not the maintainer") }
    if (-not (Test-HarnessTextIn $CommitterEmail.ToLowerInvariant() $AllowedCommitters)) { $problems.Add("committer email $CommitterEmail is not allowed") }
    if ((($Message -replace "`r`n", "`n") -split "`n")[0] -notmatch "\(#$Number\)$") { $problems.Add("the subject does not end with (#$Number)") }
    # a message the tools refuse to read (a control character) is one more problem: after a merge the report must still name the commit
    try {
        foreach ($e in @(Get-MessageErrors $Message -ExactlyOne)) { $problems.Add($e) }
        $scan = Test-PublicText $Message
        if (-not $scan.Ok) { $problems.Add("the message failed the public-text check: $($scan.Findings -join '; ')") }
    } catch { $problems.Add("the message could not be checked: $($_.Exception.Message)") }
    $problems.ToArray()
}

function Invoke-MergeUnlocked {
    param([int]$Number, [string]$SummaryFile, [string]$RecordsPath)
    if (-not $SummaryFile -or -not (Test-Path -LiteralPath $SummaryFile -PathType Leaf)) { throw '-Merge needs -SummaryFile (the summary paragraph of the squash commit)' }
    $slug = Get-HarnessRepo
    # the squash message is built and checked first (it runs Node); after the check only API reads and the merge request remain
    $pull = Get-HarnessApi "repos/$slug/pulls/$Number"
    $msg = New-MergeMessage -PrData $pull -Summary (Read-HarnessBodyFile -Path $SummaryFile -Parameter '-SummaryFile')
    $verdict = Invoke-MergeCheck -Number $Number -RecordsPath $RecordsPath
    if ($verdict.Code -ne 'ready') {
        Write-Output (ConvertTo-HarnessJsonText $verdict)
        throw "Cannot merge: code=$($verdict.Code)"
    }
    $now = Get-HarnessApi "repos/$slug/pulls/$Number"
    if ($now.head.sha -ne $verdict.Head -or $pull.head.sha -ne $verdict.Head) { throw 'The PR head moved after the check; check again' }
    if (-not (Test-HarnessSameText $now.base.ref 'feature/v1') -or -not (Test-HarnessSameText $now.state 'open')) { throw "The PR changed after the check (base $($now.base.ref), state $($now.state)); check again" }
    if (-not (Test-HarnessSameText $now.title $pull.title)) { throw 'The PR title changed after the squash message was built; check again' }
    foreach ($x in @($verdict.ReliedOn)) { Write-Output "User record relied on ($($x.Kind), verbatim, from $($x.File)): $(ConvertTo-HarnessJsonText $x.Record)" }
    # sha pins the checked head: a push in between makes GitHub refuse the merge (the approval records are valid for this head only too)
    $request = @{ merge_method = 'squash'; sha = $verdict.Head; commit_title = $msg.Title; commit_message = $msg.Body }
    $res = Invoke-HarnessApiWrite -Method PUT -Path "repos/$slug/pulls/$Number/merge" -Body $request
    if (-not $res.merged) { throw "The merge did not succeed: $($res.message)" }
    # read the merge commit back: title, body and author are what was asked for
    $commit = Get-HarnessApi "repos/$slug/commits/$($res.sha)"
    $expected = ("$($msg.Title)`n`n$($msg.Body)").TrimEnd()
    $problems = [System.Collections.Generic.List[string]]::new()
    $actual = (([string]$commit.commit.message) -replace "`r`n", "`n").TrimEnd()
    if (-not (Test-HarnessSameText $actual $expected)) { $problems.Add('title or body of the merge commit differ from what was sent') }
    foreach ($p in @(Get-SquashProblems -Number ([string]$Number) -AuthorName ([string]$commit.commit.author.name) -AuthorEmail ([string]$commit.commit.author.email) `
                -CommitterEmail ([string]$commit.commit.committer.email) -Message $actual)) { $problems.Add($p) }
    if ($problems.Count) { throw "#$Number was merged as $($res.sha), but the read-back found problems (nothing is retried): $($problems -join '; ')" }
    "Merged #$Number -> $($res.sha)"
}

# ---- after the merge ------------------------------------------------------------------------

<# The final path of a directory; the path itself when it is gone. #>
function Get-RealDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $id = Get-PathIdentity $Path
    ($id ? $id.Final : [IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
}

<# A directory -After may remove at all: absolute and local, not itself a link, not the main checkout, not a drive root or the home directory. Anything else throws and nothing is touched. #>
function Assert-RemovablePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$MainRoot)
    $refuse = { param($why) throw "Refusing to remove ${Path}: $why" }
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path -match '^[\\/]{2}') { & $refuse 'it is not an absolute local path' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { & $refuse 'it is not an existing directory' }
    if ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) { & $refuse 'it is a link (junction or symlink), not a worktree directory' }
    $final = Get-RealDirectory $Path
    if ($final -ieq (Get-RealDirectory $MainRoot)) { & $refuse 'it is the main checkout of this repository' }
    if ([IO.Path]::GetPathRoot($final).TrimEnd('\', '/') -ieq $final) { & $refuse 'it is a drive root' }
    $homeDir = [Environment]::GetFolderPath('UserProfile')
    if ($homeDir -and $final -ieq (Get-RealDirectory $homeDir)) { & $refuse 'it is the home directory' }
}

<#
  git worktree remove deletes the directory with everything untracked in it, so before it runs the path has to be a directory -After may
  remove, its final path a worktree registered in this repository and its .git a file (the worktree marker).
#>
function Assert-WorktreeDir {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$MainRoot, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$KnownTrees)
    Assert-RemovablePath -Path $Path -MainRoot $MainRoot
    $refuse = { param($why) throw "Refusing to remove ${Path}: $why" }
    $known = @($KnownTrees | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-RealDirectory $_ })
    if ($known -inotcontains (Get-RealDirectory $Path)) { & $refuse 'it is not a worktree registered in this repository (git worktree list); what an earlier run left behind is only taken along when it holds no file' }
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git') -PathType Leaf)) { & $refuse 'its .git is not a file, it does not look like a worktree' }
}

<#
  What git leaves when it removed the registration and could not remove the directory (another process had it open): a directory that is
  not registered and holds no file and no link, only empty directories. Then there is nothing in it to look at and nothing to lose.
#>
function Test-WorktreeLeftover {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$MainRoot, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$KnownTrees)
    Assert-RemovablePath -Path $Path -MainRoot $MainRoot
    if (@($KnownTrees | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-RealDirectory $_ }) -icontains (Get-RealDirectory $Path)) { return $false }
    @(Get-ChildItem -LiteralPath $Path -Force -Recurse | Where-Object { -not $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | Select-Object -First 1).Count -eq 0
}

<# Removes that leftover, deepest directory first and never recursively: a file that appeared in the meantime makes it fail and stays. #>
function Remove-WorktreeLeftover {
    param([Parameter(Mandatory)][string]$Path)
    try {
        foreach ($directory in @(Get-ChildItem -LiteralPath $Path -Force -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending)) { [IO.Directory]::Delete($directory.FullName) }
        [IO.Directory]::Delete($Path)
    } catch { throw "$Path could not be removed (is it still in use?), nothing else is cleaned up: $($_.Exception.Message)" }
}

<# Why git worktree remove would fail on this worktree: a lock, or the current directory of this process inside it (Windows keeps that open). Returns the reason, or $null. #>
function Get-WorktreeRemovalBlock {
    param([Parameter(Mandatory)][string]$Path)
    $final = Get-RealDirectory $Path
    $blocks = (Invoke-HarnessGit @('worktree', 'list', '--porcelain')).Out -split "`r?`n`r?`n"
    foreach ($block in $blocks) {
        $listed = [regex]::Match($block, '(?m)^worktree (.+?)\r?$')
        if ($listed.Success -and (Get-RealDirectory $listed.Groups[1].Value) -ieq $final -and $block -cmatch '(?m)^locked(?: .*)?\r?$') { return 'it is locked (git worktree unlock clears that)' }
    }
    foreach ($current in @((Get-Location -PSProvider FileSystem).ProviderPath, [Environment]::CurrentDirectory)) {
        $here = Get-RealDirectory $current
        if ($here -ieq $final -or $here.StartsWith($final + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return "the current directory $current is inside it (change to another directory first)" }
    }
    $null
}

<# Where a branch is checked out, by git worktree list --porcelain: the paths, registered ones whose directory is gone included. #>
function Get-BranchCheckouts {
    param([Parameter(Mandatory)][string]$Ref)
    $blocks = (Invoke-HarnessGit @('worktree', 'list', '--porcelain')).Out -split "`r?`n`r?`n"
    @($blocks | Where-Object { $_ -cmatch "(?m)^branch $([regex]::Escape($Ref))\r?$" } | ForEach-Object { [IO.Path]::GetFullPath(([regex]::Match($_, '(?m)^worktree (.+?)\r?$')).Groups[1].Value) })
}

function Invoke-AfterUnlocked {
    param([int]$Number, [string]$WorktreePath)
    if (-not $WorktreePath) { throw '-After needs -Worktree <path> (the worktree of this sub-branch; only that one is removed)' }
    $slug = Get-HarnessRepo
    $pull = Get-HarnessApi "repos/$slug/pulls/$Number"
    if (-not $pull.merged) { throw "#$Number is not merged yet" }
    $sha = [string]$pull.merge_commit_sha
    $branch = [string]$pull.head.ref
    if ($branch -cnotmatch '^feat/[a-z0-9][a-z0-9-]*$') { throw "Not a sub-branch name: $branch" }
    Invoke-HarnessGitLocked { Invoke-HarnessGit @('fetch', '--no-tags', 'origin', '+refs/heads/feature/v1:refs/remotes/origin/feature/v1') | Out-Null } | Out-Null
    if ((Invoke-HarnessGit @('merge-base', '--is-ancestor', $sha, 'origin/feature/v1') -AllowFail).Code -ne 0) { throw "$sha is not on origin/feature/v1" }
    # read back: author and committer, exactly one maintainer sign-off, the subject carries (#n)
    $sep = [string][char]0x1f
    $raw = (Invoke-HarnessGit @('log', '-1', "--format=%an$sep%ae$sep%ce$sep%B", $sha)).Out
    $f = $raw -split $sep, 4
    if ($f.Count -ne 4) { throw "Could not read back the commit $sha" }
    $problems = @(Get-SquashProblems -Number ([string]$Number) -AuthorName $f[0] -AuthorEmail $f[1] -CommitterEmail $f[2] -Message $f[3].TrimEnd())
    if ($problems.Count) { throw "The squash commit failed the read-back: $($problems -join '; ')" }
    # the worktree must be on this very sub-branch, so a wrong path cannot remove another work area
    $registered = @(Get-RegisteredWorktrees)
    $present = Test-Path -LiteralPath $WorktreePath
    $leftover = $present -and (Test-WorktreeLeftover -Path $WorktreePath -MainRoot (Get-HarnessRepoRoot) -KnownTrees $registered)
    if ($present -and -not $leftover) {
        Assert-WorktreeDir -Path $WorktreePath -MainRoot (Get-HarnessRepoRoot) -KnownTrees $registered
        $current = (Invoke-HarnessGit @('symbolic-ref', '--quiet', '--short', 'HEAD') -Repo $WorktreePath -AllowFail).Out.Trim()
        if ($current -ne $branch) { throw "$WorktreePath is on branch '$current', not on $branch of #${Number}: wrong path, nothing is cleaned up" }
    }
    # everything is compared before anything is deleted: a tip other than the merged head holds commits the merge does not have
    $mergedHead = [string]$pull.head.sha
    $branchRef = "refs/heads/$branch"
    # ls-remote --exit-code: 0 found, 2 no such ref; anything else (no network, no access) says nothing about the branch
    $remoteRead = Invoke-HarnessGit @('ls-remote', '--exit-code', '--heads', 'origin', $branchRef) -AllowFail
    $remoteTip = $null
    if ($remoteRead.Code -eq 0) {
        $tipLine = [regex]::Match($remoteRead.Out, "(?m)^([0-9a-f]{40})\t$([regex]::Escape($branchRef))\r?$")
        if (-not $tipLine.Success) { throw "git ls-remote did not name ${branchRef}, nothing is cleaned up: $($remoteRead.Out)" }
        $remoteTip = $tipLine.Groups[1].Value
    } elseif ($remoteRead.Code -ne 2) { throw "git ls-remote origin failed (exit code $($remoteRead.Code)), nothing is cleaned up: $($remoteRead.Err.Trim())" }
    if ($remoteTip -and $remoteTip -cne $mergedHead) { throw "The remote $branch is at $remoteTip, not at the head $mergedHead of #${Number} that was merged: nothing is cleaned up" }
    # rev-parse --verify --quiet: 0 found, 1 no such branch
    $localRead = Invoke-HarnessGit @('rev-parse', '--verify', '--quiet', $branchRef) -AllowFail
    $localTip = $null
    if ($localRead.Code -eq 0) { $localTip = $localRead.Out.Trim() }
    elseif ($localRead.Code -ne 1) { throw "git rev-parse failed (exit code $($localRead.Code)), nothing is cleaned up: $($localRead.Err.Trim())" }
    if ($localTip -and $localTip -cne $mergedHead) { throw "The local $branch is at $localTip, not at the head $mergedHead of #${Number} that was merged: nothing is cleaned up" }
    # git keeps a branch to one worktree. Checked out anywhere but here its changes are never looked at, and in either of these cases
    # git branch -D refuses after the remote branch is already gone
    foreach ($checkout in @(Get-BranchCheckouts $branchRef)) {
        if (-not (Test-Path -LiteralPath $checkout)) { throw "$branch is registered as checked out at $checkout, whose directory is gone (git worktree prune clears that): nothing is cleaned up" }
        if ((Get-RealDirectory $checkout) -ine (Get-RealDirectory $WorktreePath)) { throw "$branch is checked out at $checkout, not at ${WorktreePath}: nothing is cleaned up" }
    }
    $ignoredPaths = @()
    if ($present) {
        # both would make git worktree remove fail with the remote branch already gone
        $blocked = Get-WorktreeRemovalBlock $WorktreePath
        if ($blocked) { throw "$WorktreePath cannot be removed, nothing is cleaned up: $blocked" }
    }
    if ($present -and -not $leftover) {
        $statusLines = @(((Invoke-HarnessGit @('status', '--porcelain', '--untracked-files=normal', '--ignored') -Repo $WorktreePath).Out -split "`r?`n") | Where-Object { $_ })
        $untidy = @($statusLines | Where-Object { $_ -cnotmatch '^!! ' })
        if ($untidy.Count) { throw "$WorktreePath has changes or untracked files, nothing is cleaned up: $($untidy -join '; ')" }
        # git worktree remove takes ignored files along, so they are at least named
        $ignoredPaths = @($statusLines | ForEach-Object { $_.Substring(3) })
    }
    # what an earlier run left goes first: when it is still held open nothing else has changed
    if ($leftover) { Remove-WorktreeLeftover $WorktreePath }
    # delete the remote sub-branch (the pre-push hook lets feat/* deletions through), then remove the worktree and the local branch under the git lock
    if ($remoteTip) { Invoke-HarnessGit @('push', 'origin', '--delete', $branchRef) | Out-Null }
    Invoke-HarnessGitLocked {
        # the plain remove: no --force, git itself still refuses a worktree that changed in the meantime
        if ($present -and -not $leftover) { Invoke-HarnessGit @('worktree', 'remove', $WorktreePath) | Out-Null }
        if ($localTip) { Invoke-HarnessGit @('branch', '-D', $branch) | Out-Null }
    } | Out-Null
    $what = { param($there, $doneWord) if ($there) { $doneWord } else { 'was already gone' } }
    "#$Number merged as $($sha.Substring(0, 7)) '$($pull.title)'; read-back passed, remote sub-branch $(& $what $remoteTip 'deleted'), worktree $(if ($leftover) { 'was already unregistered, its empty directory removed' } else { & $what $present 'removed' }), local branch $(& $what $localTip 'removed')$(if ($ignoredPaths.Count) { "; ignored files removed with the worktree: $(@($ignoredPaths | Select-Object -First 20) -join ', ')$(if ($ignoredPaths.Count -gt 20) { ', ...' })" })"
}

<# -Merge and -After hold the merge lock for their whole run: one merge at a time on this machine. #>
function Invoke-Merge {
    param([int]$Number, [string]$SummaryFile, [string]$RecordsPath)
    Invoke-HarnessMergeLocked { Invoke-MergeUnlocked -Number $Number -SummaryFile $SummaryFile -RecordsPath $RecordsPath }
}

function Invoke-After {
    param([int]$Number, [string]$WorktreePath)
    Invoke-HarnessMergeLocked { Invoke-AfterUnlocked -Number $Number -WorktreePath $WorktreePath }
}

# ---- the command line -----------------------------------------------------------------------

$script:EntryCode = 0

<# The arguments first, then the identity, and only then anything that reads or writes on GitHub. The exit code is left in $script:EntryCode. #>
function Invoke-Entry {
    [CmdletBinding()]
    param([switch]$Check, [switch]$Merge, [switch]$After, [int]$Pr, [string]$SummaryFile, [string]$Worktree, [string]$WaiverFile)
    $script:EntryCode = 0
    if (@($Check, $Merge, $After | Where-Object { $_ }).Count -ne 1) { throw 'Usage: -Check | -Merge | -After, exactly one (or -SelfTest)' }
    if ($Pr -le 0) { throw '-Pr <n> is required' }
    Initialize-HarnessIdentity
    if ($Check) {
        $verdict = Invoke-MergeCheck -Number $Pr -RecordsPath $WaiverFile
        Write-Output (ConvertTo-HarnessJsonText $verdict)
        $script:EntryCode = Get-CheckExitCode $verdict.Code
        return
    }
    if ($Merge) {
        Invoke-Merge -Number $Pr -SummaryFile $SummaryFile -RecordsPath $WaiverFile
        return
    }
    Invoke-After -Number $Pr -WorktreePath $Worktree
}

# ---- self-test ------------------------------------------------------------------------------

function Invoke-SelfTest {
    $cases = New-HarnessCases
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "harness-merge-selftest-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $away = $null
    $messageOf = { param($block) try { & $block | Out-Null; $null } catch { if ($env:HARNESS_SELFTEST_VERBOSE) { [Console]::Error.WriteLine("  thrown: $($_.Exception.Message)") }; $_.Exception.Message } }
    try {
        # the repository's own privacy tool, message rules and infrastructure list run for real, with a needle file of the self-test
        New-HarnessSelfTestNeedles -Directory $tmp | Out-Null
        # ---- records file location --------------------------------------------------------------
        $fakeClone = Join-Path $tmp 'clone'
        $workDir = Join-Path $tmp 'wt'
        $outside = Join-Path $tmp 'outside'
        $elsewhere = Join-Path $tmp 'elsewhere'
        New-Item -ItemType Directory -Force -Path $fakeClone, $workDir, $outside, $elsewhere | Out-Null
        $roots = @($fakeClone, $workDir)
        $recordsFile = Join-Path $elsewhere 'waivers.json'
        Set-Content -LiteralPath $recordsFile -Value '{}'
        # an exception is no answer: the case that asked turns red under its own name
        $locate = { param($p) try { @(Test-RecordsLocation -Path $p -ExcludedRoots $roots) } catch { @("threw: $($_.Exception.Message)") } }
        $hit = { param($found, $word) @($found | Where-Object { $_ -match $word }).Count -eq 1 }
        Add-HarnessCase $cases 'records location: a file outside the repository and the worktrees' $false (@(& $locate $recordsFile).Count -ne 0)
        Add-HarnessCase $cases 'records location: a relative path' $true (& $hit (& $locate 'waivers.json') 'absolute path')
        Add-HarnessCase $cases 'records location: drive-relative and root-relative spellings' $true ((& $hit (& $locate 'C:waivers.json') 'absolute path') -and (& $hit (& $locate '\waivers.json') 'absolute path'))
        Add-HarnessCase $cases 'records location: the file does not exist' $true (& $hit (& $locate (Join-Path $tmp 'missing.json')) 'existing file')
        Set-Content -LiteralPath (Join-Path $workDir 'waivers.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $fakeClone 'waivers.json') -Value '{}'
        Add-HarnessCase $cases 'records location: a file under a worktree directory' $true (& $hit (& $locate (Join-Path $workDir 'waivers.json')) 'outside the repository')
        Add-HarnessCase $cases 'records location: a file inside the repository' $true (& $hit (& $locate (Join-Path $fakeClone 'waivers.json')) 'outside the repository')
        foreach ($odd in '\\?\C:\x\waivers.json', '\\server\share\waivers.json', '//server/share/waivers.json') {
            Add-HarnessCase $cases "records location: device or UNC spelling ($($odd.Substring(0, 4))...)" $true (& $hit (& $locate $odd) 'device path or a UNC')
        }
        Add-HarnessCase $cases 'records location: the final path is on a share (a drive letter that aliases a share)' $true (
            (& $hit @(Test-RecordsLocation -Path $recordsFile -ExcludedRoots $roots -IdentityOf { param($p) [pscustomobject]@{ Final = '\\srv\share\waivers.json'; Links = 1 } }) 'not on a local volume'))
        Add-HarnessCase $cases 'records location: more than one hard link (seam)' $true (
            (& $hit @(Test-RecordsLocation -Path $recordsFile -ExcludedRoots $roots -IdentityOf { param($p) [pscustomobject]@{ Final = $p; Links = 2 } }) 'hard links'))
        if ($IsWindows) {
            New-Item -ItemType Junction -Path (Join-Path $outside 'j') -Target $workDir | Out-Null
            New-Item -ItemType Junction -Path (Join-Path $outside 'k') -Target $elsewhere | Out-Null
            New-Item -ItemType HardLink -Path (Join-Path $outside 'hard.json') -Target (Join-Path $workDir 'waivers.json') | Out-Null
            Add-HarnessCase $cases 'records location: through a junction into a worktree directory' $true (@(& $locate (Join-Path $outside 'j/waivers.json')).Count -ge 1)
            Add-HarnessCase $cases 'records location: a junction on the path is refused even when it points elsewhere' $true (& $hit (& $locate (Join-Path $outside 'k/waivers.json')) 'reparse point')
            Add-HarnessCase $cases 'records location: a hard link to a file inside a worktree directory' $true (& $hit (& $locate (Join-Path $outside 'hard.json')) 'hard links')
            # the worktree directory itself reached through a junction: the root is compared by its final path
            $realWork = Join-Path $tmp 'realwork'
            New-Item -ItemType Directory -Force -Path $realWork | Out-Null
            Set-Content -LiteralPath (Join-Path $realWork 'waivers.json') -Value '{}'
            New-Item -ItemType Junction -Path (Join-Path $tmp 'worklink') -Target $realWork | Out-Null
            Add-HarnessCase $cases 'records location: the worktree directory is a junction, a file in its target is still recognised' $true (
                (& $hit @(Test-RecordsLocation -Path (Join-Path $realWork 'waivers.json') -ExcludedRoots @($fakeClone, (Join-Path $tmp 'worklink'))) 'outside the repository'))
            foreach ($link in 'j', 'k') { [IO.Directory]::Delete((Join-Path $outside $link)) }
            [IO.Directory]::Delete((Join-Path $tmp 'worklink'))
        }
        Add-HarnessCase $cases 'PowerShell older than 7.5 is refused (-DateKind)' $true (-not (Test-HarnessPwshVersion 7 4))
        Add-HarnessCase $cases 'PowerShell 7.5 and later run' $false (-not ((Test-HarnessPwshVersion 7 5) -and (Test-HarnessPwshVersion 8 0)))
        Add-HarnessCase $cases 'exit codes: ready 0, needs-user 2, not-ready 1' $false (-not ((Get-CheckExitCode 'ready') -eq 0 -and (Get-CheckExitCode 'needs-user') -eq 2 -and (Get-CheckExitCode 'not-ready') -eq 1))

        # ---- the recorded PR -------------------------------------------------------------------
        Clear-HarnessPermCache
        $pull = Read-HarnessFixture 'pull.json'
        $headSha = $pull.head.sha
        $tipSha = 'c' * 40
        $prFiles = Read-HarnessFixture 'files.json'
        $summaryFixture = (Read-HarnessFixture 'issue-comments.json') | Where-Object { [string]$_.id -eq '9000000001' } | Select-Object -First 1
        $summaryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(([string]$summaryFixture.body -replace "`r`n", "`n")))).ToLowerInvariant()
        $runLog = @{ Text = "claude-pr-review`tPost the review summary`t2026-11-01T10:02:10.0000000Z harness-review-posted id=$($summaryFixture.id) sha256=$summaryHash" }
        $log = [System.Collections.Generic.List[string]]::new()
        $pullState = @{ Nulls = 0 }
        $prFixture = $pull
        $clone = @{ Head = $tipSha; Tip = $tipSha; Dirty = $false; HooksPath = 'scripts/hooks'; PrRef = $headSha }
        $identity = @{ Login = 'DLsnows' }
        $savedToken = $env:GH_TOKEN
        # what the routes answer can be changed per case: the commands decide, not an edited copy of the facts
        $answers = @{ Checks = Read-HarnessFixture 'check-runs.json'; Jobs = Read-HarnessFixture 'run-jobs.json'; PrNumber = 7 }
        $wrongJobLog = "other-job`tstep`t2026-11-01T10:02:10.0000000Z harness-review-posted id=1 sha256=$('0' * 64)"
        $worktreeText = { "worktree $($fakeClone -replace '\\', '/')`nHEAD $tipSha`nbranch refs/heads/feature/v1`n`nworktree $($workDir -replace '\\', '/')/example`nHEAD $headSha`nbranch refs/heads/feat/example" }
        $lockLog = [System.Collections.Generic.List[string]]::new()
        $routes = [ordered]@{
            '^gh auth token --user DLsnows$'   = { 'tok-selftest' }
            '^gh api user --jq \.login$'       = { $identity.Login }
            'collaborators/DLsnows/permission' = { 'admin' }
            'collaborators/[^/]+/permission'   = { @{ Code = 0; Out = 'read'; Err = '' } }
            'pulls/7/files'                    = { $prFiles }
            'pulls/7/comments'                 = { Read-HarnessFixture 'review-comments.json' }
            'pulls/7/reviews'                  = { Read-HarnessFixture 'reviews.json' }
            'pulls/7$'                         = {
                if ($pullState.Nulls -gt 0) { $pullState.Nulls--; $p = Copy-HarnessObject $prFixture; $p.mergeable = $null; $p.mergeable_state = 'unknown'; return $p }
                $prFixture
            }
            'issues/7/comments'                = { Read-HarnessFixture 'issue-comments.json' }
            'api -X POST graphql'              = {
                param($argv)
                $request = Get-Content -Raw ($argv[-1]) | ConvertFrom-Json
                if ($request.variables.number -ne $answers.PrNumber) { return @{ Code = 1; Out = ''; Err = "GraphQL asked about PR $($request.variables.number)" } }
                if ($request.query -notmatch 'reviews\(') { return Read-HarnessFixture 'threads.json' }
                Read-HarnessFixture 'review-edits.json'
            }
            "actions/runs\?head_sha=$headSha&event=pull_request" = { Read-HarnessFixture 'pr-runs.json' }
            'actions/runs/5000000001/jobs'     = { $answers.Jobs }
            'actions/runs/5000000001$'         = { Read-HarnessFixture 'run.json' }
            '^gh run view 5000000001 --repo \S+ --log --job 5000000011$' = { $runLog.Text }
            # the log of another job, or of the whole run, holds a record that does not match: reading it is a failure
            '^gh run view 5000000001 --repo \S+ --log( --job \d+)?$' = { $wrongJobLog }
            "commits/$headSha/check-runs"      = { $answers.Checks }
            '^git .* fetch '                   = { '' }
            '^git .* rev-parse refs/remotes/origin/pr/7' = { $clone.PrRef }
            '^git .* rev-parse HEAD$'          = { $clone.Head }
            '^git .* rev-parse origin/feature/v1$' = { $clone.Tip }
            '^git .* status --porcelain$'      = { $(if ($clone.Dirty) { ' M x' } else { '' }) }
            '^git .* config --get core\.hooksPath$' = { $clone.HooksPath }
            '^git .* worktree list --porcelain$' = { & $worktreeText }
        }
        Set-HarnessFake (New-HarnessFake -Routes $routes -Log $log)
        Set-HarnessLockImpl { param($name, $block) $lockLog.Add($name); & $block }
        $MergeablePoll.Seconds = 0

        $baseError = $null
        try { $base = Get-MergeFacts -Number 7 -RecordsPath $recordsFile } catch { $baseError = $_.Exception.Message }
        Add-HarnessCase $cases 'the facts of a clean PR can be read' $false ([bool]$baseError)
        if ($baseError) { throw $baseError }
        $ready = Get-MergeVerdict $base
        Add-HarnessCase $cases 'a clean PR is ready' $false ($ready.Code -ne 'ready')
        if ($ready.Code -ne 'ready') { [Console]::Error.WriteLine((ConvertTo-HarnessJsonText $ready)) }
        Add-HarnessCase $cases 'facts: feature/v1 and the PR head were fetched' $false (-not ($log | Where-Object { $_ -match 'fetch --no-tags origin \+refs/heads/feature/v1:refs/remotes/origin/feature/v1 \+refs/pull/7/head:refs/remotes/origin/pr/7' }))
        Add-HarnessCase $cases 'no user record is used: ReliedOn is empty' $false (@($ready.ReliedOn).Count -gt 0)
        Add-HarnessCase $cases 'posted record matches: no "hash not verified" warning' $false (@($ready.Warnings | Where-Object { $_ -match 'Hash not verified' }).Count -gt 0)
        Add-HarnessCase $cases 'facts: the git fetch ran under the git lock' $false ($lockLog -notcontains 'git')

        $pullState.Nulls = 2
        $afterNulls = Get-MergeVerdict (Get-MergeFacts -Number 7)
        Add-HarnessCase $cases 'mergeable null first, then true: ready' $false (-not ($afterNulls.Code -eq 'ready' -and $pullState.Nulls -eq 0))
        $pullState.Nulls = 99
        $stuck = Get-MergeVerdict (Get-MergeFacts -Number 7)
        $pullState.Nulls = 0
        Add-HarnessCase $cases 'mergeable stays null: not mergeable' $true ($stuck.Code -eq 'not-ready' -and @($stuck.Failures | Where-Object { $_ -match 'not mergeable' }).Count -eq 1)

        # core.hooksPath is read from the checkout (relative and absolute spellings alike)
        $clone.HooksPath = '.git/hooks'
        $hooksOff = Get-MergeVerdict (Get-MergeFacts -Number 7)
        $clone.HooksPath = ((Get-HarnessRepoRoot) -replace '\\', '/') + '/scripts/hooks'
        $hooksAbsolute = Get-MergeVerdict (Get-MergeFacts -Number 7)
        $clone.HooksPath = 'scripts/hooks'
        Add-HarnessCase $cases 'facts: core.hooksPath of the checkout is read, another directory is not-ready' $true ($hooksOff.Code -eq 'not-ready' -and @($hooksOff.Failures | Where-Object { $_ -match "core\.hooksPath is '\.git/hooks'" }).Count -eq 1)
        Add-HarnessCase $cases 'facts: core.hooksPath written as the absolute path of this checkout is ready' $false ($hooksAbsolute.Code -ne 'ready')

        # the facts layer: the answers of the commands decide (the routes change, not a copy of the facts)
        $factsVerdict = { Get-MergeVerdict (Get-MergeFacts -Number 7) }
        $failedWith = { param($r, $word) $r.Code -eq 'not-ready' -and @($r.Failures | Where-Object { $_ -match $word }).Count -ge 1 }
        $clone.Dirty = $true
        $routeDirty = & $factsVerdict
        $clone.Dirty = $false
        Add-HarnessCase $cases 'facts: git status of the checkout reports a change' $true (& $failedWith $routeDirty 'uncommitted changes')
        $clone.Head = 'd' * 40
        $routeHead = & $factsVerdict
        $clone.Head = $tipSha
        Add-HarnessCase $cases 'facts: HEAD of the checkout is not the fetched feature line' $true (& $failedWith $routeHead 'not on the freshly fetched')
        $clone.Tip = 'e' * 40
        $routeTip = & $factsVerdict
        $clone.Tip = $tipSha
        Add-HarnessCase $cases 'facts: the fetched feature line moved on' $true (& $failedWith $routeTip 'not on the freshly fetched')
        $clone.PrRef = 'b' * 40
        $routePrRef = & $factsVerdict
        $clone.PrRef = $headSha
        Add-HarnessCase $cases 'facts: the fetched ref of the PR differs from the API head' $true (& $failedWith $routePrRef 'fetched locally differs')
        $savedChecks = $answers.Checks
        $answers.Checks = Copy-HarnessObject $savedChecks
        ($answers.Checks.check_runs | Where-Object name -eq 'harness-gate').conclusion = 'failure'
        $routeFailed = & $factsVerdict
        Add-HarnessCase $cases 'facts: a required check run that failed' $true (& $failedWith $routeFailed 'harness-gate is not success')
        # the real shape of a failed PR run and a later dispatch on the same head: the dispatch has the bigger id and proves nothing
        $answers.Checks = Copy-HarnessObject $savedChecks
        ($answers.Checks.check_runs | Where-Object name -eq 'branch-gate').conclusion = 'failure'
        $answers.Checks.check_runs = @($answers.Checks.check_runs) + @([pscustomobject]@{ id = 999; name = 'branch-gate'; status = 'completed'; conclusion = 'success'; head_sha = $headSha; app = [pscustomobject]@{ slug = 'github-actions' }; details_url = 'https://github.com/synchain-oss/reaper-harness/actions/runs/5000000099/job/5000000991' })
        $routeDispatch = & $factsVerdict
        Add-HarnessCase $cases 'facts: a failed PR run with a successful dispatch of a bigger id on the same head is not success' $true (& $failedWith $routeDispatch 'branch-gate is not success')
        # another app can create a check of the same name, and can point its link at the real PR run
        foreach ($foreignLink in 'https://example.invalid/app/check/1', 'https://github.com/synchain-oss/reaper-harness/actions/runs/5000000002/job/5000000021') {
            $answers.Checks = Copy-HarnessObject $savedChecks
            ($answers.Checks.check_runs | Where-Object name -eq 'harness-gate').conclusion = 'failure'
            $answers.Checks.check_runs = @($answers.Checks.check_runs) + @([pscustomobject]@{ id = 999; name = 'harness-gate'; status = 'completed'; conclusion = 'success'; head_sha = $headSha; app = [pscustomobject]@{ slug = 'some-other-app' }; details_url = $foreignLink })
            $routeForeign = & $factsVerdict
            Add-HarnessCase $cases "facts: a failed required check is not covered by another app's check of the same name ($foreignLink)" $true (& $failedWith $routeForeign 'harness-gate is not success')
        }
        $answers.Checks = $savedChecks
        $goodRecord = $runLog.Text
        $staleRecord = "claude-pr-review`tPost the review summary`t2026-11-01T10:01:10.0000000Z harness-review-posted id=1 sha256=$('0' * 64)"
        $runLog.Text = "$staleRecord`n$goodRecord"
        $routeLastGood = & $factsVerdict
        $runLog.Text = "$goodRecord`n$staleRecord"
        $routeLastBad = & $factsVerdict
        $runLog.Text = $goodRecord
        Add-HarnessCase $cases 'facts: two posted records in the log, the last one matches' $false ($routeLastGood.Code -ne 'ready')
        Add-HarnessCase $cases 'facts: two posted records in the log, the last one does not match' $true (& $failedWith $routeLastBad 'posted record')
        # a job of the run listed first: the log must still be the one of the review bot's job
        $savedJobs = $answers.Jobs
        $answers.Jobs = Copy-HarnessObject $savedJobs
        $answers.Jobs.jobs = @([pscustomobject]@{ id = 5000000099; name = 'another-job'; status = 'completed'; conclusion = 'success'; head_sha = $headSha }) + @($answers.Jobs.jobs)
        $log.Clear()
        $routeDecoy = & $factsVerdict
        $answers.Jobs = $savedJobs
        Add-HarnessCase $cases 'facts: the log is read for the job of the review bot, not for the first job of the run' $false ($routeDecoy.Code -ne 'ready' -or -not @($log | Where-Object { $_ -match '--log --job 5000000011$' }).Count)
        $answers.Jobs = Copy-HarnessObject $savedJobs
        ($answers.Jobs.jobs | Where-Object name -eq 'claude-pr-review').conclusion = 'failure'
        $routeJobFailed = & $factsVerdict
        $answers.Jobs = $savedJobs
        Add-HarnessCase $cases 'facts: the job of the review bot did not succeed' $true (& $failedWith $routeJobFailed 'job of the bot run did not succeed')

        Set-HarnessFake (New-HarnessFake -Routes ([ordered]@{}))
        $nameless =Read-Records -Number 7 -Path $null -Usable $true
        Set-HarnessFake (New-HarnessFake -Routes $routes -Log $log)
        Add-HarnessCase $cases 'no -WaiverFile: no records at all' $false (@($nameless.Waivers).Count + @($nameless.Approvals).Count + @($nameless.ExternalHandled).Count -ne 0)
        # a registered worktree (git worktree list) of this repository, with a records file inside it
        New-Item -ItemType Directory -Force -Path (Join-Path $workDir 'example') | Out-Null
        $inTree = Join-Path $workDir 'example/waivers.json'
        Set-Content -LiteralPath $inTree -Value (ConvertTo-Json -Depth 10 @{ approvals = @{ '7' = @(@{ head = $headSha; by = 'user'; note = 'inside a worktree' }) } })
        $hidden = Get-MergeFacts -Number 7 -RecordsPath $inTree
        $hiddenVerdict = Get-MergeVerdict $hidden
        Add-HarnessCase $cases 'a records file at a bad location is a failure and its content is not used' $true (
            $hiddenVerdict.Code -eq 'not-ready' -and @($hiddenVerdict.Failures | Where-Object { $_ -match 'outside the repository' }).Count -eq 1 -and @($hidden.Records.Approvals).Count -eq 0)

        # ---- counter-examples: one change on a copy of the facts, one criterion ----------------
        $copy = {
            $f = [pscustomobject]@{}
            foreach ($prop in $base.PSObject.Properties) { $f | Add-Member -NotePropertyName $prop.Name -NotePropertyValue (Copy-HarnessObject $prop.Value) }
            $f.Checks = @{}; foreach ($k in $base.Checks.Keys) { $f.Checks[$k] = Copy-HarnessObject $base.Checks[$k] }
            $f.Items = @($base.Items | ForEach-Object { Copy-HarnessObject $_ })
            $f
        }
        $bad = {
            param([string]$label, [scriptblock]$mutate, [string]$expect = 'not-ready', [scriptblock]$also = { param($r) $true })
            $f = & $copy
            & $mutate $f
            $r = Get-MergeVerdict $f
            if ($env:HARNESS_SELFTEST_VERBOSE) { [Console]::Error.WriteLine("$label => $($r.Code) | $(@($r.Failures) + @($r.Needs | ForEach-Object Reason) -join ' ; ')") }
            Add-HarnessCase $cases $label ($expect -ne 'ready') ($(if ($expect -eq 'ready') { $r.Code -ne 'ready' } else { $r.Code -eq $expect -and (& $also $r) }))
        }
        $failure = { param($word) { param($r) @($r.Failures | Where-Object { $_ -match $word }).Count -eq 1 }.GetNewClosure() }
        # reads as equal to nothing at all under -ceq and -ccontains; the comparisons of the criteria must not read it so
        $zeroWidth = [string][char]0x200B
        $vu = & $copy
        $vu.Posted = $null
        $vu = Get-MergeVerdict $vu
        Add-HarnessCase $cases 'no posted record in the log: only updated_at is checked and Warnings says the hash was not verified' $false (
            -not ($vu.Code -eq 'ready' -and @($vu.Warnings | Where-Object { $_ -match 'Hash not verified' }).Count -eq 1))
        # the comment table is rebuilt from the (edited) raw sources, classification included
        $reitem = { param($f, [scriptblock]$edit) $a = Copy-HarnessObject $f.Activity; & $edit $a; $f.Activity = $a; $f.Items = @(Get-HarnessCommentItems -Activity $a -State $f.State) }
        $person = { param($id, $login, $text, $created, $updated) [pscustomobject]@{ id = [long]$id; user = $(if ($login) { [pscustomobject]@{ login = $login; type = 'User' } } else { $null }); author_association = 'NONE'; created_at = $created; updated_at = $updated; body = $text; html_url = "https://github.com/x/y/pull/7#issuecomment-$id" } }
        $reply = { param($id, $answered, $created, $text = 'Done.') & $person $id 'DLsnows' "<!-- harness-agent v1 role=review kind=reply round=3 head=3f9c2e1$(if ($answered) { " in-reply-to=$answered" }) -->`n$text" $created $created }

        & $bad 'this checkout is not on the fetched origin/feature/v1' { param($f) $f.Clone.Head = 'd' * 40 } 'not-ready' (& $failure 'not on the freshly fetched')
        & $bad 'this checkout has uncommitted changes' { param($f) $f.Clone.Dirty = $true } 'not-ready' (& $failure 'uncommitted changes')
        & $bad 'core.hooksPath is not set' { param($f) $f.Clone.HooksPath = '' } 'not-ready' (& $failure "core\.hooksPath is '', not scripts/hooks of this checkout")
        & $bad 'core.hooksPath is the default hooks directory' { param($f) $f.Clone.HooksPath = '.git/hooks' } 'not-ready' (& $failure "core\.hooksPath is '\.git/hooks'")
        & $bad 'core.hooksPath is the hooks directory of another checkout' { param($f) $f.Clone.HooksPath = (Join-Path $workDir 'other/scripts/hooks') } 'not-ready' (& $failure 'core\.hooksPath is ')
        & $bad 'core.hooksPath written as ./scripts/hooks' { param($f) $f.Clone.HooksPath = './scripts/hooks' } 'ready'
        & $bad 'core.hooksPath written absolute, with forward slashes and a trailing slash' { param($f) $f.Clone.HooksPath = ($f.Clone.Root -replace '\\', '/') + '/scripts/hooks/' } 'ready'
        $hooksOf = { param($spelling) Test-HooksPath -CheckoutRoot $base.Clone.Root -Value $spelling }
        Add-HarnessCase $cases 'hooks path: scripts/hooks-old is another directory' $true (-not (& $hooksOf 'scripts/hooks-old'))
        Add-HarnessCase $cases 'hooks path: a parent directory spelling that leaves scripts/hooks is refused' $true (-not (& $hooksOf 'scripts/../scripts/other'))
        Add-HarnessCase $cases 'hooks path: a spelling through a parent directory that ends in scripts/hooks is the same directory' $false (-not (& $hooksOf 'scripts/../scripts/hooks'))
        Add-HarnessCase $cases 'hooks path: the checkout root alone is not the hooks directory' $true (-not (& $hooksOf '.'))
        if ($IsWindows) { Add-HarnessCase $cases 'hooks path: Windows compares the spelling without regard to case' $false (-not (& $hooksOf 'Scripts/Hooks')) }
        & $bad 'base is dev' { param($f) $f.Pull.base.ref = 'dev' } 'not-ready' (& $failure 'base must be feature/v1')
        & $bad 'base is a feature/** other than feature/v1' { param($f) $f.Pull.base.ref = 'feature/v2' } 'not-ready' (& $failure 'base must be feature/v1')
        & $bad 'base is feature/v1 with a zero-width space behind it' { param($f) $f.Pull.base.ref = "feature/v1$zeroWidth" } 'not-ready' (& $failure 'base must be feature/v1')
        & $bad 'head is not a feat/ branch' { param($f) $f.Pull.head.ref = 'fix/x' } 'not-ready' (& $failure 'head must be feat/')
        & $bad 'head branch with uppercase letters' { param($f) $f.Pull.head.ref = 'feat/Example' } 'not-ready' (& $failure 'head must be feat/')
        & $bad 'draft' { param($f) $f.Pull.draft = $true } 'not-ready' (& $failure 'draft')
        & $bad 'closed' { param($f) $f.Pull.state = 'closed' } 'not-ready' (& $failure 'not open')
        & $bad 'head from a fork' { param($f) $f.Pull.head.repo.full_name = 'someone/reaper-harness' } 'not-ready' (& $failure 'not a branch of this repository')
        & $bad 'conflict (mergeable_state=dirty)' { param($f) $f.Pull.mergeable_state = 'dirty' } 'not-ready' (& $failure 'not mergeable')
        & $bad 'the locally fetched PR head differs from the API' { param($f) $f.PrRef = 'b' * 40 } 'not-ready' (& $failure 'fetched locally differs')
        & $bad 'no bot summary' { param($f) $f.State.summary = $null } 'not-ready' (& $failure 'no bot review summary')
        & $bad 'the bot summary reviewed an older head' { param($f) $f.State.summary.head = 'c' * 40 } 'not-ready' (& $failure 'not the current head')
        & $bad 'footer important=1' { param($f) $f.State.summary.important = 1 } 'not-ready' (& $failure 'Footer red=0 important=1')
        & $bad 'footer red=1' { param($f) $f.State.summary.red = 1 } 'not-ready' (& $failure 'Footer red=1')
        & $bad 'the bot verdict is unusable' { param($f) $f.State.summary.ok = $false; $f.State.summary.reason = 'more than one footer line' } 'not-ready' (& $failure 'unusable')
        & $bad 'two summaries of the same head with contradicting footers' { param($f) $x = Copy-HarnessObject $f.State.summaries[-1]; $x.important = 2; $f.State.summaries = @($f.State.summaries) + @($x) } 'not-ready' (& $failure 'contradict')
        & $bad 'two summaries of the same head that differ only in the suggestions contradict nothing' { param($f) $x = Copy-HarnessObject $f.State.summaries[-1]; $x.suggest = 5; $f.State.summaries = @($f.State.summaries) + @($x) } 'ready'
        & $bad 'GitHub reports more changed files than the list holds' { param($f) $f.Pull.changed_files = 3001 } 'not-ready' (& $failure 'changed_files=3001')
        & $bad 'GitHub does not report changed_files at all' { param($f) $f.Pull.PSObject.Properties.Remove('changed_files') } 'not-ready' (& $failure 'changed_files= for the PR')
        & $bad 'the summary has no run link' { param($f) $f.State.summary.runId = $null } 'not-ready' (& $failure 'no run link')
        & $bad 'the run cannot be fetched' { param($f) $f.Run = $null } 'not-ready' (& $failure 'cannot be fetched')
        & $bad 'the run link points at another workflow' { param($f) $f.Run.path = '.github/workflows/compliance.yml' } 'not-ready' (& $failure 'not the review workflow')
        & $bad 'the run link points at the workflow path with a zero-width space in it' { param($f) $f.Run.path = "$($f.Run.path)$zeroWidth" } 'not-ready' (& $failure 'not the review workflow')
        & $bad 'the run reviewed another head' { param($f) $f.Run.head_sha = 'd' * 40 } 'not-ready' (& $failure 'did not review the current head')
        & $bad 'the run was not a pull_request event' { param($f) $f.Run.event = 'workflow_dispatch' } 'not-ready' (& $failure 'did not review the current head')
        & $bad 'the run did not succeed' { param($f) $f.Run.conclusion = 'failure' } 'not-ready' (& $failure 'concluded failure')
        & $bad 'the claude-pr-review check points at another run' { param($f) $f.Checks['claude-pr-review'].details_url = 'https://github.com/x/y/actions/runs/1/job/2' } 'not-ready' (& $failure 'not the run the summary refers to')
        & $bad 'the claude-pr-review check did not succeed' { param($f) $f.Checks['claude-pr-review'].conclusion = 'failure' } 'not-ready' (& $failure 'not the run the summary refers to')
        & $bad 'no claude-pr-review check on the head' { param($f) $f.Checks.Remove('claude-pr-review') } 'not-ready' (& $failure 'not the run the summary refers to')
        & $bad 'the claude-pr-review job did not succeed' { param($f) $f.Jobs = @() } 'not-ready' (& $failure 'job of the bot run did not succeed')
        & $bad 'the summary was posted outside the run' { param($f) $f.State.summary.createdAt = '2026-11-01T06:00:00Z'; $f.State.summary.updatedAt = '2026-11-01T06:00:00Z' } 'not-ready' (& $failure 'not posted during that run')
        & $bad 'the summary was posted after the run had ended' { param($f) $f.State.summary.createdAt = '2026-11-01T10:10:00Z'; $f.State.summary.updatedAt = '2026-11-01T10:10:00Z' } 'not-ready' (& $failure 'not posted during that run')
        # the bot only creates, never edits; the posted record's comment id and body hash have to match too
        & $bad 'the bot summary was edited after posting (updated_at changed)' { param($f) $f.State.summary.updatedAt = '2026-11-01T11:00:00Z' } 'not-ready' (& $failure 'edited after posting')
        & $bad 'the body hash differs from the posted record' { param($f) $f.State.summary.sha256 = '0' * 64 } 'not-ready' (& $failure 'posted record')
        & $bad 'the comment id differs from the posted record' { param($f) $f.Posted.Id = '1' } 'not-ready' (& $failure 'posted record')
        $hashWaiver = { param($summaryHash, $by = 'user') @([pscustomobject]@{ head = $headSha; by = $by; red = 0; important = 0; deferred = $false; summaryHash = $summaryHash; note = 'user skips the hash check' }) }
        & $bad 'hash differs, the user registered a hash waiver for this head: passes with a warning' { param($f) $f.State.summary.sha256 = '0' * 64; $f.Records.Waivers = & $hashWaiver $true } 'ready' { param($r) @($r.Warnings | Where-Object { $_ -match 'hash waiver' }).Count -eq 1 }
        & $bad 'hash differs, the hash waiver is the string "false": still red' { param($f) $f.State.summary.sha256 = '0' * 64; $f.Records.Waivers = & $hashWaiver 'false' }
        & $bad 'hash differs, the hash waiver is not by the user: still red' { param($f) $f.State.summary.sha256 = '0' * 64; $f.Records.Waivers = & $hashWaiver $true 'orchestrator' }
        & $bad 'hash differs, the hash waiver is the boolean false: still red' { param($f) $f.State.summary.sha256 = '0' * 64; $f.Records.Waivers = & $hashWaiver $false }
        $hashWaived = & $copy
        $hashWaived.State.summary.sha256 = '0' * 64
        $hashWaived.Records.Waivers = & $hashWaiver $true
        $hashWaivedVerdict = Get-MergeVerdict $hashWaived
        Add-HarnessCase $cases 'the verdict prints the hash waiver it relies on, verbatim' $false (-not ($hashWaivedVerdict.Code -eq 'ready' -and @($hashWaivedVerdict.ReliedOn | Where-Object { $_.Kind -eq 'waiver' -and $_.Record.note -eq 'user skips the hash check' }).Count -eq 1))
        # the user's records: one of a kind per head, which one was meant is never guessed
        $userRecord = { param($h = $headSha, $noteText = 'a record') [pscustomobject]@{ head = $h; by = 'user'; red = 0; important = 0; deferred = $false; note = $noteText; comments = @() } }
        & $bad 'two waivers for this head' { param($f) $f.Records.Waivers = @((& $userRecord), (& $userRecord)) } 'not-ready' (& $failure 'has 2 records of kind waivers for head')
        & $bad 'two approvals for this head' { param($f) $f.Records.Approvals = @((& $userRecord), (& $userRecord)) } 'not-ready' (& $failure 'has 2 records of kind approvals for head')
        & $bad 'two external-handled records for this head' { param($f) $f.Records.ExternalHandled = @((& $userRecord), (& $userRecord)) } 'not-ready' (& $failure 'has 2 records of kind external-handled for head')
        & $bad 'the message about two records names the file' { param($f) $f.Records.Waivers = @((& $userRecord), (& $userRecord)) } 'not-ready' (& $failure ([regex]::Escape($recordsFile)))
        & $bad 'records of other heads do not count as a second record' { param($f) $f.Records.Waivers = @((& $userRecord), (& $userRecord ('a' * 40))) } 'ready'
        & $bad 'a record not by the user does not count as a second record' { param($f) $other = & $userRecord; $other.by = 'orchestrator'; $f.Records.Waivers = @((& $userRecord), $other) } 'ready'
        # pr-agent check: required to have finished only when the head already has it (any conclusion)
        $prAgent = 'pr-agent-claude / pr-agent'
        & $bad 'pr-agent check has not finished' { param($f) $f.Checks[$prAgent] = [pscustomobject]@{ name = $prAgent; status = 'in_progress'; conclusion = $null } } 'not-ready' (& $failure 'has not finished')
        & $bad 'pr-agent check finished (failure is accepted too)' { param($f) $f.Checks[$prAgent] = [pscustomobject]@{ name = $prAgent; status = 'completed'; conclusion = 'failure' } } 'ready'
        & $bad 'no pr-agent check on the head: none required' { param($f) $null } 'ready'
        & $bad 'no disposition' { param($f) $f.State.disposition = $null } 'not-ready' (& $failure 'no disposition after')
        & $bad 'the disposition refers to another run' { param($f) $f.State.disposition.botRun = '1' } 'not-ready' (& $failure 'refers to run 1')
        & $bad 'a round without a disposition' { param($f) $f.State.dispositionRuns = @() } 'not-ready' (& $failure 'has no disposition')
        & $bad 'an unresolved thread' { param($f) $f.Threads[0].isResolved = $false; ($f.Items | Where-Object ThreadId -eq $f.Threads[0].id) | ForEach-Object { $_.Resolved = $false } } 'not-ready' (& $failure 'not resolved')

        # responses: against the original's updated_at, by in-reply-to only, review states
        & $bad 'the maintainer comment has no response' { param($f) & $reitem $f { param($a) $a.Issue += & $person 999 'DLsnows' 'Please look again.' '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z' } } 'not-ready' (& $failure 'without a response')
        & $bad 'an answered maintainer comment passes' { param($f) & $reitem $f { param($a) $a.Issue += & $person 999 'DLsnows' 'Please look again.' '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z'; $a.Issue += & $reply 1000 '999' '2026-11-01T11:10:00Z' } } 'ready'
        & $bad 'the original was edited after our reply' { param($f) & $reitem $f { param($a) $a.Issue += & $person 999 'DLsnows' 'Please look again (more).' '2026-11-01T11:00:00Z' '2026-11-01T12:00:00Z'; $a.Issue += & $reply 1000 '999' '2026-11-01T11:10:00Z' } } 'not-ready' (& $failure 'without a response')
        & $bad 'the id only occurs in the text' { param($f) & $reitem $f { param($a) $a.Issue += & $person 995 'DLsnows' 'Run it again.' '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z'; $a.Issue += & $reply 1000 $null '2026-11-01T11:10:00Z' 'ran 995 cases' } } 'not-ready' (& $failure 'without a response')
        $review = { param($id, $state, $text = '', $at = '2026-11-01T11:00:00Z') [pscustomobject]@{ id = $id; state = $state; body = $text; user = [pscustomobject]@{ login = 'DLsnows'; type = 'User' }; submitted_at = $at; updated_at = $at; html_url = 'u' } }
        & $bad 'Request changes with an empty body has no response' { param($f) & $reitem $f { param($a) $a.Reviews += & $review 777 'CHANGES_REQUESTED' } } 'not-ready' (& $failure 'without a response')
        & $bad 'Request changes lifted by a later APPROVED of the same person' { param($f) & $reitem $f { param($a) $a.Reviews += & $review 777 'CHANGES_REQUESTED'; $a.Reviews += & $review 778 'APPROVED' '' '2026-11-01T11:30:00Z' } } 'ready'
        & $bad 'Request changes answered by in-reply-to' { param($f) & $reitem $f { param($a) $a.Reviews += & $review 777 'CHANGES_REQUESTED'; $a.Issue += & $reply 1000 '777' '2026-11-01T11:10:00Z' } } 'ready'
        & $bad 'an empty COMMENTED review with no inline comments has no response' { param($f) & $reitem $f { param($a) $a.Reviews += & $review 779 'COMMENTED' } } 'not-ready' (& $failure 'without a response')
        $reviewBy = { param($a, $id, $state, $text, $login) $a.Reviews += & $review $id $state $text; $a.Reviews[-1].user.login = $login }
        & $bad 'an APPROVED review of an outside account with a body goes to the user' { param($f) & $reitem $f { param($a) & $reviewBy $a 781 'APPROVED' 'Fine, but look at the naming.' 'someone' } } 'needs-user' { param($r) @($r.Needs | Where-Object Kind -eq 'external').Count -eq 1 }
        & $bad 'a DISMISSED review of an outside account with a body goes to the user' { param($f) & $reitem $f { param($a) & $reviewBy $a 782 'DISMISSED' 'I take that back.' 'someone' } } 'needs-user' { param($r) @($r.Needs | Where-Object Kind -eq 'external').Count -eq 1 }
        & $bad 'an APPROVED review of the maintainer with a body has to be answered' { param($f) & $reitem $f { param($a) & $reviewBy $a 783 'APPROVED' 'One more thing.' 'DLsnows' } } 'not-ready' (& $failure 'without a response')
        & $bad 'a DISMISSED review of the maintainer with a body has to be answered' { param($f) & $reitem $f { param($a) & $reviewBy $a 784 'DISMISSED' 'One more thing.' 'DLsnows' } } 'not-ready' (& $failure 'without a response')
        & $bad 'an APPROVED review with a body, answered by in-reply-to' { param($f) & $reitem $f { param($a) & $reviewBy $a 783 'APPROVED' 'One more thing.' 'DLsnows'; $a.Issue += & $reply 1000 '783' '2026-11-01T11:10:00Z' } } 'ready'
        & $bad 'an APPROVED or DISMISSED review of an outside account with an empty body is left out' { param($f) & $reitem $f { param($a) & $reviewBy $a 785 'APPROVED' '' 'someone'; & $reviewBy $a 786 'DISMISSED' '' 'someone' } } 'ready'
        & $bad 'a review body answered by in-reply-to' { param($f) & $reitem $f { param($a) $a.Reviews += & $review 780 'COMMENTED' 'Check the naming.'; $a.Issue += & $reply 1000 '780' '2026-11-01T11:10:00Z' } } 'ready'
        & $bad 'a review body edited after our reply' { param($f) & $reitem $f { param($a) $a.Reviews += & $review 780 'COMMENTED' 'Check the naming.'; $a.Reviews[-1].updated_at = '2026-11-01T12:00:00Z'; $a.Issue += & $reply 1000 '780' '2026-11-01T11:10:00Z' } } 'not-ready' (& $failure 'without a response')
        $userInline = {
            param($a, [bool]$withReply)
            $c = & $person 8001 'DLsnows' 'Rename this.' '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z'
            $c | Add-Member -NotePropertyName pull_request_review_id -NotePropertyValue 9001
            $a.Review += $c
            $nodes = @([pscustomobject]@{ databaseId = 8001 })
            if ($withReply) {
                $r = & $reply 8002 $null '2026-11-01T11:10:00Z' 'Renamed.'
                $r | Add-Member -NotePropertyName pull_request_review_id -NotePropertyValue 9002
                $a.Review += $r
                $nodes += [pscustomobject]@{ databaseId = 8002 }
            }
            $a.Threads += [pscustomobject]@{ id = 'PRRT_user'; isResolved = $true; comments = [pscustomobject]@{ nodes = $nodes } }
        }
        & $bad 'an inline comment of the maintainer that is only resolved, not answered' { param($f) & $reitem $f { param($a) & $userInline $a $false } } 'not-ready' (& $failure 'without a response')
        & $bad 'an inline comment of the maintainer with our reply in the thread' { param($f) & $reitem $f { param($a) & $userInline $a $true } } 'ready'
        & $bad 'a comment of a deleted account is external' { param($f) & $reitem $f { param($a) $a.Issue += & $person 996 $null '...' '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z' } } 'needs-user'
        # pr-agent output is its own class: unanswered = not-ready (not external); answered only by in-reply-to later than updated_at; the two notices are exempt
        $prAgentComment = { param($a, $id, $updated = '2026-11-01T11:00:00Z') $a.Issue += & $person $id 'github-actions[bot]' "<!-- pr-agent:review:full -->`n## PR Reviewer Guide`n`n**Recommended focus areas**`n`n- Possible Issue: x" '2026-11-01T11:00:00Z' $updated }
        & $bad 'an unanswered pr-agent comment is not-ready, not external' { param($f) & $reitem $f { param($a) & $prAgentComment $a 1201 } } 'not-ready' { param($r) @($r.Failures | Where-Object { $_ -match 'pr-agent|Comment without a response' }).Count -eq 1 -and @($r.Needs).Count -eq 0 }
        & $bad 'a pr-agent comment answered later than its updated_at' { param($f) & $reitem $f { param($a) & $prAgentComment $a 1201; $a.Issue += & $reply 1202 '1201' '2026-11-01T11:10:00Z' } } 'ready'
        & $bad 'a pr-agent comment whose answer predates its updated_at' { param($f) & $reitem $f { param($a) & $prAgentComment $a 1201 '2026-11-01T11:20:00Z'; $a.Issue += & $reply 1202 '1201' '2026-11-01T11:10:00Z' } } 'not-ready' (& $failure 'without a response')
        & $bad 'the two pr-agent notices are exempt' { param($f) & $reitem $f { param($a) $a.Issue += & $person 1203 'github-actions[bot]' '**[Persistent review](https://github.com/o/r/pull/7#issuecomment-1)** updated to latest commit https://github.com/o/r/commit/abc1234' '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z'; $a.Issue += & $person 1204 'github-actions[bot]' 'Failed to generate code suggestions for PR' '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z' } } 'ready'
        & $bad 'the words of a pr-agent notice above a list of findings have to be answered' { param($f) & $reitem $f { param($a) $a.Issue += & $person 1208 'github-actions[bot]' "The [Persistent review] link`n- 【重要】a real finding" '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z' } } 'not-ready' (& $failure 'without a response')
        & $bad 'a pr-agent marker below the first 5 lines (a quote) is a plain bot comment, and that has to be answered too' { param($f) & $reitem $f { param($a) $a.Issue += & $person 1205 'github-actions[bot]' "one`ntwo`nthree`nfour`nfive`n<!-- pr-agent:review:full -->`n## PR Reviewer Guide" '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z' } } 'not-ready' (& $failure 'without a response')
        $deepseekText = "### DeepSeek PR review (``some-model``, manual run)`n`nLooks mostly fine."
        & $bad 'the output of the manual review bot has to be answered' { param($f) & $reitem $f { param($a) $a.Issue += & $person 1206 'github-actions[bot]' $deepseekText '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z' } } 'not-ready' (& $failure 'without a response')
        & $bad 'the output of the manual review bot, answered by in-reply-to' { param($f) & $reitem $f { param($a) $a.Issue += & $person 1206 'github-actions[bot]' $deepseekText '2026-11-01T11:00:00Z' '2026-11-01T11:00:00Z'; $a.Issue += & $reply 1207 '1206' '2026-11-01T11:10:00Z' } } 'ready'
        # external comments go to the user; external-handled binds head, by = user and the comment's updated_at
        $external = { param($a, $updated = '2026-11-01T11:00:00Z') $a.Issue += & $person 998 'someone' 'lgtm' '2026-11-01T11:00:00Z' $updated }
        $handledRecord = { param($h = $headSha, $by = 'user', $listed = @([pscustomobject]@{ id = '998'; updated_at = '2026-11-01T11:00:00Z' })) @([pscustomobject]@{ head = $h; by = $by; comments = $listed; note = 'replied' }) }
        & $bad 'an external comment goes to the user' { param($f) & $reitem $f { param($a) & $external $a } } 'needs-user' { param($r) @($r.Needs | Where-Object Kind -eq 'external').Count -eq 1 }
        & $bad 'an external comment the user handled for this head passes' { param($f) & $reitem $f { param($a) & $external $a }; $f.Records.ExternalHandled = & $handledRecord } 'ready'
        & $bad 'the handled record is for another head' { param($f) & $reitem $f { param($a) & $external $a }; $f.Records.ExternalHandled = & $handledRecord ('e' * 40) } 'needs-user'
        & $bad 'the handled record is not by the user' { param($f) & $reitem $f { param($a) & $external $a }; $f.Records.ExternalHandled = & $handledRecord $headSha 'orchestrator' } 'needs-user'
        & $bad 'the external comment was edited after the user handled it' { param($f) & $reitem $f { param($a) & $external $a '2026-11-01T13:00:00Z' }; $f.Records.ExternalHandled = & $handledRecord } 'needs-user' { param($r) @($r.Needs | Where-Object { $_.Reason -match 'edited after the user handled' }).Count -eq 1 }
        & $bad 'the handled record lists only an id, no updated_at' { param($f) & $reitem $f { param($a) & $external $a }; $f.Records.ExternalHandled = & $handledRecord $headSha 'user' @('998') } 'needs-user'
        & $bad 'the handled record names another comment (right updated_at, wrong id)' { param($f) & $reitem $f { param($a) & $external $a }; $f.Records.ExternalHandled = & $handledRecord $headSha 'user' @([pscustomobject]@{ id = '997'; updated_at = '2026-11-01T11:00:00Z' }) } 'needs-user'
        $x = & $copy
        & $reitem $x { param($a) & $external $a }
        $x.Records.ExternalHandled = & $handledRecord
        $vx = Get-MergeVerdict $x
        Add-HarnessCase $cases 'the verdict prints the handled record it relies on, verbatim' $false (-not ($vx.Code -eq 'ready' -and @($vx.ReliedOn | Where-Object { $_.Kind -eq 'external-handled' -and $_.Record.comments[0].updated_at -eq '2026-11-01T11:00:00Z' -and $_.File -eq $recordsFile }).Count -eq 1))

        # findings judged will-not-fix: the user has to waive them
        $row = { param($level, $where, $what, $action) "| $level | $where | $what | $action |" }
        $addRow = {
            param($f, [int]$round, [string]$text)
            $existing = @($f.Items | Where-Object { $_.Kind -eq 'agent' -and $_.Source -eq 'issue' -and (Get-AgentMarker $_.Body) -and (Get-AgentMarker $_.Body).Kind -eq 'disposition' -and (Get-AgentMarker $_.Body).Round -eq $round })
            if ($existing.Count) { $existing[0].Body += "`n$text"; return }
            $first = @($f.Items | Where-Object { $_.Kind -eq 'agent' -and $_.Source -eq 'issue' -and (Get-AgentMarker $_.Body) -and (Get-AgentMarker $_.Body).Kind -eq 'disposition' })[0]
            $later = Copy-HarnessObject $first
            $later.Id = [string](9000000099 + $round)
            $later.Body = ((@($first.Body -split "`n" | Select-Object -First 6) -join "`n") -replace 'round=\d+', "round=$round") + "`n$text"
            $f.Items = @($f.Items) + @($later)
        }
        & $bad 'an important finding judged "will not fix"' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '不改') } 'needs-user' { param($r) @($r.Needs | Where-Object Kind -eq 'deferred').Count -eq 1 }
        & $bad 'the deferral has a waiver only by the orchestrator' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '不改'); $f.Records.Waivers = @([pscustomobject]@{ head = $headSha; by = 'orchestrator'; red = 0; important = 0; deferred = $true; note = '' }) } 'needs-user'
        & $bad 'the deferral has a user waiver for this head' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '不改'); $f.Records.Waivers = @([pscustomobject]@{ head = $headSha; by = 'user'; red = 0; important = 0; deferred = $true; note = 'ok' }) } 'ready'
        & $bad 'the waiver does not say deferred: true' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '不改'); $f.Records.Waivers = @([pscustomobject]@{ head = $headSha; by = 'user'; red = 0; important = 0; deferred = $false; note = 'ok' }) } 'needs-user'
        foreach ($word in '**不改**', '__挂账__', '`不采纳`', '不采纳', '暂不改', '维持', '搁置', '未采纳', '不处理', '延后', '不修复', '未修复') {
            & $bad "an important finding with the decision '$word'" { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' "$word abc1234") } 'needs-user'
        }
        & $bad 'the decision column is empty' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '') } 'needs-user'
        & $bad 'a suggestion level with a zero-width space behind it is read as severe' { param($f) & $addRow $f 1 (& $row "【建议$zeroWidth】" 'a.mjs:1' 'x' '不改') } 'needs-user' { param($r) @($r.Deferred).Count -eq 1 }
        & $bad '"adopt" with a commit is handled' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '采纳 abc1234') } 'ready'
        & $bad '"fixed" with a commit is handled' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '修复 abc1234') } 'ready'
        foreach ($word in '修复不了', '修复中', '修复待定', '修复计划', '采纳不修', '采纳不做', '采纳但不修', '采纳但不做', '采纳，跟进中', '采纳，后续再做', '已修一半，其余下个 PR', '采纳：开 issue 跟进', '已修？否', '采纳与否待定', '采纳，但不在本 PR 改') {
            & $bad "a handled word that goes on to say it is not done: '$word'" { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' "$word abc1234") } 'needs-user' { param($r) @($r.Deferred).Count -eq 1 }
        }
        & $bad "a handled word that goes on to say it is not done, the commit in the next column" { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '修复中 | abc1234') } 'needs-user' { param($r) @($r.Deferred).Count -eq 1 }
        foreach ($word in '修复中文路径', '修复不一致', '已修：不再重复扫描', '修复后续步骤被跳过', '采纳：计划文件改名', '已修：中断时报错', '已修：采纳与否的判断') {
            & $bad "a handled word followed by a description of the fix: '$word'" { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' "$word abc1234") } 'ready'
        }
        # what proves a commit: the real shapes of it, and the words, ids and links that only look like one
        foreach ($word in 'feedback', 'FEEDBACK', 'ABC1234', 'effaced', 'defaced', 'abc1234xyz', 'xyzabc1234', 'https://example.invalid/issues/1abcdef', 'not-a-hash-abc1234', 'abc1234-note', 'v1.abc1234', '#abc1234', 'abc1234/x', '1234567', 'abcdefa', 'abc123', ('abc1234' + ('0' * 34)), 'abc1234.ps1', '见 abc1234.md', '<!-- abc1234 -->') {
            & $bad "no commit in the words: '已修 $word'" { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' "已修 $word") } 'needs-user' { param($r) @($r.Deferred).Count -eq 1 }
        }
        foreach ($word in 'feedback 已收到', 'PR_kwDOabcdef1 的讨论') {
            & $bad "no commit in the column on the right: '$word'" { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' "采纳 | $word") } 'needs-user' { param($r) @($r.Deferred).Count -eq 1 }
        }
        foreach ($word in '`abc1234`', '（abc1234）', '：abc1234，补了用例', 'abc1234.', 'abc1234。', 'abc1234. 后续', 'abc1234、def5678', 'abc1234..def5678', '提交abc1234修复', 'https://github.com/o/r/commit/abc1234', 'https://github.com/o/r/pull/7/commits/abc1234def', ('abc1234' + ('0' * 33))) {
            & $bad "a commit in the shape it is written: '已修 $word'" { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' "已修 $word") } 'ready'
        }
        & $bad 'a commit in the column on the right' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '采纳 | abc1234') } 'ready'
        & $bad 'a commit of only digits is not read as one, and the message says so' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '已修 1234567') } 'needs-user' { param($r) @($r.Needs | Where-Object { $_.Kind -eq 'deferred' -and $_.Reason -match 'only digits or only letters' }).Count -eq 1 }
        & $bad 'a word that is neither on the handled list nor a refusal is not handled' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '已处理 abc1234') } 'needs-user' { param($r) @($r.Deferred).Count -eq 1 }
        foreach ($word in '待修复', '计划修复', '已采纳', '已改', '将修复', '部分修复', 'fixed', '见下') {
            & $bad "a severe row whose decision does not start with a handled word: '$word'" { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' "$word abc1234") } 'needs-user' { param($r) @($r.Deferred).Count -eq 1 }
        }
        & $bad 'a handled word with a refusal in the same cell is not handled' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '采纳 abc1234，其余不改') } 'needs-user' { param($r) @($r.Deferred).Count -eq 1 }
        & $bad 'a handled word without a commit is not handled' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '采纳') } 'needs-user' { param($r) @($r.Deferred).Count -eq 1 }
        foreach ($odd in 'important', '高', '严重', '重要度', '', '红旗 0') {
            & $bad "a level the table does not know is read as severe: '$odd'" { param($f) & $addRow $f 1 (& $row $odd 'a.mjs:1' 'x' '不改') } 'needs-user' { param($r) @($r.Deferred).Count -eq 1 }
        }
        foreach ($mild in '建议', '【建议】', '总结', '【总结】', '信息', '【信息】') {
            & $bad "a level that is not severe needs nothing: '$mild'" { param($f) & $addRow $f 1 (& $row $mild 'a.mjs:1' 'x' '不改') } 'ready'
        }
        & $bad 'level column says important without the brackets' { param($f) & $addRow $f 1 (& $row '重要' 'a.mjs:1' 'x' '不改') } 'needs-user'
        & $bad 'a red flag finding judged "will not fix"' { param($f) & $addRow $f 1 (& $row '【红旗】' 'a.mjs:1' 'x' '不改') } 'needs-user'
        & $bad 'a suggestion judged "will not fix" needs no waiver' { param($f) & $addRow $f 1 (& $row '【建议】' 'a.mjs:1' 'x' '不改') } 'ready'
        & $bad 'deferred first, fixed later (with a commit): no waiver needed' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '挂账'); & $addRow $f 3 (& $row '【重要】' 'a.mjs:1' 'x' '已修 abc1234') } 'ready'
        & $bad 'fixed first, deferred later: the waiver is needed' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '已修 abc1234'); & $addRow $f 3 (& $row '【重要】' 'a.mjs:1' 'x' '挂账') } 'needs-user'
        & $bad 'two findings at one location: one deferred, the other (other summary) fixed: the deferral stays' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'A' '挂账'); & $addRow $f 3 (& $row '【重要】' 'a.mjs:1' 'B' '已修 abc1234') } 'needs-user'
        & $bad 'the commit proof sits left of the decision column: the waiver is still needed' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '挂账'); & $addRow $f 3 (& $row '【重要】' 'abc1234' 'x' '已修') } 'needs-user'
        & $bad 'the "fixed" row has only a pure-digit number: the waiver is still needed' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '挂账'); & $addRow $f 3 (& $row '【重要】' 'a.mjs:1' 'x' '已修 7000000101') } 'needs-user'
        & $bad 'the deferred waiver is the string "false"' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '不改'); $f.Records.Waivers = @([pscustomobject]@{ head = $headSha; by = 'user'; red = 0; important = 0; deferred = 'false'; note = 'ok' }) } 'needs-user'
        $deferWaived = & $copy
        & $addRow $deferWaived 1 (& $row '【重要】' 'a.mjs:1' 'x' '不改')
        $deferWaived.Records.Waivers = @([pscustomobject]@{ head = $headSha; by = 'user'; red = 0; important = 0; deferred = $true; note = 'user accepts the deferral' })
        $deferWaivedVerdict = Get-MergeVerdict $deferWaived
        Add-HarnessCase $cases 'the verdict prints the deferred waiver it relies on, verbatim' $false (-not ($deferWaivedVerdict.Code -eq 'ready' -and @($deferWaivedVerdict.ReliedOn | Where-Object { $_.Kind -eq 'waiver' -and $_.Record.note -eq 'user accepts the deferral' }).Count -eq 1))
        # one row per finding, counted per run and per level
        $withFindings = { param($f, $levels) $f.State.summaries[-1].items = @($levels | ForEach-Object { [pscustomobject]@{ level = $_; text = 'a finding' } }) }
        $fixedRow = { param($level = '【重要】', $what = 'x') & $row $level 'a.mjs:1' $what '已修 abc1234' }
        & $bad 'a red flag of the summary has no row' { param($f) & $withFindings $f @('红旗') } 'not-ready' (& $failure 'run 5000000001 hold 0 【红旗】 row\(s\) with their own location and summary, the bot summary lists 1: 1 missing')
        & $bad 'an important finding of the summary has no row' { param($f) & $withFindings $f @('重要') } 'not-ready' (& $failure 'run 5000000001 hold 0 【重要】 row\(s\) with their own location and summary, the bot summary lists 1: 1 missing')
        & $bad 'three important findings, one row' { param($f) & $withFindings $f @('重要', '重要', '重要'); & $addRow $f 1 (& $fixedRow) } 'not-ready' (& $failure 'hold 1 【重要】 row\(s\) with their own location and summary, the bot summary lists 3: 2 missing')
        & $bad 'two findings, the same finding written twice: the other one has no row' { param($f) & $withFindings $f @('重要', '重要'); & $addRow $f 1 (& $row '【重要】' 'a.ps1:1' 'A' '挂账'); & $addRow $f 1 (& $row '【重要】' 'a.ps1:1' 'A' '已修 abc1234') } 'not-ready' (& $failure 'hold 1 【重要】 row\(s\) .* 1 missing')
        & $bad 'two findings, the same row in two comments of that run: the other one has no row' { param($f) & $withFindings $f @('重要', '重要'); & $addRow $f 1 (& $fixedRow); & $addRow $f 3 (& $fixedRow) } 'not-ready' (& $failure 'hold 1 【重要】 row\(s\) .* 1 missing')
        & $bad 'two findings, one row each in two comments of that run: enough' { param($f) & $withFindings $f @('重要', '重要'); & $addRow $f 1 (& $row '【重要】' 'a.ps1:1' 'A' '已修 abc1234'); & $addRow $f 3 (& $row '【重要】' 'b.ps1:2' 'B' '已修 abc1234') } 'ready'
        & $bad 'one finding, the same row again in a later comment of that run: enough' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 (& $fixedRow); & $addRow $f 3 (& $fixedRow) } 'ready'
        & $bad 'two findings at one location, each with its summary: enough' { param($f) & $withFindings $f @('重要', '重要'); & $addRow $f 1 (& $fixedRow '【重要】' 'A'); & $addRow $f 1 (& $fixedRow '【重要】' 'B') } 'ready'
        & $bad 'two findings with one summary at two locations: enough' { param($f) & $withFindings $f @('重要', '重要'); & $addRow $f 1 (& $row '【重要】' 'a.ps1:1' 'A' '已修 abc1234'); & $addRow $f 1 (& $row '【重要】' 'b.ps1:2' 'A' '已修 abc1234') } 'ready'
        & $bad 'two findings whose summaries differ only by letter case: enough' { param($f) & $withFindings $f @('重要', '重要'); & $addRow $f 1 (& $row '【重要】' 'a.ps1:1' 'Abc' '已修 abc1234'); & $addRow $f 1 (& $row '【重要】' 'a.ps1:1' 'abc' '已修 abc1234') } 'ready'
        & $bad 'a row in a code fence does not count for a finding' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 "``````text`n$(& $fixedRow)`n``````" } 'not-ready' (& $failure 'hold 0 【重要】 row')
        & $bad 'a row in an HTML comment does not count for a finding' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 "<!--`n$(& $fixedRow)`n-->" } 'not-ready' (& $failure 'hold 0 【重要】 row')
        & $bad 'a row in a one-line HTML comment does not count for a finding' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 "<!-- $(& $fixedRow) -->" } 'not-ready' (& $failure 'hold 0 【重要】 row')
        & $bad 'a row indented by 4 columns does not count for a finding' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 "    $(& $fixedRow)" } 'not-ready' (& $failure 'hold 0 【重要】 row')
        & $bad 'a level with a zero-width space behind it does not count for that finding' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 (& $fixedRow "重要$zeroWidth") } 'not-ready' (& $failure 'hold 0 【重要】 row')
        & $bad 'a row after a closed code fence counts' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 "``````text`nsample`n``````"; & $addRow $f 1 "| 级别 | 位置 | 摘要 | 处置 |`n|---|---|---|---|`n$(& $fixedRow)" } 'ready'
        & $bad 'one important finding, one row: enough' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 (& $fixedRow) } 'ready'
        & $bad 'the level without brackets counts as that level' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 (& $fixedRow '重要') } 'ready'
        & $bad 'a row of the other severe level does not count' { param($f) & $withFindings $f @('红旗'); & $addRow $f 1 (& $fixedRow '【重要】') } 'not-ready' (& $failure 'hold 0 【红旗】 row')
        & $bad 'a suggestion row does not count for an important finding' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 (& $fixedRow '【建议】') } 'not-ready' (& $failure 'hold 0 【重要】 row')
        & $bad 'a level the count does not know does not count for an important finding' { param($f) & $withFindings $f @('重要'); & $addRow $f 1 (& $fixedRow '高') } 'not-ready' (& $failure 'hold 0 【重要】 row')
        & $bad 'suggestions of the summary need no rows' { param($f) & $withFindings $f @('建议', '建议', '建议') } 'ready'
        $otherRunDisposition = { param($f, $text) $first = @($f.Items | Where-Object { $_.Kind -eq 'agent' -and (Get-AgentMarker $_.Body) -and (Get-AgentMarker $_.Body).Kind -eq 'disposition' })[0]; $later = Copy-HarnessObject $first; $later.Id = '9000000199'; $later.Body = ($first.Body -replace 'bot-run=\d+', 'bot-run=4999999999') + "`n$text"; $f.Items = @($f.Items) + @($later) }
        & $bad 'a row in the disposition of another run does not count' { param($f) & $withFindings $f @('重要'); & $otherRunDisposition $f (& $fixedRow) } 'not-ready' (& $failure 'run 5000000001 hold 0 【重要】 row')
        $foreignDisposition = { param($f, $text, $itemKind) $first = @($f.Items | Where-Object { $_.Kind -eq 'agent' -and (Get-AgentMarker $_.Body) -and (Get-AgentMarker $_.Body).Kind -eq 'disposition' })[0]; $later = Copy-HarnessObject $first; $later.Id = '9000000198'; $later.Kind = $itemKind; $later.Body = "$($first.Body)`n$text"; $f.Items = @($f.Items) + @($later) }
        & $bad 'a table of an outsider under the mark of a disposition does not count' { param($f) & $withFindings $f @('重要'); & $foreignDisposition $f (& $fixedRow) 'external' } 'not-ready' (& $failure 'run 5000000001 hold 0 【重要】 row')
        & $bad 'a table of a bot under the mark of a disposition does not count' { param($f) & $withFindings $f @('重要'); & $foreignDisposition $f (& $fixedRow) 'bot' } 'not-ready' (& $failure 'run 5000000001 hold 0 【重要】 row')
        & $bad 'an older summary is counted as well, against its own run' { param($f) $older = Copy-HarnessObject $f.State.summaries[-1]; $older.runId = '4999999999'; $older.head = 'a' * 40; $older.items = @([pscustomobject]@{ level = '红旗'; text = 'old finding' }); $f.State.summaries = @($older) + @($f.State.summaries); $f.State.dispositionRuns = @($f.State.dispositionRuns) + @('4999999999'); & $otherRunDisposition $f '| 【建议】 | a | b | 不改 |' } 'not-ready' (& $failure 'run 4999999999 hold 0 【红旗】 row')
        & $bad 'a summary without a run link cannot be referenced: its important finding is missing' { param($f) & $withFindings $f @('重要'); $f.State.summaries[-1].runId = $null } 'not-ready' (& $failure 'a bot summary without a run link hold 0 【重要】 row\(s\) with their own location and summary, the bot summary lists 1: 1 missing')
        # the waiver is compared with the footer, level by level
        & $bad 'footer red=2, the waiver covers red=1' { param($f) $f.State.summary.red = 2; $f.Records.Waivers = @([pscustomobject]@{ head = $headSha; by = 'user'; red = 1; important = 0; deferred = $false; note = 'covers one' }) } 'not-ready' (& $failure 'Footer red=2')
        & $bad 'footer red=1, the waiver covers red=1' { param($f) $f.State.summary.red = 1; $f.Records.Waivers = @([pscustomobject]@{ head = $headSha; by = 'user'; red = 1; important = 0; deferred = $false; note = 'covers it' }) } 'ready'
        & $bad '"fixed" without a commit: the waiver is still needed' { param($f) & $addRow $f 1 (& $row '【重要】' 'a.mjs:1' 'x' '挂账'); & $addRow $f 3 (& $row '【重要】' 'a.mjs:1' 'x' '已修') } 'needs-user'

        # Get-DeferredSevere on its own: which rows are one finding, which round wins, whose tables count
        $tableText = { param($rows) "| 级别 | 位置 | 摘要 | 处置 |`n|---|---|---|---|`n" + (@($rows) -join "`n") }
        $dispItem = { param($round, $text, $noteKind = 'disposition', $itemKind = 'agent') [pscustomobject]@{ Kind = $itemKind; Source = 'issue'; Body = "<!-- harness-agent v1 role=impl kind=$noteKind round=$round head=3f9c2e1 -->`n$text" } }
        $deferredCount = { param($itemList) @(Get-DeferredSevere -Items @($itemList)).Count }
        # every refusal word on its own, behind a word that would count as handled and with a commit; 未修复 reads as 未修 anyway
        foreach ($word in '不改', '不采纳', '挂账', '暂不', '维持', '未采纳', '不修复', '未修复', '未改', '未修', '搁置', '驳回', '不处理', '延后', '暂缓', '忽略') {
            foreach ($handledWord in '已修', '采纳') {
                Add-HarnessCase $cases "deferred findings: the refusal '$word' behind '$handledWord', before the commit" $true ((& $deferredCount (& $dispItem 1 (& $tableText (& $row '【重要】' 'a.mjs:1' 'x' "$handledWord $word abc1234")))) -eq 1)
                Add-HarnessCase $cases "deferred findings: the refusal '$word' behind '$handledWord', after the commit" $true ((& $deferredCount (& $dispItem 1 (& $tableText (& $row '【重要】' 'a.mjs:1' 'x' "$handledWord abc1234，$word")))) -eq 1)
            }
        }
        $deferredRow = & $row '【重要】' 'abcdef1' 'x' '挂账'
        $headerless = "| 【重要】 | thing one | 不改 |`n| 【重要】 | thing two | 已修 abc1234 |"
        Add-HarnessCase $cases 'deferred findings: rows without a header are different findings, and without a disposition column none of them is handled' $true ((& $deferredCount (& $dispItem 1 $headerless)) -eq 2)
        Add-HarnessCase $cases 'deferred findings: a table without a disposition column handles nothing' $true ((& $deferredCount (& $dispItem 1 "| 级别 | 位置 | 摘要 |`n|---|---|---|`n| 【重要】 | a.mjs:1 | 已修 abc1234 |")) -eq 1)
        Add-HarnessCase $cases 'deferred findings: a row cut short before the disposition column handles nothing' $true ((& $deferredCount (& $dispItem 1 (& $tableText '| 【重要】 | a.mjs:1 |'))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: a later row with an unknown word replaces an earlier "fixed"' $true ((& $deferredCount @((& $dispItem 1 (& $tableText (& $row '【重要】' 'a.mjs:1' 'x' '已修 abc1234'))), (& $dispItem 3 (& $tableText (& $row '【重要】' 'a.mjs:1' 'x' '另议'))))) -eq 1)
        # the keys are text from the table: a finding called Values must not hide the others behind the member of the same name
        Add-HarnessCase $cases 'deferred findings: a summary called Values does not hide another finding' $true ((& $deferredCount (& $dispItem 1 (& $tableText @((& $row '【重要】' '' 'Values' '已修 abc1234'), (& $row '【重要】' 'b.mjs:2' 'y' '挂账'))))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: the commit proof in the location column is no proof' $true ((& $deferredCount @((& $dispItem 1 (& $tableText $deferredRow)), (& $dispItem 3 (& $tableText (& $row '【重要】' 'abcdef1' 'x' '已修'))))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: the commit proof in the decision column clears the deferral' $false ((& $deferredCount @((& $dispItem 1 (& $tableText $deferredRow)), (& $dispItem 3 (& $tableText (& $row '【重要】' 'abcdef1' 'x' '已修 abc1234'))))) -ne 0)
        Add-HarnessCase $cases 'deferred findings: a higher round posted first does not hide a deferral posted after it' $true ((& $deferredCount @((& $dispItem 3 (& $tableText (& $row '【重要】' 'abcdef1' 'x' '已修 abc1234'))), (& $dispItem 1 (& $tableText $deferredRow)))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: the same round posted again, "fixed" last: handled' $false ((& $deferredCount @((& $dispItem 2 (& $tableText $deferredRow)), (& $dispItem 2 (& $tableText (& $row '【重要】' 'abcdef1' 'x' '已修 abc1234'))))) -ne 0)
        Add-HarnessCase $cases 'deferred findings: the rows are listed once when both orders name them' $true (@(Get-DeferredSevere -Items @((& $dispItem 1 (& $tableText $deferredRow)))).Count -eq 1)
        Add-HarnessCase $cases 'deferred findings: a deferral of a later round stays even when an earlier round was posted last' $true ((& $deferredCount @((& $dispItem 3 (& $tableText $deferredRow)), (& $dispItem 1 (& $tableText (& $row '【重要】' 'abcdef1' 'x' '已修 abc1234'))))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: a table in a comment that is not a disposition counts for nothing' $false ((& $deferredCount (& $dispItem 1 (& $tableText $deferredRow) 'note')) -ne 0)
        Add-HarnessCase $cases 'deferred findings: a disposition table of a comment that is not ours cannot clear a deferral' $true ((& $deferredCount @((& $dispItem 1 (& $tableText $deferredRow)), (& $dispItem 3 (& $tableText (& $row '【重要】' 'abcdef1' 'x' '已修 abc1234')) 'disposition' 'user'))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: emphasis marks inside the decision word do not hide it' $true ((& $deferredCount (& $dispItem 1 (& $tableText (& $row '【重要】' 'a.mjs:1' 'x' '不**改**'))) ) -eq 1)
        Add-HarnessCase $cases 'deferred findings: emphasis marks inside "fixed" do not hide it either' $false ((& $deferredCount @((& $dispItem 1 (& $tableText $deferredRow)), (& $dispItem 3 (& $tableText (& $row '【重要】' 'abcdef1' 'x' '已**修** abc1234'))))) -ne 0)
        Add-HarnessCase $cases 'table cells lose their emphasis and code marks' $false ((Clear-MdCell '**a_b`c`**') -cne 'abc')
        # two rows that look like one finding do not clear each other, and letter case makes two findings
        Add-HarnessCase $cases 'deferred findings: in one table a row deferred, then the same location and summary fixed: it stays deferred' $true ((& $deferredCount (& $dispItem 1 (& $tableText @((& $row '【重要】' 'a.mjs:1' 'A' '挂账'), (& $row '【重要】' 'a.mjs:1' 'A' '已修 abc1234'))))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: in one table a row fixed, then the same location and summary deferred: deferred' $true ((& $deferredCount (& $dispItem 1 (& $tableText @((& $row '【重要】' 'a.mjs:1' 'A' '已修 abc1234'), (& $row '【重要】' 'a.mjs:1' 'A' '挂账'))))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: summaries that differ only by letter case are two findings' $true ((& $deferredCount @((& $dispItem 1 (& $tableText (& $row '【重要】' 'a.mjs:1' 'Abc' '挂账'))), (& $dispItem 2 (& $tableText (& $row '【重要】' 'a.mjs:1' 'abc' '已修 abc1234'))))) -eq 1)
        # a code fence: a sample, it can show a problem but not that something was handled
        $fence = { param($text) "``````text`n$text`n``````" }
        Add-HarnessCase $cases 'deferred findings: a fixed row inside a code fence is not handled' $true ((& $deferredCount (& $dispItem 1 (& $fence (& $tableText (& $row '【重要】' 'a.mjs:1' 'x' '已修 abc1234'))))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: a fixed row in a code fence does not clear an earlier deferral' $true ((& $deferredCount @((& $dispItem 1 (& $tableText $deferredRow)), (& $dispItem 3 (& $fence (& $tableText (& $row '【重要】' 'abcdef1' 'x' '已修 abc1234')))))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: a tilde fence is a fence too' $true ((& $deferredCount (& $dispItem 1 "~~~`n$(& $tableText (& $row '【重要】' 'a.mjs:1' 'x' '已修 abc1234'))`n~~~")) -eq 1)
        Add-HarnessCase $cases 'deferred findings: the other mark inside a code fence does not close it' $true ((& $deferredCount (& $dispItem 1 (& $fence "~~~`n$(& $tableText (& $row '【重要】' 'a.mjs:1' 'x' '已修 abc1234'))"))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: a fixed row after a closed code fence is handled' $false ((& $deferredCount (& $dispItem 1 "$(& $fence 'sample')`n$(& $tableText (& $row '【重要】' 'a.mjs:1' 'x' '已修 abc1234'))")) -ne 0)
        Add-HarnessCase $cases 'disposition rows: a fence does not carry the header of the table before it' $true (@(Get-DispositionRows "| 级别 | 位置 | 摘要 | 处置 |`n|---|---|---|---|`n| 【重要】 | a:1 | x | 不改 |`n``````t`n| 【重要】 | b:2 | y | 不改 |`n``````" | Where-Object { $null -eq $_.Cols }).Count -eq 1)
        $headerlessRows = @{ Items = @((& $dispItem 1 "| 【重要】 | thing one | 不改 |`n| 【重要】 | thing two | 不改 |" )) }
        $headerlessRows.Items[0].Body = $headerlessRows.Items[0].Body -replace 'head=3f9c2e1', 'head=3f9c2e1 bot-run=77'
        $countFor = { param($wanted, $itemList) @(Get-DispositionShortfalls -Summaries @([pscustomobject]@{ runId = '77'; items = @(1..$wanted | ForEach-Object { [pscustomobject]@{ level = '重要'; text = 'f' } }) }) -Items $itemList) }
        Add-HarnessCase $cases 'one row per finding: rows without a location and a summary are told apart by their whole line' $false (@(& $countFor 2 $headerlessRows.Items).Count -ne 0)
        Add-HarnessCase $cases 'one row per finding: the same row without a location and a summary twice is one row' $true (@(& $countFor 2 @((& $dispItem 1 "| 【重要】 | thing one | 不改 |`n| 【重要】 | thing one | 不改 |") | ForEach-Object { $_.Body = $_.Body -replace 'head=3f9c2e1', 'head=3f9c2e1 bot-run=77'; $_ })).Count -eq 1)

        # CI, texts, infrastructure
        & $bad 'a required check is not success' { param($f) $f.Checks['branch-gate'].conclusion = 'failure' } 'not-ready' (& $failure 'branch-gate is not success')
        & $bad 'a required check is missing' { param($f) $f.Checks.Remove('harness-gate') } 'not-ready' (& $failure 'harness-gate is not success')
        & $bad 'the PR body has no sign-off on the last line' { param($f) $f.Pull.body = ($f.Pull.body -replace 'Signed-off-by: .*\s*$', '') } 'not-ready' (& $failure "body's last line must be")
        & $bad 'the PR title is not type(scope): text' { param($f) $f.Pull.title = 'Add the example module' } 'not-ready' (& $failure 'PR title must be')
        & $bad 'the PR body carries an AI attribution trailer' { param($f) $f.Pull.body = "$($f.Pull.body.TrimEnd())`nCo-Authored" + "-By: a <a@b.c>`n$(Get-HarnessSignoff)" } 'not-ready' (& $failure 'public-text check')
        & $bad 'a local path in one of our comments' { param($f) $i = $f.Items | Where-Object Kind -eq 'agent' | Select-Object -First 1; $i.Body += "`nlog in C:" + '\Users\someone\x.log' } 'not-ready' (& $failure 'Our comment .* public-text')
        & $bad 'a personal needle in one of our comments' { param($f) $i = $f.Items | Where-Object Kind -eq 'agent' | Select-Object -First 1; $i.Body += "`n$(Get-HarnessFakeNeedle)" } 'not-ready' (& $failure 'Our comment .* public-text')
        & $bad 'a task-card number in the PR body' { param($f) $f.Pull.body = $f.Pull.body -replace '## 做了什么', ('## R' + 'H-02') } 'not-ready' (& $failure 'public-text check')
        $infraFile = { param($f, $name = 'scripts/review-bot.mjs', $previous = $null) $f.Files = @([pscustomobject]@{ filename = $name; status = $(if ($previous) { 'renamed' } else { 'modified' }); previous_filename = $previous }); $f.Pull.changed_files = 1 }
        & $bad 'a change to an infrastructure path goes to the user' { param($f) & $infraFile $f } 'needs-user' { param($r) @($r.Needs | Where-Object Kind -eq 'infra').Count -eq 1 -and $r.Infra.Count -eq 1 }
        & $bad 'a workflow renamed away still counts' { param($f) & $infraFile $f 'old/x.yml' '.github/workflows/x.yml' } 'needs-user' { param($r) $r.Infra.Count -ge 1 }
        & $bad 'a change to this maintainer directory goes to the user' { param($f) & $infraFile $f 'scripts/maintainer/pr-merge.ps1' } 'needs-user'
        & $bad 'an approval by the user for this head lets the infrastructure change through' { param($f) & $infraFile $f; $f.Records.Approvals = @([pscustomobject]@{ head = $headSha; by = 'user'; note = 'diff reviewed' }) } 'ready'
        & $bad 'an approval for an older head' { param($f) & $infraFile $f; $f.Records.Approvals = @([pscustomobject]@{ head = 'a' * 40; by = 'user'; note = '' }) } 'needs-user'
        & $bad 'an approval with a 7-character head' { param($f) & $infraFile $f; $f.Records.Approvals = @([pscustomobject]@{ head = $headSha.Substring(0, 7); by = 'user'; note = '' }) } 'needs-user'
        & $bad 'an approval not made by the user' { param($f) & $infraFile $f; $f.Records.Approvals = @([pscustomobject]@{ head = $headSha; by = 'orchestrator'; note = '' }) } 'needs-user'
        # the 40-character rule lives in the record lookup itself: an abbreviated head on both sides is still no record
        $shortHead = $headSha.Substring(0, 7)
        Add-HarnessCase $cases 'a user record never matches an abbreviated head, even when both sides are abbreviated' $true ($null -eq (Get-HeadRecord -List @([pscustomobject]@{ head = $shortHead; by = 'user' }) -ForHead $shortHead))
        Add-HarnessCase $cases 'a user record for the full head is found' $false ($null -eq (Get-HeadRecord -List @([pscustomobject]@{ head = $headSha; by = 'user' }) -ForHead $headSha))
        $x = & $copy
        & $infraFile $x
        $x.Records.Approvals = @([pscustomobject]@{ head = $headSha; by = 'user'; note = 'diff reviewed' })
        $vx = Get-MergeVerdict $x
        Add-HarnessCase $cases 'the verdict prints the approval it relies on, verbatim' $false (-not ($vx.Code -eq 'ready' -and @($vx.ReliedOn | Where-Object { $_.Kind -eq 'approval' -and $_.Record.note -eq 'diff reviewed' -and $_.Record.head -eq $headSha }).Count -eq 1))
        $w = & $copy
        $w.State.summary.important = 1
        $w.Records.Waivers = @([pscustomobject]@{ head = $headSha; by = 'user'; red = 0; important = 1; note = 'user waiver' })
        $vw = Get-MergeVerdict $w
        Add-HarnessCase $cases 'footer important=1 with a user waiver for this head' $false ($vw.Code -ne 'ready')
        Add-HarnessCase $cases 'the verdict prints the waiver it relies on, verbatim' $false (-not (@($vw.ReliedOn).Count -eq 1 -and $vw.ReliedOn[0].Kind -eq 'waiver' -and $vw.ReliedOn[0].Record.note -eq 'user waiver' -and $vw.ReliedOn[0].File -eq $recordsFile))
        $w.Records.Waivers = @([pscustomobject]@{ head = 'a' * 40; by = 'user'; red = 0; important = 1; note = 'other head' })
        Add-HarnessCase $cases 'a waiver for another head does not count' $true ((Get-MergeVerdict $w).Code -eq 'not-ready')
        $w.Records.Waivers = @([pscustomobject]@{ head = $headSha; by = 'orchestrator'; red = 0; important = 1; note = 'orchestrator wrote this' })
        Add-HarnessCase $cases 'footer important=1, the waiver was written by the orchestrator' $true ((Get-MergeVerdict $w).Code -eq 'not-ready')
        $w.Records.Waivers = @([pscustomobject]@{ head = $headSha; by = 'user'; red = 0; important = 0; note = 'covers less than the footer' })
        Add-HarnessCase $cases 'footer important=1, the waiver only covers important=0' $true ((Get-MergeVerdict $w).Code -eq 'not-ready')
        $w.State.summary.important = 0; $w.State.summary.red = 1
        $w.Records.Waivers = @([pscustomobject]@{ head = $headSha; red = 1; important = 0; note = 'no by' })
        Add-HarnessCase $cases 'footer red=1, the waiver has no by' $true ((Get-MergeVerdict $w).Code -eq 'not-ready')

        # infrastructure list
        $touch = { param($names, $status = 'modified') @(Get-InfraTouches -Files @($names | ForEach-Object { [pscustomobject]@{ filename = $_; status = $status } })).Count }
        Add-HarnessCase $cases 'infrastructure list: workflows, hooks, shared libs, CLAUDE.md, the maintainer scripts' $true ((& $touch @('.github/workflows/x.yml', 'scripts/hooks/pre-push', 'scripts/lib/privacy-needles.mjs', 'CLAUDE.md', 'scripts/maintainer/pr-merge.ps1')) -eq 5)
        Add-HarnessCase $cases 'infrastructure list: the review bot and check scripts (new ones too)' $true ((& $touch @('scripts/review-bot.mjs', 'scripts/check-new.mjs') 'added') -eq 2)
        Add-HarnessCase $cases 'infrastructure list: tool pins, bot settings and nested instruction files' $true ((& $touch @('.node-version', '.gitleaks.toml', '.gitleaksignore', '.pr_agent.toml', 'docs/CLAUDE.md', '.claude/settings.json', 'sub/AGENTS.md')) -eq 7)
        Add-HarnessCase $cases 'infrastructure list: sources and docs do not count' $false ((& $touch @('src/tool/x.ts', 'docs/a.md', 'scripts/check-x/y.mjs', 'tests/check-x.mjs')) -gt 0)
        Set-HarnessInfraModule (Join-Path $tmp 'no-such-infra-paths.mjs')
        Add-HarnessCase $cases 'infrastructure list unavailable: no verdict, never a pass' $true (Test-Throws { Get-MergeVerdict $base })
        Set-HarnessInfraModule $null

        # disposition table recognition
        Add-HarnessCase $cases 'disposition rows: the header is recognised by column name' $true ((@(Get-DispositionRows "| 级别 | 位置 | 摘要 | 处置 |`n|---|---|---|---|`n| 【重要】 | a:1 | x | 不改 |")).Count -eq 1)
        Add-HarnessCase $cases 'disposition rows: text between tables resets the header' $true (@(Get-DispositionRows "| 级别 | 位置 | 摘要 | 处置 |`n|---|---|---|---|`n| 【重要】 | a:1 | x | 不改 |`ntext`n| 【重要】 | b:2 | y | 不改 |" | Where-Object { $null -eq $_.Cols }).Count -eq 1)

        # read the way markdown renders it: what a reader of the comment cannot see does not count, what a reader sees does
        $heading = "| 级别 | 位置 | 摘要 | 处置 |`n|---|---|---|---|`n"
        $plainRow = '| 【重要】 | a:1 | x | 不改 |'
        $rowCount = { param($label, $text, $count) Add-HarnessCase $cases "disposition rows: $label" $true (@(Get-DispositionRows $text).Count -eq $count) }
        & $rowCount 'an HTML comment block around a table is not there' "<!--`n$heading$plainRow`n-->" 0
        & $rowCount 'an HTML comment block with blank lines in it is not there' "<!--`n`n$heading$plainRow`n`n-->" 0
        & $rowCount 'a one-line HTML comment around a row is not there' "<!-- $plainRow -->" 0
        & $rowCount 'a comment block indented by 3 columns is not there either' "   <!--`n$heading$plainRow`n-->" 0
        & $rowCount 'a row after a one-line comment counts' "<!-- note -->`n$heading$plainRow" 1
        & $rowCount 'a row after a comment block counts' "<!--`nnote`n-->`n$heading$plainRow" 1
        & $rowCount 'a comment after a row takes nothing away' "$heading$plainRow`n<!-- note -->" 1
        & $rowCount 'a comment that is never closed reaches to the end of the text' "<!--`n$heading$plainRow" 0
        & $rowCount 'a row on the closing line of a comment block is not there' "<!--`nnote`n--> $plainRow" 0
        & $rowCount 'a comment opened in a line of text reaches over the next lines' "text <!-- hidden`n$heading$plainRow`n--> more" 0
        & $rowCount 'a comment opened in a line of text with no end before the blank line is plain text' "text <!-- hidden`n`n$heading$plainRow`n--> more" 1
        & $rowCount 'a comment opened in a table row and not closed on that line is plain text' "$heading| 【重要】 | a:1 | x | 不改 <!-- note |`n| 【重要】 | b:2 | y | 不改 --> |" 2
        & $rowCount 'a comment opened in a header row and not closed on that line is plain text' "| 级别 | 位置 | 摘要 | 处置 <!-- note |`n|---|---|---|---|`n$plainRow`n--> more" 1
        $cutCell = @(Get-DispositionRows "$heading| 【重要】 | a:1 | x | 不改 <!-- 已修 abc1234 | abc1234 --> |")
        Add-HarnessCase $cases 'disposition rows: an inline comment is cut out of its row, with the pipes in it' $true ($cutCell.Count -eq 1 -and $cutCell[0].Cells.Count -eq 6 -and $cutCell[0].Cells[$cutCell[0].Cols['处置']] -ceq '不改' -and $cutCell[0].Line -notmatch 'abc1234')
        $twoComments = @(Get-DispositionRows "$heading| 【重要】 | a:1 | x <!-- p --> | 不改 <!-- q --> |")
        Add-HarnessCase $cases 'disposition rows: two inline comments in one row keep what is between them' $true ($twoComments.Count -eq 1 -and $twoComments[0].Cells[$twoComments[0].Cols['摘要']] -ceq 'x' -and $twoComments[0].Cells[$twoComments[0].Cols['处置']] -ceq '不改')
        $cutAtComment = @(Get-DispositionRows "| 【重要】 | a <!-- hidden`nmore --> | b |")
        Add-HarnessCase $cases 'disposition rows: a comment opened in a row outside a table takes the rest of the line' $true ($cutAtComment.Count -eq 1 -and $cutAtComment[0].Cells[2] -ceq 'a' -and $cutAtComment[0].Line -notmatch 'hidden')
        & $rowCount 'a row indented by 4 spaces is no table row' "    $plainRow" 0
        & $rowCount 'a row indented by a tab is no table row' "`t$plainRow" 0
        & $rowCount 'a row indented by a space and a tab is no table row' " `t$plainRow" 0
        & $rowCount 'a row indented by 3 spaces is a table row' "   $plainRow" 1
        $endedByIndent = @(Get-DispositionRows "$heading$plainRow`n    | 【重要】 | b:2 | y | 不改 |`n| 【重要】 | c:3 | z | 不改 |")
        Add-HarnessCase $cases 'disposition rows: a line indented by 4 columns ends the table' $true ($endedByIndent.Count -eq 2 -and $null -ne $endedByIndent[0].Cols -and $null -eq $endedByIndent[1].Cols)
        # code fences as CommonMark has them. Single quotes keep the backticks as they are
        $mark3 = '```'
        $mark4 = '````'
        $mark5 = '`````'
        $fencedRows = {
            param($label, $text, $count)
            $seen = @(Get-DispositionRows $text)
            Add-HarnessCase $cases "code fence: $label" $true ($seen.Count -eq 1 -and @($seen | Where-Object Fenced).Count -eq $count)
        }
        & $fencedRows 'a line with an info string does not close it' "$mark3 t`n$mark3 no-close`n$plainRow`n$mark3" 1
        & $fencedRows 'fewer marks do not close it' "$mark4`n$mark3`n$plainRow`n$mark4" 1
        & $fencedRows 'as many marks close it' "$mark4`nx`n$mark4`n$plainRow" 0
        & $fencedRows 'more marks close it' "$mark3`nx`n$mark5`n$plainRow" 0
        & $fencedRows 'trailing spaces do not stop it from closing' "$mark3`nx`n$mark3   `n$plainRow" 0
        & $fencedRows 'one that is never closed reaches to the end of the text' "$mark3 t`n$plainRow" 1
        & $fencedRows 'a tilde fence takes any info string' "~~~ a ~~~ ``b`n$plainRow`n~~~" 1
        & $fencedRows 'a tilde line with an info string does not close it' "~~~`n~~~ no-close`n$plainRow" 1
        & $fencedRows 'a backtick in the info string: no fence' "$mark3 a``b`n$plainRow" 0
        & $fencedRows 'two marks: no fence' "````t`n$plainRow" 0
        & $fencedRows 'indented by 4 columns: no fence' "    $mark3`n$plainRow" 0
        & $fencedRows 'indented by 3 columns: a fence' "   $mark3`n$plainRow" 1
        & $fencedRows 'a closing line indented by 4 columns does not close it' "$mark3`n    $mark3`n$plainRow" 1
        & $fencedRows 'a closing line indented by 3 columns closes it' "$mark3`n   $mark3`n$plainRow" 0
        & $fencedRows 'a comment mark in a fence is text: the fence still closes' "$mark3`n<!-- x`n$mark3`n$plainRow" 0
        & $fencedRows 'a fence mark in a comment is text: no fence opens' "<!--`n$mark3`n-->`n$plainRow" 0
        & $fencedRows 'a row indented by 4 columns in a fence is a sample all the same' "$mark3`n    $plainRow`n$mark3" 1
        # a header row only with a delimiter row right below it
        Add-HarnessCase $cases 'deferred findings: a row whose text starts like a column name is no header without a delimiter row' $true ((& $deferredCount (& $dispItem 1 '| 【重要】 | 处置错了 | 挂账 |')) -eq 1)
        & $rowCount 'a row that looks like a header, and the next one: two rows' "| 【重要】 | 位置不对 | 挂账 |`n| 【重要】 | b:2 | 不改 |" 2
        Add-HarnessCase $cases 'deferred findings: a cell that is only the level word, no header, no brackets' $true ((& $deferredCount (& $dispItem 1 '| 重要 | a.ps1:1 | 级别判错 | 挂账 |')) -eq 1)
        Add-HarnessCase $cases 'deferred findings: a cell that is only the other level word' $true ((& $deferredCount (& $dispItem 1 '| 红旗 | a.ps1:1 | 位置不对 | 挂账 |')) -eq 1)
        $headerCase = {
            param($label, $text, $isHeader)
            $seen = @(Get-DispositionRows $text)
            Add-HarnessCase $cases "table header: $label" $true ($(if ($isHeader) { $seen.Count -eq 1 -and $null -ne $seen[0].Cols } else { @($seen | Where-Object { $null -ne $_.Cols }).Count -eq 0 }))
        }
        & $rowCount 'a first row without known column names is a row, the delimiter row under it is not' "| x | y |`n| - | - |`n| 【重要】 | 不改 |" 2
        & $headerCase 'an escaped pipe in a header cell is no cell boundary' "| 级别 \| x | 处置 |`n|---|---|`n| 【重要】 | 不改 |" $true
        & $headerCase 'a delimiter row of single hyphens' "| 级别 | 处置 |`n| - | - |`n| 【重要】 | 不改 |" $true
        & $headerCase 'a delimiter row with colons' "| 级别 | 处置 |`n|:--|:-:|`n| 【重要】 | 不改 |" $true
        & $headerCase 'a delimiter row without outer pipes' "| 级别 | 处置 |`n--|--`n| 【重要】 | 不改 |" $true
        & $headerCase 'a delimiter row indented by 3 columns' "| 级别 | 处置 |`n   |---|---|`n| 【重要】 | 不改 |" $true
        & $headerCase 'a delimiter row of another number of cells' "| 级别 | 位置 | 摘要 | 处置 |`n|---|---|`n| 【重要】 | a | x | 不改 |" $false
        & $headerCase 'a blank line before the delimiter row' "| 级别 | 处置 |`n`n|---|---|`n| 【重要】 | 不改 |" $false
        & $headerCase 'a delimiter row without a pipe' "| 级别 |`n---`n| 【重要】 |" $false
        & $headerCase 'a delimiter row indented by 4 columns' "| 级别 | 处置 |`n    |---|---|`n| 【重要】 | 不改 |" $false
        & $headerCase 'a delimiter row with something else in a cell' "| 级别 | 处置 |`n|---|-a-|`n| 【重要】 | 不改 |" $false
        & $headerCase 'a second header in the same table' "| x | y |`n|---|---|`n| 级别 | 处置 |`n|---|---|`n| 【重要】 | 不改 |" $false
        # what ends a table, and that the next table has its own header
        $otherRow = '| 【重要】 | b:2 | y | 不改 |'
        $headersOf = {
            param($label, $text, $expected)
            Add-HarnessCase $cases "table state: $label" $true ((@(Get-DispositionRows $text | ForEach-Object { $null -ne $_.Cols }) -join ',') -ceq $expected)
        }
        & $headersOf 'a comment ends the table' "$heading$plainRow`n<!-- x -->`n$otherRow" 'True,False'
        & $headersOf 'a table after a comment has its own header' "$heading$plainRow`n<!-- x -->`n$heading$plainRow" 'True,True'
        & $headersOf 'a table after a fence has its own header' "$heading$plainRow`n$mark3`nx`n$mark3`n$heading$plainRow" 'True,True'
        & $headersOf 'the header of a table in a fence ends with the fence' "$mark3`n$heading$plainRow`n$mark3`n$otherRow" 'True,False'
        & $headersOf 'a table in a fence after a table has its own header' "$heading$plainRow`n$mark3`n$heading$plainRow`n$mark3" 'True,True'
        & $headersOf 'a table after a fence with a table in it has its own header' "$mark3`n$heading$plainRow`n$mark3`n$heading$plainRow" 'True,True'
        & $headersOf 'text in a fence ends the table in it' "$mark3`n$heading$plainRow`nx`n$otherRow`n$mark3" 'True,False'
        & $headersOf 'a second table in a fence has its own header' "$mark3`n$heading$plainRow`nx`n$heading$plainRow`n$mark3" 'True,True'
        & $headersOf 'a table after text has its own header' "$heading$plainRow`ntext`n$heading$plainRow" 'True,True'
        & $headersOf 'a table after an indented line has its own header' "$heading$plainRow`n    x`n$heading$plainRow" 'True,True'
        Add-HarnessCase $cases 'deferred findings: a table in an HTML comment shows nothing as handled' $true ((& $deferredCount @((& $dispItem 1 (& $tableText $deferredRow)), (& $dispItem 3 "<!--`n$(& $tableText (& $row '【重要】' 'a.mjs:1' 'x' '已修 abc1234'))`n-->"))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: the agent marker in the first line is read on its own' $true ((Get-AgentMarker (& $dispItem 1 "<!-- note -->`n$plainRow").Body).Kind -ceq 'disposition')

        # the tables people really post: extra columns, a note after the column name; columns are found by name, not by position
        $wideHeader = "| # | 来源 | 级别 | 位置 | 摘要 | 依据 | 处置（采纳 / 不改 / 挂账） | commit 或理由 / issue |`n|---|---|---|---|---|---|---|---|`n"
        $wideRow = { param($level, $decision, $proof, $basis = 'review') "| 1 | bot | $level | a.mjs:1 | thing | $basis | $decision | $proof |" }
        $wide = @(Get-DispositionRows ($wideHeader + (& $wideRow '【重要】' '不改' '设计如此')))
        Add-HarnessCase $cases 'disposition rows: a table with extra columns is read by column name' $true (
            $wide.Count -eq 1 -and $wide[0].Cells[$wide[0].Cols['级别']] -eq '【重要】' -and $wide[0].Cells[$wide[0].Cols['位置']] -eq 'a.mjs:1' -and
            $wide[0].Cells[$wide[0].Cols['摘要']] -eq 'thing' -and $wide[0].Cells[$wide[0].Cols['处置']] -eq '不改')
        Add-HarnessCase $cases 'disposition rows: a decision column header with a note after the name is the decision column' $true ($wide[0].Cols['处置'] - $wide[0].Cols['级别'] -eq 4)
        $lateName = @(Get-DispositionRows "| 原位置 | 级别 | 位置 | 摘要 | 处置 |`n|---|---|---|---|---|`n| old | 【重要】 | a:1 | x | 不改 |")
        Add-HarnessCase $cases 'disposition rows: a header cell that only contains a column name later is not that column' $true ($lateName.Count -eq 1 -and $lateName[0].Cols['位置'] - $lateName[0].Cols['级别'] -eq 1)
        Add-HarnessCase $cases 'deferred findings: a refusal in a table with extra columns is found' $true ((& $deferredCount (& $dispItem 1 ($wideHeader + (& $wideRow '【重要】' '不改' '设计如此')))) -eq 1)
        Add-HarnessCase $cases 'deferred findings: the level comes from the level column, not from a word in another column' $false ((& $deferredCount (& $dispItem 1 ($wideHeader + (& $wideRow '【建议】' '不改' '设计如此' '非【重要】')))) -ne 0)
        Add-HarnessCase $cases 'deferred findings: a fix with the commit in a column right of the decision clears the refusal' $false (
            (& $deferredCount @((& $dispItem 1 ($wideHeader + (& $wideRow '【重要】' '不改' '设计如此'))), (& $dispItem 3 ($wideHeader + (& $wideRow '【重要】' '已修' 'abc1234'))))) -ne 0)
        Add-HarnessCase $cases 'deferred findings: a fix whose commit is missing leaves the refusal' $true (
            (& $deferredCount @((& $dispItem 1 ($wideHeader + (& $wideRow '【重要】' '不改' '设计如此'))), (& $dispItem 3 ($wideHeader + (& $wideRow '【重要】' '已修' '见上'))))) -eq 1)

        # ---- the merge action --------------------------------------------------------------------
        $msg = New-MergeMessage -PrData $pull -Summary 'Adds the example module.'
        Add-HarnessCase $cases 'squash message: subject with (#7), the one sign-off last' $false (-not ($msg.Title -match '\(#7\)$' -and $msg.Body -match "`n`nSigned-off-by: [^\n]+$" -and ([regex]::Matches($msg.Body, 'Signed-off-by')).Count -eq 1))
        Add-HarnessCase $cases 'squash message: the summary carries its own Signed-off-by' $true ((Get-ThrownMessage { New-MergeMessage -PrData $pull -Summary "x`n`n$(Get-HarnessSignoff)" }) -match 'exactly one Signed-off-by line')
        Add-HarnessCase $cases 'squash message: the summary carries an AI attribution trailer' $true ((Get-ThrownMessage { New-MergeMessage -PrData $pull -Summary ("x`n`nCo-Authored" + '-By: a <a@b.c>') }) -match 'AI attribution trailers are not allowed')
        Add-HarnessCase $cases 'squash message: the summary carries an AI session trailer' $true ((Get-ThrownMessage { New-MergeMessage -PrData $pull -Summary ("x`n`nCla" + 'ude-Session: https://example.invalid/s') }) -match 'AI attribution trailers are not allowed')
        Add-HarnessCase $cases 'squash message: the summary is empty' $true (Test-Throws { New-MergeMessage -PrData $pull -Summary '  ' })
        Add-HarnessCase $cases 'squash message: a local path in the summary' $true (Test-Throws { New-MergeMessage -PrData $pull -Summary ('see C:' + '\Users\someone\x') })
        $escape = [string][char]27
        Add-HarnessCase $cases 'squash message: a local path split by an escape character is refused, the rules must not read around it' $true ((Get-ThrownMessage { New-MergeMessage -PrData $pull -Summary ('see C:' + $escape + '\Users\someone\x') }) -match 'control character U\+001B')
        $needleText = Get-HarnessFakeNeedle
        Add-HarnessCase $cases 'squash message: a personal needle split by an escape character is refused' $true ((Get-ThrownMessage { New-MergeMessage -PrData $pull -Summary ($needleText.Substring(0, 5) + $escape + $needleText.Substring(5)) }) -match 'control character U\+001B')
        Add-HarnessCase $cases 'squash message: an escape character in the PR title is refused' $true ((Get-ThrownMessage { $titled = Copy-HarnessObject $pull; $titled.title = "feat(x): a$($escape)b"; New-MergeMessage -PrData $titled -Summary 'x' }) -match 'control character U\+001B')
        # characters nobody sees: the rule that would catch the path reads the text without them
        foreach ($hidden in @(@{ Name = 'zero-width space'; Code = 0x200B }, @{ Name = 'soft hyphen'; Code = 0x00AD }, @{ Name = 'direction override'; Code = 0x202E }, @{ Name = 'word joiner'; Code = 0x2060 }, @{ Name = 'combining grapheme joiner'; Code = 0x034F }, @{ Name = 'variation selector'; Code = 0xFE0F }, @{ Name = 'Hangul filler'; Code = 0x3164 }, @{ Name = 'Mongolian variation selector'; Code = 0x180B }, @{ Name = 'halfwidth Hangul filler'; Code = 0xFFA0 }, @{ Name = 'line separator'; Code = 0x2028 }, @{ Name = 'paragraph separator'; Code = 0x2029 })) {
            Add-HarnessCase $cases "squash message: a local path split by a $($hidden.Name) is found" $true ((Get-ThrownMessage { New-MergeMessage -PrData $pull -Summary ('see C:' + '\Us' + [string][char]$hidden.Code + 'ers\someone\x') }) -match '\[win-user-path\]')
        }
        foreach ($control in @(@{ Name = 'C1 control character'; Text = [string][char]0x0085; Code = '0085' }, @{ Name = 'CR without LF'; Text = "`r"; Code = '000D' })) {
            Add-HarnessCase $cases "squash message: a local path split by a $($control.Name) is refused" $true ((Get-ThrownMessage { New-MergeMessage -PrData $pull -Summary ('see C:' + '\Us' + $control.Text + 'ers\someone\x') }) -match "control character U\+$($control.Code)")
        }
        # what goes out is what the rules read, the history of the line keeps it for good
        Add-HarnessCase $cases 'squash message: an invisible character of the summary is not sent' $true (Test-HarnessSameText (New-MergeMessage -PrData $pull -Summary "Ad$($zeroWidth)ds it.").Body "Adds it.`n`n$(Get-HarnessSignoff)")
        $hiddenTitled = Copy-HarnessObject $pull
        $hiddenTitled.title = "feat(x): a$($zeroWidth)b"
        Add-HarnessCase $cases 'squash message: an invisible character of the PR title is not sent' $true (Test-HarnessSameText (New-MergeMessage -PrData $hiddenTitled -Summary 'x').Title 'feat(x): ab (#7)')
        Add-HarnessCase $cases 'squash message: a summary of nothing but invisible characters is empty' $true ((Get-ThrownMessage { New-MergeMessage -PrData $pull -Summary "$zeroWidth$zeroWidth" }) -match 'The summary paragraph is empty')
        $crlfMessage = New-MergeMessage -PrData $pull -Summary "Line one.`r`nLine two.`r`n"
        Add-HarnessCase $cases 'squash message: CRLF in the summary becomes LF' $false ($crlfMessage.Body -cnotmatch "^Line one\.`nLine two\.`n`nSigned-off-by: ")
        $squashOk = "feat(example): add the example module (#7)`n`nAdds it.`n`n$(Get-HarnessSignoff)"
        # the shape GitHub really writes for a squash: the numbered noreply address of the account, committer the web flow
        $squashAuthor = '140901583+DLsnows@users.noreply.github.com'
        $squashFor = { param($text, $authorMail = $squashAuthor, $authorLabel = 'DLsnows') try { (@(Get-SquashProblems -Number '7' -AuthorName $authorLabel -AuthorEmail $authorMail -CommitterEmail 'noreply@github.com' -Message $text)) -join ' | ' } catch { "threw: $($_.Exception.Message)" } }
        Add-HarnessCase $cases 'squash commit: a clean message has no problem' $false ((& $squashFor $squashOk) -ne '')
        Add-HarnessCase $cases 'squash commit: the local identity of the maintainer is on the list too' $false ((& $squashFor $squashOk 'noreply@synchain.ca') -ne '')
        Add-HarnessCase $cases 'squash commit: the author email is compared without regard to case' $false ((& $squashFor $squashOk $squashAuthor.ToLowerInvariant()) -ne '')
        Add-HarnessCase $cases 'squash commit: another author email' $true ((& $squashFor $squashOk 'someone@example.com') -match 'author is DLsnows <someone@example\.com>')
        Add-HarnessCase $cases 'squash commit: the right email under another name' $true ((& $squashFor $squashOk $squashAuthor 'someone-else') -match 'author is someone-else')
        Add-HarnessCase $cases 'squash commit: the author name with a zero-width space behind it' $true ((& $squashFor $squashOk $squashAuthor "DLsnows$zeroWidth") -match 'author is DLsnows')
        Add-HarnessCase $cases 'squash commit: the author email with a zero-width space behind it' $true ((& $squashFor $squashOk "$squashAuthor$zeroWidth") -match 'author is DLsnows')
        Add-HarnessCase $cases 'squash commit: the committer email with a zero-width space behind it' $true ((@(Get-SquashProblems -Number '7' -AuthorName 'DLsnows' -AuthorEmail $squashAuthor -CommitterEmail "noreply@github.com$zeroWidth" -Message $squashOk) -join ' | ') -match 'committer email')
        Add-HarnessCase $cases 'squash commit: a control character in the merged message is one more problem, not a crash' $true ((& $squashFor "feat(example): add (#7)`n`nAd$([char]27)ds it.`n`n$(Get-HarnessSignoff)") -match 'control character U\+001B')
        Add-HarnessCase $cases 'squash commit: a local path in the merged message is found by the public-text check' $true ((& $squashFor ("feat(example): add the example module (#7)`n`nsee C:" + '\Users\someone\x' + "`n`n$(Get-HarnessSignoff)")) -match 'failed the public-text check')
        $badTitle = Copy-HarnessObject $pull
        $badTitle.title = 'Add the example module'
        Add-HarnessCase $cases 'squash message: a PR title that is not type(scope): text' $true (Test-Throws { New-MergeMessage -PrData $badTitle -Summary 'x' })
        $summaryPath = Join-Path $tmp 'summary.txt'
        Set-Content -LiteralPath $summaryPath -Value 'Adds the example module.' -Encoding utf8NoBOM
        $put = [System.Collections.Generic.List[object]]::new()
        $readback = @{ Mode = ''; Author = 'DLsnows'; AuthorEmail = '140901583+DLsnows@users.noreply.github.com'; CommitterEmail = 'noreply@github.com' }
        $putMode = @{ Refuse = $false }
        $routes.Insert(0, 'api -X PUT \S+/pulls/7/merge --input', {
                param($argv)
                $put.Add((Get-Content -Raw ($argv[-1]) | ConvertFrom-Json))
                if ($putMode.Refuse) { return @{ merged = $false; message = 'Base branch was modified' } }
                @{ merged = $true; sha = 'f' * 40 }
            })
        $routes.Insert(1, "repos/\S+/commits/f{40}$", {
                $sent = $put[-1]
                $text = "$(Get-HarnessProp $sent 'commit_title')`n`n$(Get-HarnessProp $sent 'commit_message')"
                if ($readback.Mode -eq 'title') { $text = $text -replace '^[^\n]+', 'something else (#7)' }
                if ($readback.Mode -eq 'body') { $text = $text -replace 'Adds the example module\.', 'Adds something else.' }
                if ($readback.Mode -eq 'hidden') { $text = $text -replace 'Adds the example module\.', "Adds the example module.$zeroWidth" }
                @{ sha = 'f' * 40; commit = @{ message = $text; author = @{ name = $readback.Author; email = $readback.AuthorEmail }; committer = @{ name = 'GitHub'; email = $readback.CommitterEmail } } }
            })
        Set-HarnessFake (New-HarnessFake -Routes $routes -Log $log)
        $lockLog.Clear()
        Get-MergeVerdict (Get-MergeFacts -Number 7) | Out-Null
        Add-HarnessCase $cases '-Check takes the git lock, not the merge lock' $false ($lockLog -contains 'merge' -or -not ($lockLog -contains 'git'))
        $lockLog.Clear()
        $log.Clear()
        $done = try { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile } catch { "threw: $($_.Exception.Message)" }
        Add-HarnessCase $cases '-Merge holds the merge lock for its whole run (merge first, then git)' $false (-not ($lockLog.Count -ge 2 -and $lockLog[0] -eq 'merge' -and $lockLog -contains 'git'))
        $sent = $put[-1]
        Add-HarnessCase $cases '-Merge: squash, sha = the checked head, subject (#7), the body ends with the one sign-off' $false (-not (
                (Get-HarnessProp $sent 'merge_method') -eq 'squash' -and (Get-HarnessProp $sent 'sha') -eq $headSha -and (Get-HarnessProp $sent 'commit_title') -match '\(#7\)$' -and
                (Get-HarnessProp $sent 'commit_message') -match "^Adds the example module\.`n`nSigned-off-by: [^\n]+$" -and ([string]$done -match 'Merged #7')))
        $putAt = @(0..($log.Count - 1) | Where-Object { $log[$_] -match 'X PUT \S+/pulls/7/merge' })
        $readAt = @(0..($log.Count - 1) | Where-Object { $log[$_] -match 'api repos/\S+/commits/f{40}$' })
        Add-HarnessCase $cases '-Merge: one merge request, and the merge commit is read back after it' $false (-not ($putAt.Count -eq 1 -and $readAt.Count -eq 1 -and $readAt[0] -gt $putAt[0]))
        $crlfSummary = Join-Path $tmp 'crlf.txt'
        [IO.File]::WriteAllText($crlfSummary, "Line one.`r`nLine two.`r`n", [Text.UTF8Encoding]::new($false))
        Add-HarnessCase $cases '-Merge: a summary file with CRLF passes the read-back' $false ([bool](& $messageOf { Invoke-Merge -Number 7 -SummaryFile $crlfSummary -RecordsPath $recordsFile }))
        $hiddenSummary = Join-Path $tmp 'hidden.txt'
        [IO.File]::WriteAllText($hiddenSummary, "Adds the$zeroWidth example module.", [Text.UTF8Encoding]::new($false))
        $hiddenSaid = & $messageOf { Invoke-Merge -Number 7 -SummaryFile $hiddenSummary -RecordsPath $recordsFile }
        Add-HarnessCase $cases '-Merge: an invisible character of the summary is not sent, and the read-back passes' $true ($null -eq $hiddenSaid -and (Test-HarnessSameText (Get-HarnessProp $put[-1] 'commit_message') "Adds the example module.`n`n$(Get-HarnessSignoff)"))
        # the summary file is read like every body file
        $bomSummary = Join-Path $tmp 'bom.txt'
        [IO.File]::WriteAllBytes($bomSummary, [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('Adds the example module.')))
        $bomSaid = & $messageOf { Invoke-Merge -Number 7 -SummaryFile $bomSummary -RecordsPath $recordsFile }
        Add-HarnessCase $cases '-Merge: a byte order mark of the summary file is not sent' $true ($null -eq $bomSaid -and (Test-HarnessSameText (Get-HarnessProp $put[-1] 'commit_message') "Adds the example module.`n`n$(Get-HarnessSignoff)"))
        Push-Location -LiteralPath $tmp
        try { $relativeSaid = & $messageOf { Invoke-Merge -Number 7 -SummaryFile (Split-Path -Leaf $hiddenSummary) -RecordsPath $recordsFile } } finally { Pop-Location }
        Add-HarnessCase $cases '-Merge: a relative summary file means the current PowerShell location' $false ($null -ne $relativeSaid)
        $n = $put.Count
        $latinSummary = Join-Path $tmp 'latin.txt'
        [IO.File]::WriteAllBytes($latinSummary, [byte[]](0x41, 0xC3, 0x28))
        Add-HarnessCase $cases '-Merge: a summary file that is not UTF-8 is refused before anything is sent' $true (((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $latinSummary -RecordsPath $recordsFile }) -match '-SummaryFile is not valid UTF-8') -and $put.Count -eq $n)
        foreach ($mode in 'title', 'body', 'hidden') {
            $readback.Mode = $mode
            $found = & $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }
            Add-HarnessCase $cases "-Merge: the read-back finds a different $mode" $true ([bool]$found -and $found -match 'differ from what was sent')
        }
        $readback.Mode = ''
        $n = $put.Count
        $putMode.Refuse = $true
        $log.Clear()
        $refusedMerge = & $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }
        $putMode.Refuse = $false
        Add-HarnessCase $cases '-Merge: GitHub refuses the merge: reported as not merged, no read-back' $true ($refusedMerge -match 'The merge did not succeed: Base branch was modified' -and $put.Count -eq $n + 1 -and -not @($log | Where-Object { $_ -match 'api repos/\S+/commits/' }).Count)
        $readback.Author = 'someone-else'
        Add-HarnessCase $cases '-Merge: the read-back finds another author' $true ((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }) -match 'author is')
        $readback.Author = 'DLsnows'; $readback.CommitterEmail = 'someone@example.com'
        Add-HarnessCase $cases '-Merge: the read-back finds another committer' $true ((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }) -match 'committer email')
        $readback.CommitterEmail = 'noreply@github.com'
        $n = $put.Count
        Add-HarnessCase $cases '-Merge: no summary file' $true ((Test-Throws { Invoke-Merge -Number 7 -SummaryFile (Join-Path $tmp 'nope.txt') -RecordsPath $recordsFile }) -and $put.Count -eq $n)
        $selfSigned = Join-Path $tmp 'signed.txt'
        Set-Content -LiteralPath $selfSigned -Value "Adds it.`n`n$(Get-HarnessSignoff)" -Encoding utf8NoBOM
        Add-HarnessCase $cases '-Merge: a summary that carries its own Signed-off-by is refused before anything is sent' $true ((Test-Throws { Invoke-Merge -Number 7 -SummaryFile $selfSigned -RecordsPath $recordsFile }) -and $put.Count -eq $n)
        $escaped = Join-Path $tmp 'escaped.txt'
        [IO.File]::WriteAllText($escaped, ('see C:' + $escape + '\Users\someone\x'), [Text.UTF8Encoding]::new($false))
        Add-HarnessCase $cases '-Merge: a summary with a control character is refused before anything is sent' $true (((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $escaped -RecordsPath $recordsFile }) -match 'control character U\+001B') -and $put.Count -eq $n)
        $titleRoutes = $routes
        $moved = @{ Seen = 0 }
        $titleRoutes['pulls/7$'] = { $moved.Seen++; $p = Copy-HarnessObject $prFixture; if ($moved.Seen -ge 3) { $p.title = "$($p.title) (edited)" }; $p }
        Set-HarnessFake (New-HarnessFake -Routes $titleRoutes -Log $log)
        Add-HarnessCase $cases '-Merge: the PR title changed after the squash message was built' $true ((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }) -match 'title changed' -and $put.Count -eq $n)
        $moved.Seen = 0
        $titleRoutes['pulls/7$'] = { $moved.Seen++; $p = Copy-HarnessObject $prFixture; if ($moved.Seen -ge 3) { $p.base.ref = 'dev' }; $p }
        Add-HarnessCase $cases '-Merge: the base of the PR changed right before the merge request' $true (((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }) -match 'changed after the check \(base dev') -and $put.Count -eq $n)
        $moved.Seen = 0
        $titleRoutes['pulls/7$'] = { $moved.Seen++; $p = Copy-HarnessObject $prFixture; if ($moved.Seen -ge 3) { $p.state = 'closed' }; $p }
        Add-HarnessCase $cases '-Merge: the PR was closed right before the merge request' $true (((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }) -match 'changed after the check \(base feature/v1, state closed') -and $put.Count -eq $n)
        $moved.Seen = 0
        $titleRoutes['pulls/7$'] = { $moved.Seen++; $p = Copy-HarnessObject $prFixture; if ($moved.Seen -ge 3) { $p.base.ref = "feature/v1$zeroWidth" }; $p }
        Add-HarnessCase $cases '-Merge: a zero-width space behind the base right before the merge request' $true (((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }) -match 'changed after the check') -and $put.Count -eq $n)
        $moved.Seen = 0
        $titleRoutes['pulls/7$'] = { $moved.Seen++; $p = Copy-HarnessObject $prFixture; if ($moved.Seen -ge 3) { $p.state = "open$zeroWidth" }; $p }
        Add-HarnessCase $cases '-Merge: a zero-width space behind the state right before the merge request' $true (((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }) -match 'changed after the check') -and $put.Count -eq $n)
        $moved.Seen = 0
        $titleRoutes['pulls/7$'] = { $moved.Seen++; $p = Copy-HarnessObject $prFixture; if ($moved.Seen -ge 3) { $p.title = "$($p.title)$zeroWidth" }; $p }
        Add-HarnessCase $cases '-Merge: a zero-width space added to the title after the squash message was built' $true (((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }) -match 'title changed') -and $put.Count -eq $n)
        $moved.Seen = -100
        $titleRoutes['pulls/7$'] = { $moved.Seen++; $p = Copy-HarnessObject $prFixture; if ($moved.Seen -ge -97) { $p.head.sha = 'a' * 40 }; $p }
        Add-HarnessCase $cases '-Merge: the PR head moved after the check' $true (((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }) -match 'head moved|Cannot merge') -and $put.Count -eq $n)
        $moved.Seen = 0
        $titleRoutes['pulls/7$'] = { $moved.Seen++; $p = Copy-HarnessObject $prFixture; if ($moved.Seen -eq 1) { $p.head.sha = 'a' * 40 }; $p }
        Add-HarnessCase $cases '-Merge: the PR head was another one when the message was built, the check saw the head back' $true (((& $messageOf { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile }) -match 'head moved after the check') -and $put.Count -eq $n)
        $routes['pulls/7$'] = {
            if ($pullState.Nulls -gt 0) { $pullState.Nulls--; $p = Copy-HarnessObject $prFixture; $p.mergeable = $null; $p.mergeable_state = 'unknown'; return $p }
            $prFixture
        }
        Set-HarnessFake (New-HarnessFake -Routes $routes -Log $log)
        # an infrastructure PR is only merged with the user's approval of this very head
        $savedPrFiles = $prFiles
        $prFiles = @([pscustomobject]@{ filename = '.github/workflows/x.yml'; status = 'modified' })
        $savedChanged = $prFixture.changed_files
        $prFixture.changed_files = 1
        $n = $put.Count
        Add-HarnessCase $cases '-Merge: an infrastructure PR without an approval record is not merged' $true ((Test-Throws { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile | Out-Null }) -and $put.Count -eq $n)
        Set-Content -LiteralPath $recordsFile -Value (ConvertTo-Json -Depth 10 @{ approvals = @{ '7' = @(@{ head = 'a' * 40; by = 'user'; note = 'approved H' }) } })
        Add-HarnessCase $cases '-Merge: approval for H, the PR is at H2: not merged' $true ((Test-Throws { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile | Out-Null }) -and $put.Count -eq $n)
        Set-Content -LiteralPath $recordsFile -Value (ConvertTo-Json -Depth 10 @{ approvals = @{ '7' = @(@{ head = $headSha; by = 'user'; note = 'approved exactly this head' }) } })
        $mout = @(Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile)
        Add-HarnessCase $cases '-Merge: with an approval for the current head, merged with sha pinned to it' $false (-not ($put.Count -eq $n + 1 -and (Get-HarnessProp $put[-1] 'sha') -eq $headSha))
        Add-HarnessCase $cases '-Merge: prints the approval record it relies on, verbatim' $false (-not (@($mout | Where-Object { $_ -match '^User record relied on \(approval' -and $_ -match 'approved exactly this head' -and $_ -match $headSha }).Count -eq 1))
        $prFixture.mergeable_state = 'dirty'
        Add-HarnessCase $cases '-Merge: not ready, an approval record does not help' $true ((Test-Throws { Invoke-Merge -Number 7 -SummaryFile $summaryPath -RecordsPath $recordsFile | Out-Null }) -and $put.Count -eq $n + 1)
        $prFixture.mergeable_state = 'clean'
        $prFixture.changed_files = $savedChanged
        $prFiles = $savedPrFiles
        Set-Content -LiteralPath $recordsFile -Value '{}'

        # a PR other than #7: the number comes from the arguments everywhere
        $otherPull = Copy-HarnessObject $pull
        $otherPull.number = 42
        $otherRoutes = [ordered]@{}
        foreach ($routeKey in $routes.get_Keys()) { $otherRoutes[($routeKey -replace 'pulls/7', 'pulls/42' -replace 'issues/7', 'issues/42' -replace 'origin/pr/7', 'origin/pr/42')] = $routes[$routeKey] }
        $otherRoutes['pulls/42$'] = { $otherPull }
        Set-HarnessFake (New-HarnessFake -Routes $otherRoutes -Log $log)
        $answers.PrNumber = 42
        $log.Clear()
        $n = $put.Count
        $otherDone = & $messageOf { $otherLine = Invoke-Merge -Number 42 -SummaryFile $summaryPath -RecordsPath $recordsFile; if ($otherLine -notmatch 'Merged #42') { throw "unexpected: $otherLine" } }
        $answers.PrNumber = 7
        Set-HarnessFake (New-HarnessFake -Routes $routes -Log $log)
        Add-HarnessCase $cases 'a PR other than #7: facts, check and merge all use its number' $false (-not (
                -not $otherDone -and $put.Count -eq $n + 1 -and (Get-HarnessProp $put[-1] 'commit_title') -match '\(#42\)$' -and
                @($log | Where-Object { $_ -match 'fetch .*\+refs/pull/42/head:refs/remotes/origin/pr/42' }).Count -ge 1 -and
                @($log | Where-Object { $_ -match 'pulls/7|issues/7|pr/7' }).Count -eq 0))

        # ---- the command line ------------------------------------------------------------------
        $entryRun = {
            param([hashtable]$entryArgs)
            $log.Clear()
            $putBefore = $put.Count
            $said = & { try { @(Invoke-Entry @entryArgs) } catch { "threw: $($_.Exception.Message)" } }
            [pscustomobject]@{ Said = @($said) -join "`n"; Code = $script:EntryCode; Sent = $put.Count - $putBefore; Gh = @($log | Where-Object { $_ -match '^gh ' }) }
        }
        $identityFirst = { param($entryResult) $entryResult.Gh.Count -gt 2 -and $entryResult.Gh[0] -ceq 'gh auth token --user DLsnows' -and $entryResult.Gh[1] -ceq 'gh api user --jq .login' }
        $checkArgs = @{ Check = $true; Pr = 7; WaiverFile = $recordsFile }
        $checked = & $entryRun $checkArgs
        Add-HarnessCase $cases 'entry: -Check: the first gh calls are the identity check, one JSON line, exit 0' $false (-not ((& $identityFirst $checked) -and $checked.Code -eq 0 -and (ConvertFrom-Json -InputObject $checked.Said -Depth 100).Code -eq 'ready'))
        $identity.Login = 'someone-else'
        $checkWrong = & $entryRun $checkArgs
        $identity.Login = 'DLsnows'
        Add-HarnessCase $cases 'entry: -Check with another account: refused, GitHub is not asked anything else' $true ($checkWrong.Said -match 'resolves to someone-else' -and $checkWrong.Gh.Count -eq 2)
        $prFixture.draft = $true
        $checkNotReady = & $entryRun $checkArgs
        $prFixture.draft = $false
        Add-HarnessCase $cases 'entry: -Check, not ready: exit 1' $true ($checkNotReady.Code -eq 1 -and (ConvertFrom-Json -InputObject $checkNotReady.Said -Depth 100).Code -eq 'not-ready')
        $savedPrFiles = $prFiles
        $prFiles = @([pscustomobject]@{ filename = '.github/workflows/x.yml'; status = 'modified' })
        $prFixture.changed_files = 1
        $checkNeeds = & $entryRun $checkArgs
        $prFixture.changed_files = $savedChanged
        $prFiles = $savedPrFiles
        Add-HarnessCase $cases 'entry: -Check, needs the user: exit 2' $true ($checkNeeds.Code -eq 2 -and (ConvertFrom-Json -InputObject $checkNeeds.Said -Depth 100).Code -eq 'needs-user')
        $mergeArgs = @{ Merge = $true; Pr = 7; SummaryFile = $summaryPath; WaiverFile = $recordsFile }
        $merged = & $entryRun $mergeArgs
        Add-HarnessCase $cases 'entry: -Merge: the identity check comes first, then the merge request, exit 0' $false (-not ((& $identityFirst $merged) -and $merged.Sent -eq 1 -and $merged.Code -eq 0 -and $merged.Said -match 'Merged #7'))
        $identity.Login = 'someone-else'
        $mergeWrong = & $entryRun $mergeArgs
        $identity.Login = 'DLsnows'
        Add-HarnessCase $cases 'entry: -Merge with another account: refused, nothing sent' $true ($mergeWrong.Said -match 'resolves to someone-else' -and $mergeWrong.Sent -eq 0 -and $mergeWrong.Gh.Count -eq 2)
        $noSummary = & $entryRun @{ Merge = $true; Pr = 7 }
        Add-HarnessCase $cases 'entry: -Merge hands -SummaryFile on' $true ($noSummary.Said -match '-Merge needs -SummaryFile' -and $noSummary.Sent -eq 0)
        $waiverAnswer = Join-Path $elsewhere 'entry-waivers.json'
        Set-Content -LiteralPath $waiverAnswer -Value (ConvertTo-Json -Depth 10 @{ approvals = @{ '7' = @(@{ head = $headSha; by = 'user'; note = 'entry approval' }) } })
        $prFiles = @([pscustomobject]@{ filename = '.github/workflows/x.yml'; status = 'modified' })
        $prFixture.changed_files = 1
        $checkWaiverFile = & $entryRun @{ Check = $true; Pr = 7; WaiverFile = $waiverAnswer }
        $mergeWaiverFile = & $entryRun @{ Merge = $true; Pr = 7; SummaryFile = $summaryPath; WaiverFile = $waiverAnswer }
        $prFixture.changed_files = $savedChanged
        $prFiles = $savedPrFiles
        Add-HarnessCase $cases 'entry: -Check hands -WaiverFile on' $false ($checkWaiverFile.Code -ne 0)
        Add-HarnessCase $cases 'entry: -Merge hands -WaiverFile on' $false ($mergeWaiverFile.Sent -ne 1)
        foreach ($usage in @(@{ label = 'no mode'; args = @{ Pr = 7 } }, @{ label = 'two modes'; args = @{ Check = $true; Merge = $true; Pr = 7 } })) {
            $refused = & $entryRun $usage.args
            Add-HarnessCase $cases "entry: $($usage.label): refused before anything is asked" $true ($refused.Said -match 'exactly one' -and $log.Count -eq 0)
        }
        $noPr = & $entryRun @{ Check = $true }
        Add-HarnessCase $cases 'entry: no -Pr: refused before anything is asked' $true ($noPr.Said -match '-Pr <n> is required' -and $log.Count -eq 0)

        # ---- -After ------------------------------------------------------------------------------
        $mergedPull = Copy-HarnessObject $pull
        $mergedPull.merged = $true; $mergedPull.state = 'closed'; $mergedPull.merge_commit_sha = 'f' * 40
        $sep = [string][char]0x1f
        $squash = @{ Author = 'DLsnows'; AuthorEmail = '140901583+DLsnows@users.noreply.github.com'; CommitterEmail = 'noreply@github.com'
            Message = "feat(example): add the example module (#7)`n`nAdds it.`n`n$(Get-HarnessSignoff)"; Raw = $null }
        $wtBranch = @{ Name = 'feat/example' }
        $onFeatureLine = @{ Yes = $true }
        $exampleTree = Join-Path $workDir 'example'
        New-Item -ItemType Directory -Force -Path $exampleTree | Out-Null
        Set-Content -LiteralPath (Join-Path $exampleTree '.git') -Value 'gitdir: x'
        $locks = [System.Collections.Generic.List[string]]::new()
        Set-HarnessLockImpl { param($name, $block) $locks.Add($name); & $block }
        $remoteLine = "$headSha`trefs/heads/feat/example"
        $afterState = @{ Remote = $remoteLine; Local = $headSha; Status = ''; Push = '' }
        $afterRoutes = [ordered]@{
            '^gh auth token --user DLsnows$' = { 'tok-selftest' }
            '^gh api user --jq \.login$'     = { $identity.Login }
            'pulls/7$'                       = { $mergedPull }
            'merge-base --is-ancestor'       = { if ($onFeatureLine.Yes) { '' } else { @{ Code = 1; Out = ''; Err = '' } } }
            ' log -1 --format='              = { if ($null -ne $squash.Raw) { $squash.Raw } else { "$($squash.Author)$sep$($squash.AuthorEmail)$sep$($squash.CommitterEmail)$sep$($squash.Message)" } }
            ' symbolic-ref --quiet --short HEAD' = { $wtBranch.Name }
            'ls-remote --exit-code --heads origin refs/heads/feat/example$' = { $afterState.Remote }
            ' status --porcelain --untracked-files=normal --ignored$' = { $afterState.Status }
            ' push origin --delete refs/heads/feat/example' = { $afterState.Push }
            ' worktree list --porcelain'     = { & $worktreeText }
            # fake worktree remove: moves the directory into the self-test's temp directory (never deletes), and only when the path is inside it
            ' worktree remove '              = {
                param($argv)
                $target = [IO.Path]::GetFullPath($argv[-1])
                if (-not $target.StartsWith($tmp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "the fake worktree remove only moves paths inside the self-test directory: $target" }
                Move-Item -LiteralPath $target -Destination (Join-Path $tmp "removed-$([guid]::NewGuid().ToString('N'))"); ''
            }
            'rev-parse --verify --quiet refs/heads/feat/example' = { $afterState.Local }
            ' branch -D feat/example'        = { '' }
            '^git .* fetch '                 = { '' }
        }
        $log.Clear()
        Set-HarnessFake (New-HarnessFake -Routes $afterRoutes -Log $log)
        $afterLine = { try { Invoke-After -Number 7 -WorktreePath $exampleTree } catch { "threw: $($_.Exception.Message)" } }
        $line = & $afterLine
        Add-HarnessCase $cases '-After: merge lock first; read-back passes, remote branch deleted, worktree and local branch removed under the git lock' $false (-not (
                $line -match 'merged as fffffff' -and @($log | Where-Object { $_ -match 'push origin --delete refs/heads/feat/example' }).Count -eq 1 -and
                @($log | Where-Object { $_ -match "worktree remove $([regex]::Escape($exampleTree))$" }).Count -eq 1 -and
                @($log | Where-Object { $_ -match 'branch -D feat/example' }).Count -eq 1 -and
                $locks[0] -eq 'merge' -and @($locks | Where-Object { $_ -eq 'git' }).Count -ge 2))
        Add-HarnessCase $cases '-After: only the given worktree is removed, with no --force' $false (-not (
                @($log | Where-Object { $_ -match ' worktree remove ' }).Count -eq 1 -and @($log | Where-Object { $_ -match 'worktree remove --force' }).Count -eq 0 -and -not (Test-Path -LiteralPath $exampleTree)))
        $reset = {
            New-Item -ItemType Directory -Force -Path $exampleTree | Out-Null
            Set-Content -LiteralPath (Join-Path $exampleTree '.git') -Value 'gitdir: x'
            $log.Clear()
        }
        $removed = { @($log | Where-Object { $_ -match ' worktree remove ' }).Count }
        $nothingDeleted = { @($log | Where-Object { $_ -match 'push origin --delete| worktree remove | branch -D ' }).Count -eq 0 -and (Test-Path -LiteralPath $exampleTree) }
        $afterCase = {
            param([string]$label, [string]$stateKey, $stateAnswer, [string]$word)
            & $reset
            $saved = $afterState[$stateKey]
            $afterState[$stateKey] = $stateAnswer
            $said = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }
            $afterState[$stateKey] = $saved
            Add-HarnessCase $cases $label $true ($said -match $word -and (& $nothingDeleted))
        }
        & $afterCase '-After: git ls-remote fails: an error, nothing is deleted' 'Remote' @{ Code = 128; Out = ''; Err = 'fatal: unable to access the remote' } 'ls-remote origin failed \(exit code 128\).*unable to access'
        & $afterCase '-After: git ls-remote answers without naming the branch: an error, nothing is deleted' 'Remote' "$headSha`trefs/heads/feat/example-two" 'did not name refs/heads/feat/example'
        & $afterCase '-After: the remote branch has commits the merge does not have: nothing is deleted' 'Remote' "$('a' * 40)`trefs/heads/feat/example" 'remote feat/example is at a{40}'
        & $afterCase '-After: the local branch has commits the merge does not have: nothing is deleted' 'Local' ('b' * 40) 'local feat/example is at b{40}'
        & $afterCase '-After: the local branch cannot be read: an error, nothing is deleted' 'Local' @{ Code = 128; Out = ''; Err = 'fatal: bad object' } 'rev-parse failed \(exit code 128\).*bad object'
        & $afterCase '-After: the worktree has an untracked file: nothing is deleted' 'Status' '?? notes.txt' 'has changes or untracked files.*notes\.txt'
        & $afterCase '-After: the worktree has a changed file: nothing is deleted' 'Status' ' M a.txt' 'has changes or untracked files: M a\.txt|has changes or untracked files.* M a\.txt'
        & $afterCase '-After: an ignored file next to an untracked one: nothing is deleted, and only the untracked one is named as the problem' 'Status' "!! skip.log`n?? notes.txt" 'has changes or untracked files.*: \?\? notes\.txt$'
        & $reset
        $afterState.Remote = @{ Code = 2; Out = ''; Err = '' }
        $remoteGone = & $afterLine
        $afterState.Remote = $remoteLine
        Add-HarnessCase $cases '-After: the remote branch is already gone: not pushed, and the last line says so' $false (-not ($remoteGone -match 'remote sub-branch was already gone, worktree removed, local branch removed' -and @($log | Where-Object { $_ -match 'push origin --delete' }).Count -eq 0))
        & $reset
        $afterState.Local = @{ Code = 1; Out = ''; Err = '' }
        $localGone = & $afterLine
        $afterState.Local = $headSha
        Add-HarnessCase $cases '-After: the local branch is already gone: not deleted, and the last line says so' $false (-not ($localGone -match 'remote sub-branch deleted, worktree removed, local branch was already gone' -and @($log | Where-Object { $_ -match 'branch -D' }).Count -eq 0))
        # ignored files go with the worktree: not a reason to stop, but the last line names them
        & $reset
        $afterState.Status = (1..25 | ForEach-Object { "!! skip$_.log" }) -join "`n"
        $withIgnored = & $afterLine
        $afterState.Status = ''
        Add-HarnessCase $cases '-After: ignored files in the worktree: removed, and the last line names them (at most 20)' $false (-not ($withIgnored -match 'ignored files removed with the worktree: skip1\.log, skip2\.log' -and $withIgnored -match 'skip20\.log, \.\.\.$' -and $withIgnored -notmatch 'skip21\.log'))
        # the branch is checked out somewhere else than the path given
        $savedWorktreeText = $worktreeText
        $elsewhereTree = Join-Path $workDir 'elsewhere-tree'
        New-Item -ItemType Directory -Force -Path $elsewhereTree | Out-Null
        $worktreeText = { "worktree $($fakeClone -replace '\\', '/')`nHEAD $tipSha`nbranch refs/heads/feature/v1`n`nworktree $($elsewhereTree -replace '\\', '/')`nHEAD $headSha`nbranch refs/heads/feat/example" }
        & $reset
        $checkedOutElsewhere = & $messageOf { Invoke-After -Number 7 -WorktreePath (Join-Path $workDir 'typo-of-the-path') }
        Add-HarnessCase $cases '-After: the branch is checked out at another path than the one given: nothing is deleted' $true ($checkedOutElsewhere -match 'feat/example is checked out at .*elsewhere-tree, not at' -and (& $nothingDeleted))
        # another branch that starts with the same name, checked out elsewhere, does not matter
        $worktreeText = { "$(& $savedWorktreeText)`n`nworktree $($elsewhereTree -replace '\\', '/')`nHEAD $headSha`nbranch refs/heads/feat/example-two" }
        & $reset
        $otherBranch = & $afterLine
        Add-HarnessCase $cases '-After: another branch that starts with the same name is checked out elsewhere: cleaned up' $false ($otherBranch -notmatch 'remote sub-branch deleted, worktree removed')
        $goneTree = Join-Path $workDir 'gone-tree'
        $worktreeText = { "worktree $($fakeClone -replace '\\', '/')`nHEAD $tipSha`nbranch refs/heads/feature/v1`n`nworktree $($goneTree -replace '\\', '/')`nHEAD $headSha`nbranch refs/heads/feat/example" }
        & $reset
        $registeredGone = & $messageOf { Invoke-After -Number 7 -WorktreePath $goneTree }
        Add-HarnessCase $cases '-After: the worktree is registered but its directory is gone: nothing is deleted, and the message says what clears it' $true ($registeredGone -match 'whose directory is gone \(git worktree prune clears that\)' -and (& $nothingDeleted))
        $worktreeText = $savedWorktreeText
        & $reset
        $afterState.Push = @{ Code = 1; Out = ''; Err = 'remote: refused' }
        $pushRefused = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }
        $afterState.Push = ''
        Add-HarnessCase $cases '-After: the remote branch cannot be deleted: an error, the worktree and the local branch stay' $true ($pushRefused -match 'git push origin refs/heads/feat/example failed.*remote: refused' -and (& $removed) -eq 0 -and -not @($log | Where-Object { $_ -match 'branch -D' }).Count -and (Test-Path -LiteralPath $exampleTree))
        & $reset
        $wtBranch.Name = 'feat/other'
        Add-HarnessCase $cases '-After: the worktree is on another branch (wrong path): nothing is cleaned up' $true (((& $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }) -match "not on feat/example") -and (Test-Path -LiteralPath $exampleTree) -and (& $removed) -eq 0)
        $wtBranch.Name = 'feat/example'
        Add-HarnessCase $cases '-After: no -Worktree' $true ((& $messageOf { Invoke-After -Number 7 -WorktreePath '' }) -match 'needs -Worktree')
        $squash.Message = "feat(example): add (#7)`n`nAdds it.`n`n$(Get-HarnessSignoff)`n$(Get-HarnessSignoff)"
        Add-HarnessCase $cases '-After: the squash message has two sign-off lines' $true ((& $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }) -match 'exactly one Signed-off-by')
        $squash.Message = "feat(example): add`n`nAdds it.`n`n$(Get-HarnessSignoff)"
        Add-HarnessCase $cases '-After: the subject has no (#7)' $true ((& $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }) -match 'does not end with')
        $squash.Message = "feat(example): add (#7)`n`nAdds it.`n`nSigned-off-by: Someone <someone@example.com>"
        Add-HarnessCase $cases '-After: the sign-off is not the maintainer''s' $true ((& $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }) -match 'every Signed-off-by line')
        $squash.Message = "feat(example): add (#7)`n`nAdds it.`n`n$(Get-HarnessSignoff)"
        $squash.Author = 'someone-else'
        Add-HarnessCase $cases '-After: the author is not the maintainer' $true ((& $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }) -match 'author is')
        $squash.Author = 'DLsnows'; $squash.CommitterEmail = 'someone@example.com'
        Add-HarnessCase $cases '-After: the committer is not allowed' $true ((& $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }) -match 'committer email')
        $squash.CommitterEmail = 'noreply@github.com'
        Add-HarnessCase $cases '-After: no push, remove or branch delete ran in any of the refused runs' $false (@($log | Where-Object { $_ -match 'push origin --delete| worktree remove | branch -D ' }).Count -gt 0)
        $mergedPull.merged = $false
        Add-HarnessCase $cases '-After: not merged yet' $true ((& $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }) -match 'not merged yet')
        $mergedPull.merged = $true
        $mergedPull.head.ref = 'dev'
        Add-HarnessCase $cases '-After: the head branch is not a sub-branch name' $true ((& $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }) -match 'Not a sub-branch name')
        $mergedPull.head.ref = 'feat/example'
        $onFeatureLine.Yes = $false
        Add-HarnessCase $cases '-After: the merge commit is not on origin/feature/v1' $true (((& $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }) -match 'is not on origin/feature/v1') -and (& $removed) -eq 0)
        $onFeatureLine.Yes = $true
        $squash.Raw = 'only-one-field'
        Add-HarnessCase $cases '-After: the commit cannot be read back (no field separators)' $true (((& $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }) -match 'Could not read back the commit') -and (& $removed) -eq 0)
        $squash.Raw = $null

        # what git worktree remove cannot do has to be known before the remote branch goes
        foreach ($lockLine in 'locked', 'locked kept on purpose') {
            $worktreeText = { "$(& $savedWorktreeText)`n$lockLine" }
            & $reset
            $lockedRun = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }
            Add-HarnessCase $cases "-After: the worktree is locked ('$lockLine'): nothing is deleted" $true ($lockedRun -match 'it is locked' -and (& $nothingDeleted))
        }
        $worktreeText = { "worktree $($fakeClone -replace '\\', '/')`nHEAD $tipSha`nbranch refs/heads/feature/v1`nlocked`n`nworktree $($workDir -replace '\\', '/')/example`nHEAD $headSha`nbranch refs/heads/feat/example" }
        & $reset
        $otherLocked = & $afterLine
        Add-HarnessCase $cases '-After: another worktree is locked: cleaned up' $false ($otherLocked -notmatch 'remote sub-branch deleted, worktree removed')
        $worktreeText = { "$(& $savedWorktreeText)`nprunable locked away" }
        & $reset
        $notLockLine = & $afterLine
        Add-HarnessCase $cases '-After: a line that only holds the word locked is no lock' $false ($notLockLine -notmatch 'remote sub-branch deleted, worktree removed')
        $worktreeText = $savedWorktreeText
        & $reset
        $treeBelow = Join-Path $exampleTree 'below'
        New-Item -ItemType Directory -Force -Path $treeBelow | Out-Null
        foreach ($inside in @($exampleTree, $treeBelow)) {
            Push-Location -LiteralPath $inside
            try { $insideRun = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree } } finally { Pop-Location }
            Add-HarnessCase $cases "-After: the current location is inside the worktree ($(Split-Path -Leaf $inside)): nothing is deleted" $true ($insideRun -match 'the current directory .* is inside it' -and (& $nothingDeleted))
        }
        $processHere = [Environment]::CurrentDirectory
        [Environment]::CurrentDirectory = $treeBelow
        try { $processRun = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree } } finally { [Environment]::CurrentDirectory = $processHere }
        Add-HarnessCase $cases '-After: the directory of the process is inside the worktree: nothing is deleted' $true ($processRun -match 'the current directory .* is inside it' -and (& $nothingDeleted))
        $treeSibling = "$exampleTree-two"
        New-Item -ItemType Directory -Force -Path $treeSibling | Out-Null
        Push-Location -LiteralPath $treeSibling
        try { $siblingRun = & $afterLine } finally { Pop-Location }
        Add-HarnessCase $cases '-After: the current location is a directory whose name starts the same: cleaned up' $false ($siblingRun -notmatch 'remote sub-branch deleted, worktree removed')
        # a run again after one that stopped halfway: git unregistered the worktree and left directories
        $worktreeText = { "worktree $($fakeClone -replace '\\', '/')`nHEAD $tipSha`nbranch refs/heads/feature/v1" }
        $leftBelow = Join-Path $exampleTree 'empty/below'
        $halfDone = {
            if (Test-Path -LiteralPath $exampleTree) { Remove-Item -LiteralPath $exampleTree -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $leftBelow | Out-Null
            $log.Clear()
        }
        & $halfDone
        $halfLine = & $afterLine
        Add-HarnessCase $cases '-After: unregistered, only empty directories left: the rest is done' $false (-not (
                $halfLine -match 'remote sub-branch deleted, worktree was already unregistered, its empty directory removed, local branch removed' -and (& $removed) -eq 0 -and
                @($log | Where-Object { $_ -match 'push origin --delete' }).Count -eq 1 -and @($log | Where-Object { $_ -match 'branch -D' }).Count -eq 1 -and -not (Test-Path -LiteralPath $exampleTree)))
        & $halfDone
        Set-Content -LiteralPath (Join-Path $leftBelow 'kept.txt') -Value 'x'
        $halfFile = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }
        Add-HarnessCase $cases '-After: unregistered, a file left: nothing is deleted' $true ($halfFile -match 'not a worktree registered' -and (& $nothingDeleted) -and (Test-Path -LiteralPath (Join-Path $leftBelow 'kept.txt')))
        & $halfDone
        $hiddenFile = Join-Path $leftBelow 'hidden.txt'
        Set-Content -LiteralPath $hiddenFile -Value 'x'
        [IO.File]::SetAttributes($hiddenFile, [IO.FileAttributes]::Hidden)
        $halfHidden = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }
        [IO.File]::SetAttributes($hiddenFile, [IO.FileAttributes]::Normal)
        Add-HarnessCase $cases '-After: unregistered, a hidden file left: nothing is deleted' $true ($halfHidden -match 'not a worktree registered' -and (& $nothingDeleted) -and (Test-Path -LiteralPath $hiddenFile))
        & $halfDone
        Push-Location -LiteralPath $leftBelow
        try { $halfInside = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree } } finally { Pop-Location }
        Add-HarnessCase $cases '-After: unregistered, the current location inside what is left: nothing is deleted' $true ($halfInside -match 'the current directory .* is inside it' -and (& $nothingDeleted))
        if ($IsWindows) {
            & $halfDone
            $leftTarget = Join-Path $workDir 'left-target'
            New-Item -ItemType Directory -Force -Path $leftTarget | Out-Null
            Set-Content -LiteralPath (Join-Path $leftTarget 'keep.txt') -Value 'x'
            $leftLink = Join-Path $leftBelow 'link'
            New-Item -ItemType Junction -Path $leftLink -Target $leftTarget | Out-Null
            $halfLink = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }
            if (Test-Path -LiteralPath $leftLink) { [IO.Directory]::Delete($leftLink) }
            Add-HarnessCase $cases '-After: unregistered, a link left: nothing is deleted' $true ($halfLink -match 'not a worktree registered' -and (& $nothingDeleted) -and (Test-Path -LiteralPath (Join-Path $leftTarget 'keep.txt')))
            # a directory that cannot be removed stands for one another process still holds: the remote branch stays
            & $halfDone
            [IO.File]::SetAttributes($leftBelow, [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReadOnly)
            $halfHeld = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }
            [IO.File]::SetAttributes($leftBelow, [IO.FileAttributes]::Directory)
            Add-HarnessCase $cases '-After: unregistered, a directory that cannot be removed: an error, the branches stay' $true ($halfHeld -match 'could not be removed .*nothing else is cleaned up' -and (& $nothingDeleted))
        }
        if ($IsWindows) {
            $emptyTarget = Join-Path $workDir 'empty-target'
            New-Item -ItemType Directory -Force -Path $emptyTarget | Out-Null
            $emptyLink = Join-Path $workDir 'to-empty'
            New-Item -ItemType Junction -Path $emptyLink -Target $emptyTarget | Out-Null
            $log.Clear()
            $linkAsTree = & $messageOf { Invoke-After -Number 7 -WorktreePath $emptyLink }
            $linkStays = Test-Path -LiteralPath $emptyLink
            if ($linkStays) { [IO.Directory]::Delete($emptyLink) }
            Add-HarnessCase $cases '-After: a junction to an empty directory given as -Worktree: refused as a link, nothing is deleted' $true ($linkAsTree -match 'is a link' -and $linkStays -and -not @($log | Where-Object { $_ -match 'push origin --delete| branch -D ' }).Count)
        }
        # registered and empty is something else: git still knows it, so it is looked at as a worktree
        $worktreeText = $savedWorktreeText
        & $halfDone
        $registeredEmpty = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }
        Add-HarnessCase $cases '-After: a registered worktree with nothing in it is no leftover: nothing is deleted' $true ($registeredEmpty -match 'does not look like a worktree' -and (& $nothingDeleted))
        $worktreeText = { "worktree $($fakeClone -replace '\\', '/')`nHEAD $tipSha`nbranch refs/heads/feature/v1`n`nworktree $($elsewhereTree -replace '\\', '/')`nHEAD $headSha`nbranch refs/heads/feat/example" }
        & $halfDone
        $wrongEmpty = & $messageOf { Invoke-After -Number 7 -WorktreePath $exampleTree }
        Add-HarnessCase $cases '-After: an empty directory at a wrong path, the branch checked out elsewhere: nothing is deleted' $true ($wrongEmpty -match 'feat/example is checked out at .*elsewhere-tree, not at' -and (& $nothingDeleted))
        $worktreeText = { "worktree $($fakeClone -replace '\\', '/')`nHEAD $tipSha`nbranch refs/heads/feature/v1" }
        Remove-Item -LiteralPath $exampleTree -Recurse -Force
        $log.Clear()
        $nothingThere = & $afterLine
        Add-HarnessCase $cases '-After: no directory and no registration: the last line says the worktree was already gone' $false (-not ($nothingThere -match 'remote sub-branch deleted, worktree was already gone, local branch removed' -and (& $removed) -eq 0))
        $worktreeText = $savedWorktreeText

        # the checks before git worktree remove
        Set-HarnessFake (New-HarnessFake -Routes $afterRoutes -Log $log)
        $registered = @(Get-RegisteredWorktrees)
        $guard = { param($p) & $messageOf { Assert-WorktreeDir -Path $p -MainRoot $fakeClone -KnownTrees $registered } }
        & $reset
        Add-HarnessCase $cases 'worktree check: a registered worktree whose .git is a file passes' $false ($null -ne (& $guard $exampleTree))
        Add-HarnessCase $cases 'worktree check: a relative path' $true ((& $guard 'example') -match 'not an absolute')
        Add-HarnessCase $cases 'worktree check: a UNC path' $true ((& $guard '\\server\share\example') -match 'not an absolute')
        Add-HarnessCase $cases 'worktree check: a directory that does not exist' $true ((& $guard (Join-Path $workDir 'nope')) -match 'not an existing directory')
        Add-HarnessCase $cases 'worktree check: the main checkout' $true ((& $messageOf { Assert-WorktreeDir -Path $fakeClone -MainRoot $fakeClone -KnownTrees $registered }) -match 'main checkout')
        $unregistered = Join-Path $workDir 'stranger'
        New-Item -ItemType Directory -Force -Path $unregistered | Out-Null
        Set-Content -LiteralPath (Join-Path $unregistered '.git') -Value 'gitdir: x'
        Add-HarnessCase $cases 'worktree check: not registered in this repository' $true ((& $guard $unregistered) -match 'not a worktree registered')
        Add-HarnessCase $cases 'worktree check: a drive root' $true ((& $messageOf { Assert-WorktreeDir -Path ([IO.Path]::GetPathRoot($tmp)) -MainRoot $fakeClone -KnownTrees $registered }) -match 'drive root')
        # listed as a worktree on purpose: only the home-directory rule can refuse it
        Add-HarnessCase $cases 'worktree check: the home directory' $true ((& $messageOf { Assert-WorktreeDir -Path ([Environment]::GetFolderPath('UserProfile')) -MainRoot $fakeClone -KnownTrees @([Environment]::GetFolderPath('UserProfile')) }) -match 'it is the home directory')
        Add-HarnessCase $cases 'worktree check: the directory exists but .git is not a file' $true ((& $messageOf { Assert-WorktreeDir -Path $fakeClone -MainRoot $outside -KnownTrees @($fakeClone) }) -match 'does not look like a worktree')
        if ($IsWindows) {
            $away = Join-Path ([IO.Path]::GetTempPath()) "harness-merge-selftest-away-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Force -Path $away | Out-Null
            Set-Content -LiteralPath (Join-Path $away '.git') -Value 'gitdir: x'
            Set-Content -LiteralPath (Join-Path $away 'keep.txt') -Value 'x'
            $toAway = Join-Path $workDir 'to-away'
            New-Item -ItemType Junction -Path $toAway -Target $away | Out-Null
            Add-HarnessCase $cases 'worktree check: a junction that points outside is refused as a link' $true ((& $messageOf { Assert-WorktreeDir -Path $toAway -MainRoot $fakeClone -KnownTrees @($toAway, $away) }) -match 'is a link')
            $viaLink = & $messageOf { Invoke-After -Number 7 -WorktreePath $toAway }
            Add-HarnessCase $cases '-After: a junction given as -Worktree leaves the target untouched' $true ($viaLink -and (Test-Path -LiteralPath (Join-Path $away 'keep.txt')) -and (Test-Path -LiteralPath $toAway))
            [IO.Directory]::Delete($toAway)
        }
        # the command line of -After
        & $reset
        $afterEntry = @{ After = $true; Pr = 7; Worktree = $exampleTree }
        $identity.Login = 'someone-else'
        $afterWrong = & $entryRun $afterEntry
        $identity.Login = 'DLsnows'
        Add-HarnessCase $cases 'entry: -After with another account: refused, nothing is deleted' $true ($afterWrong.Said -match 'resolves to someone-else' -and $afterWrong.Gh.Count -eq 2 -and (& $nothingDeleted))
        $afterDone = & $entryRun $afterEntry
        Add-HarnessCase $cases 'entry: -After: the identity check comes first, the given worktree is what gets removed' $false (-not ((& $identityFirst $afterDone) -and $afterDone.Code -eq 0 -and @($log | Where-Object { $_ -match "worktree remove $([regex]::Escape($exampleTree))$" }).Count -eq 1))

        # -After for real: a bare origin, a main clone and a real worktree in the temp directory; only gh is faked
        $e2eRoot = Join-Path $tmp 'e2e'
        $e2eOrigin = Join-Path $e2eRoot 'origin.git'
        $e2eMain = Join-Path $e2eRoot 'main'
        $e2eTree = Join-Path $e2eRoot 'tree'
        New-Item -ItemType Directory -Force -Path $e2eRoot | Out-Null
        $gitConfigFile = Join-Path $e2eRoot 'gitconfig'
        Set-Content -LiteralPath $gitConfigFile -Value "[user]`n`tname = DLsnows`n`temail = noreply@synchain.ca`n" -Encoding utf8NoBOM
        $gitEnvironment = @{ GIT_CONFIG_GLOBAL = $gitConfigFile; GIT_CONFIG_NOSYSTEM = '1'; GIT_DIR = $null; GIT_WORK_TREE = $null; GIT_INDEX_FILE = $null }
        $gitEnvironmentSaved = @{}
        # [NullString]::Value: a plain $null reaches .NET as an empty string, and an empty variable is still a variable to git
        $setVariable = { param($variableName, $variableText) [Environment]::SetEnvironmentVariable($variableName, $(if ($null -eq $variableText) { [NullString]::Value } else { $variableText })) }
        foreach ($variableName in $gitEnvironment.get_Keys()) {
            $gitEnvironmentSaved[$variableName] = [Environment]::GetEnvironmentVariable($variableName)
            & $setVariable $variableName $gitEnvironment[$variableName]
        }
        try {
            $repoRootNow = Get-HarnessRepoRoot
            $e2e = @{ Pull = $null; Line = '' }
            # gh is answered here; git runs for real, and a command addressed to this repository goes to the temporary main clone instead
            Set-HarnessFake {
                param($cmd, $argv, $opts)
                if ($cmd -ceq 'gh') {
                    if (($argv -join ' ') -match 'pulls/7$') { return @{ Code = 0; Out = (ConvertTo-Json -InputObject $e2e.Pull -Depth 100 -Compress); Err = '' } }
                    return @{ Code = 1; Out = ''; Err = "no fixture for: gh $($argv -join ' ')" }
                }
                if ($cmd -ceq 'git' -and $argv[0] -ceq '-C' -and $argv[1] -ceq $repoRootNow -and $argv[2] -cne 'config') { $argv[1] = $e2eMain }
                $null
            }
            $realGit = { param([string[]]$gitArgs) (Invoke-HarnessExternal git $gitArgs).Out.Trim() }
            $hasRef = { param($gitDir, $refName) (Invoke-HarnessExternal git @('--git-dir', $gitDir, 'rev-parse', '--verify', '--quiet', $refName) -AllowFail).Code -eq 0 }
            $mainGitDir = Join-Path $e2eMain '.git'
            $branchRefName = 'refs/heads/feat/example'
            $intact = { (Test-Path -LiteralPath (Join-Path $e2eTree '.git')) -and (& $hasRef $e2eOrigin $branchRefName) -and (& $hasRef $mainGitDir $branchRefName) }
            & $realGit @('init', '--quiet', '--bare', '--initial-branch=feature/v1', $e2eOrigin) | Out-Null
            & $realGit @('init', '--quiet', '--initial-branch=feature/v1', $e2eMain) | Out-Null
            & $realGit @('-C', $e2eMain, 'remote', 'add', 'origin', $e2eOrigin) | Out-Null
            Set-Content -LiteralPath (Join-Path $e2eMain 'a.txt') -Value 'base'
            & $realGit @('-C', $e2eMain, 'add', 'a.txt') | Out-Null
            & $realGit @('-C', $e2eMain, 'commit', '--quiet', '-m', 'chore(example): base') | Out-Null
            & $realGit @('-C', $e2eMain, 'push', '--quiet', 'origin', 'feature/v1') | Out-Null
            & $realGit @('-C', $e2eMain, 'worktree', 'add', '--quiet', '-b', 'feat/example', $e2eTree) | Out-Null
            Set-Content -LiteralPath (Join-Path $e2eTree 'b.txt') -Value 'work'
            & $realGit @('-C', $e2eTree, 'add', 'b.txt') | Out-Null
            & $realGit @('-C', $e2eTree, 'commit', '--quiet', '-m', 'feat(example): work') | Out-Null
            & $realGit @('-C', $e2eTree, 'push', '--quiet', 'origin', 'feat/example') | Out-Null
            $treeTip = & $realGit @('-C', $e2eTree, 'rev-parse', 'HEAD')
            # the squash on the feature line, the way a merge writes it
            & $realGit @('-C', $e2eMain, 'merge', '--quiet', '--squash', 'feat/example') | Out-Null
            & $realGit @('-C', $e2eMain, 'commit', '--quiet', '-m', 'feat(example): add the example module (#7)', '-m', 'Adds it.', '-m', (Get-HarnessSignoff)) | Out-Null
            & $realGit @('-C', $e2eMain, 'push', '--quiet', 'origin', 'feature/v1') | Out-Null
            $squashOnLine = & $realGit @('-C', $e2eMain, 'rev-parse', 'HEAD')
            $e2e.Pull = Copy-HarnessObject $pull
            $e2e.Pull.merged = $true; $e2e.Pull.state = 'closed'; $e2e.Pull.merge_commit_sha = $squashOnLine; $e2e.Pull.head.sha = $treeTip; $e2e.Pull.head.ref = 'feat/example'
            $e2eRun = { & $messageOf { $e2e.Line = Invoke-After -Number 7 -WorktreePath $e2eTree } }

            # a commit in the worktree that was never pushed
            Set-Content -LiteralPath (Join-Path $e2eTree 'c.txt') -Value 'local only'
            & $realGit @('-C', $e2eTree, 'add', 'c.txt') | Out-Null
            & $realGit @('-C', $e2eTree, 'commit', '--quiet', '-m', 'feat(example): local only') | Out-Null
            $localAhead = & $e2eRun
            Add-HarnessCase $cases '-After with real git: an unmerged local commit: refused, nothing is deleted' $true ($localAhead -match 'local feat/example is at' -and (& $intact) -and (Test-Path -LiteralPath (Join-Path $e2eTree 'c.txt')))
            & $realGit @('-C', $e2eTree, 'reset', '--quiet', '--hard', $treeTip) | Out-Null

            # a commit on the remote branch that the merge does not have
            $remoteExtra = & $realGit @('-C', $e2eTree, 'commit-tree', "$treeTip^{tree}", '-p', $treeTip, '-m', 'feat(example): remote only')
            & $realGit @('-C', $e2eTree, 'push', '--quiet', 'origin', "${remoteExtra}:$branchRefName") | Out-Null
            $remoteAhead = & $e2eRun
            Add-HarnessCase $cases '-After with real git: an unmerged remote commit: refused, nothing is deleted' $true ($remoteAhead -match 'remote feat/example is at' -and (& $intact) -and (& $realGit @('--git-dir', $e2eOrigin, 'rev-parse', $branchRefName)) -ceq $remoteExtra)
            & $realGit @('--git-dir', $e2eOrigin, 'update-ref', $branchRefName, $treeTip) | Out-Null

            # an untracked file in the worktree
            Set-Content -LiteralPath (Join-Path $e2eTree 'notes.txt') -Value 'not committed'
            $untracked = & $e2eRun
            Add-HarnessCase $cases '-After with real git: an untracked file: refused, nothing is deleted' $true ($untracked -match 'has changes or untracked files' -and (& $intact) -and (Test-Path -LiteralPath (Join-Path $e2eTree 'notes.txt')))
            Remove-Item -LiteralPath (Join-Path $e2eTree 'notes.txt')

            # the real worktree is elsewhere than the path given: its changes were never looked at, and git branch -D would fail after the remote is gone
            $typoRun = & $messageOf { $e2e.Line = Invoke-After -Number 7 -WorktreePath (Join-Path $e2eRoot 'typo') }
            Add-HarnessCase $cases '-After with real git: a wrong path while the real worktree is elsewhere: refused, nothing is deleted' $true ($typoRun -match 'feat/example is checked out at .*tree, not at .*typo' -and (& $intact))

            # the clean case deletes all three; an ignored file goes with the worktree, and the last line names it
            Add-Content -LiteralPath (Join-Path $mainGitDir 'info/exclude') -Value '*.ignored'
            Set-Content -LiteralPath (Join-Path $e2eTree 'local-notes.ignored') -Value 'ignored by git'
            $cleanRun = & $e2eRun
            Add-HarnessCase $cases '-After with real git: tips equal and the worktree clean: remote branch, worktree and local branch are gone' $false (
                [bool]$cleanRun -or $e2e.Line -notmatch 'remote sub-branch deleted, worktree removed, local branch removed' -or (Test-Path -LiteralPath $e2eTree) -or (& $hasRef $e2eOrigin $branchRefName) -or (& $hasRef $mainGitDir $branchRefName))
            Add-HarnessCase $cases '-After with real git: an ignored file is named in the last line' $false ($e2e.Line -notmatch 'ignored files removed with the worktree: local-notes\.ignored$')

            # the same again with the remote branch already gone: GitHub deletes merged branches when the repository says so
            & $realGit @('-C', $e2eMain, 'worktree', 'add', '--quiet', '-b', 'feat/example', $e2eTree, $treeTip) | Out-Null
            $goneRun = & $e2eRun
            Add-HarnessCase $cases '-After with real git: the remote branch was already gone: the last line says so, the rest is removed' $false (
                [bool]$goneRun -or $e2e.Line -notmatch 'remote sub-branch was already gone, worktree removed, local branch removed' -or (Test-Path -LiteralPath $e2eTree) -or (& $hasRef $mainGitDir $branchRefName))

            # the worktree directory was deleted by hand and is still registered: git branch -D would fail after the remote is gone
            & $realGit @('-C', $e2eMain, 'worktree', 'add', '--quiet', '-b', 'feat/example', $e2eTree, $treeTip) | Out-Null
            & $realGit @('-C', $e2eTree, 'push', '--quiet', 'origin', 'feat/example') | Out-Null
            Remove-Item -LiteralPath $e2eTree -Recurse -Force
            $handDeleted = & $e2eRun
            Add-HarnessCase $cases '-After with real git: the directory deleted by hand, the worktree still registered: refused, the branches stay' $true ($handDeleted -match 'whose directory is gone' -and (& $hasRef $e2eOrigin $branchRefName) -and (& $hasRef $mainGitDir $branchRefName))

            # what would make git worktree remove fail is found while the remote branch is still there
            & $realGit @('-C', $e2eMain, 'worktree', 'prune') | Out-Null
            & $realGit @('-C', $e2eMain, 'worktree', 'add', '--quiet', $e2eTree, 'feat/example') | Out-Null
            foreach ($lockWay in @(@{ Name = 'with a reason'; Flags = @('--reason', 'kept on purpose') }, @{ Name = 'without a reason'; Flags = @() })) {
                & $realGit (@('-C', $e2eMain, 'worktree', 'lock') + $lockWay.Flags + @($e2eTree)) | Out-Null
                $lockedReal = & $e2eRun
                & $realGit @('-C', $e2eMain, 'worktree', 'unlock', $e2eTree) | Out-Null
                Add-HarnessCase $cases "-After with real git: a worktree locked $($lockWay.Name): refused, nothing is deleted" $true ($lockedReal -match 'it is locked' -and (& $intact))
            }
            Push-Location -LiteralPath $e2eTree
            try { $locationReal = & $e2eRun } finally { Pop-Location }
            Add-HarnessCase $cases '-After with real git: the current location inside the worktree: refused, nothing is deleted' $true ($locationReal -match 'the current directory .* is inside it' -and (& $intact))
            $processHere = [Environment]::CurrentDirectory
            [Environment]::CurrentDirectory = $e2eTree
            try { $processReal = & $e2eRun } finally { [Environment]::CurrentDirectory = $processHere }
            Add-HarnessCase $cases '-After with real git: the directory of the process inside the worktree: refused, nothing is deleted' $true ($processReal -match 'the current directory .* is inside it' -and (& $intact))

            # git took the registration away and something kept the directory: first with a file in it, then only empty directories
            & $realGit @('-C', $e2eMain, 'worktree', 'remove', $e2eTree) | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $e2eTree 'empty/below') | Out-Null
            $leftFile = Join-Path $e2eTree 'empty/kept.txt'
            Set-Content -LiteralPath $leftFile -Value 'not empty'
            $halfWithFile = & $e2eRun
            Add-HarnessCase $cases '-After with real git: unregistered with a file left: refused, the file and the branches stay' $true ($halfWithFile -match 'not a worktree registered' -and (Test-Path -LiteralPath $leftFile) -and (& $hasRef $e2eOrigin $branchRefName) -and (& $hasRef $mainGitDir $branchRefName))
            Remove-Item -LiteralPath $leftFile
            $halfEmpty = & $e2eRun
            Add-HarnessCase $cases '-After with real git: unregistered with only empty directories left: the run finishes, all three are gone' $false (
                [bool]$halfEmpty -or $e2e.Line -notmatch 'remote sub-branch deleted, worktree was already unregistered, its empty directory removed, local branch removed' -or (Test-Path -LiteralPath $e2eTree) -or (& $hasRef $e2eOrigin $branchRefName) -or (& $hasRef $mainGitDir $branchRefName))
            $allGone = & $e2eRun
            Add-HarnessCase $cases '-After with real git: once more with everything gone: the last line says so' $false ([bool]$allGone -or $e2e.Line -notmatch 'remote sub-branch was already gone, worktree was already gone, local branch was already gone')
        } finally {
            Set-HarnessFake (New-HarnessFake -Routes $afterRoutes -Log $log)
            foreach ($variableName in $gitEnvironmentSaved.get_Keys()) { & $setVariable $variableName $gitEnvironmentSaved[$variableName] }
        }

        $fakeRemove = $afterRoutes[' worktree remove ']
        Add-HarnessCase $cases 'the fake worktree remove refuses a path outside the self-test directory' $true (Test-Throws { & $fakeRemove @('git', 'worktree', 'remove', (Join-Path ([IO.Path]::GetTempPath()) 'outside-the-selftest')) })

        # ---- source hygiene ----------------------------------------------------------------------
        $selfText = Get-Content -Raw -LiteralPath $PSCommandPath
        Add-HarnessCase $cases 'source hygiene: pr-merge.ps1' $false (@(Get-HarnessSourceProblems -Text $selfText -Name 'pr-merge.ps1').Count -gt 0)
    } catch {
        # a crash does not hide what already turned red by name
        Write-HarnessFailedCases $cases
        throw
    } finally {
        Set-HarnessFake $null
        Set-HarnessLockImpl $null
        Set-HarnessInfraModule $null
        Set-HarnessNeedles
        Clear-HarnessPermCache
        if (Test-Path -LiteralPath variable:savedToken) { $env:GH_TOKEN = $savedToken }
        # the temp directories are this process's own: name prefix and parent checked before the recursive delete
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        foreach ($dir in @($tmp, $away) | Where-Object { $_ }) {
            $full = [IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
            if ((Split-Path -Parent $full) -ieq $tempRoot -and (Split-Path -Leaf $full) -like 'harness-merge-selftest-*') {
                foreach ($entry in Get-ChildItem -LiteralPath $full -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
                    [IO.Directory]::Delete($entry.FullName)
                }
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Add-HarnessCase $cases 'the self-test temp directories were removed' $false ((Test-Path -LiteralPath $tmp) -or ($away -and (Test-Path -LiteralPath $away)))
    }
    Complete-HarnessSelfTest $cases 'pr-merge'
}

# only the last value is the exit code: a stray object from the self-test would turn exit into an array and report 0
if ($SelfTest) { exit [int]@(Invoke-SelfTest)[-1] }
Invoke-Entry @PSBoundParameters
exit $script:EntryCode

#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
#
# Deletion-style verification of the self-tests: every entry of lib/mutations.txt removes or weakens exactly one criterion in
# a throw-away copy of scripts/maintainer and expects the self-tests of the affected script to turn red. An entry that stays
# green ("survived") means the criterion has no case that depends on it. The working tree is never touched.
# Entry format (blocks separated by "@@"; lines starting with # are comments):
#   @@ <file relative to scripts/maintainer> | <label>
#   % run=<script,script,maint>        optional; default: the script itself (a .ps1 file) or maint (maint.mjs)
#   < <text to find, exactly once in the file; several < lines are joined with newlines>
#   > <replacement; several > lines are joined; a bare > is an empty line; no > line = delete>
#   pwsh scripts/maintainer/lib/mutation-check.ps1 [-Only <text in the label or file>] [-Id 5,9] [-FromId 120]   (ids as listed by -List) [-Parallel 3] [-TimeoutSeconds 900] [-ResultFile <path>] [-List] [-Check]
# A run= name is a script (push, pr-open, pr-comment, pr-merge, new-worktree), maint (maint.mjs --self-test), shared (the
# shared-module and source-hygiene rules of self-test.ps1), pre-push (scripts/hooks/pre-push.mjs --self-test), check-secrets
# (scripts/check-secrets.mjs --self-test), check-commits (scripts/check-commits.mjs --self-test) or privacy
# (scripts/check-privacy.mjs --self-test). A file outside this directory is named relative to it (../hooks/pre-push.mjs,
# ../../.github/workflows/ci.yml) and needs a run=.
# A mutation is killed only when a named case of one of its self-tests turns red ("self-test failed: <case>"). A self-test that
# exits red without naming a case is a CRASH: the script fell over, which says nothing about the criterion, so it is not a kill.
# A self-test that runs longer than -TimeoutSeconds is a CRASH as well: the process it runs in and everything it started are
# ended, and the run goes on with the next entry.
# A mutated file that no longer parses is an ERROR, not a kill: the self-tests would turn red for the wrong reason.
# -Check only verifies that every text to find occurs exactly once and that every mutated file still parses (seconds, no self-test).
# Every result goes to -ResultFile the moment it is known, one JSON line per entry (default: a new file in the temp directory, its
# name is the first line of the output), so a run that is stopped keeps what it found.
# The result is a markdown table on stdout; exit code 0 only when the unmutated copy passes and every mutation was killed.

[CmdletBinding()]
param([string]$Only, [string]$Id, [int]$FromId = 0, [int]$Parallel = 3, [int]$TimeoutSeconds = 900, [string]$ResultFile, [switch]$List, [switch]$Check, [string]$Table = (Join-Path $PSScriptRoot 'mutations.txt'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# the self-tests write UTF-8; the table must not come out in the code page of the console (without a console there is none to set)
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { $null = 0 }

$maintainerDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$nodeCommand = if ($env:HARNESS_NODE) { $env:HARNESS_NODE } else { 'node' }
# the copies are no repositories, git config cannot answer there; without gitleaks the hook's self-test leaves out its end-to-end part
if (-not $env:HARNESS_GITLEAKS) {
    $pinnedGitleaks = & git -C $maintainerDir config --get harness.gitleaks
    if ($LASTEXITCODE -eq 0 -and $pinnedGitleaks) { $env:HARNESS_GITLEAKS = $pinnedGitleaks }
}

function Read-Mutations {
    param([Parameter(Mandatory)][string]$Path)
    $all = [System.Collections.Generic.List[object]]::new()
    $current = $null
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        $lineNumber++
        if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
        if ($line -match '^@@ (.+?) \| (.+)$') {
            $current = [pscustomobject]@{ Id = $all.Count + 1; File = $Matches[1].Trim(); Label = $Matches[2].Trim(); Run = @(); Find = [System.Collections.Generic.List[string]]::new(); Replace = [System.Collections.Generic.List[string]]::new(); Line = $lineNumber }
            $all.Add($current)
        } elseif (-not $current) { throw "${Path}:${lineNumber}: text before the first @@ header" }
        elseif ($line -match '^% run=(.+)$') { $current.Run = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        elseif ($line -match '^< ?(.*)$') { $current.Find.Add($Matches[1]) }
        elseif ($line -match '^> ?(.*)$') { $current.Replace.Add($Matches[1]) }
        else { throw "${Path}:${lineNumber}: unknown line: $line" }
    }
    foreach ($m in $all) {
        if (-not $m.Find.Count) { throw "${Path}:$($m.Line): entry '$($m.Label)' has no < line" }
        if (-not $m.Run.Count) { $m.Run = @($(if ($m.File -like '*.mjs') { 'maint' } elseif ($m.File -like '*.ps1') { [IO.Path]::GetFileNameWithoutExtension($m.File) } else { throw "${Path}:$($m.Line): entry '$($m.Label)' needs % run=" })) }
    }
    $all.ToArray()
}

$worker = {
    param($Mutation, $SourceDir, $NodePath, $ScratchDir, $CheckOnly, $LimitSeconds)
    $result = [ordered]@{ Id = $Mutation.Id; File = $Mutation.File; Label = $Mutation.Label; Status = ''; Detail = '' }
    # one self-test in a process of its own, with a time limit. Output is taken from the pipes as it comes, a full pipe cannot block it
    $runChild = {
        param([string]$Exe, [string[]]$Arguments)
        $info = [System.Diagnostics.ProcessStartInfo]::new($Exe)
        foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.RedirectStandardInput = $true
        $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $info.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
        $info.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
        $process = [System.Diagnostics.Process]::Start($info)
        try {
            $process.StandardInput.Close()
            $outTask = $process.StandardOutput.ReadToEndAsync()
            $errTask = $process.StandardError.ReadToEndAsync()
            $finished = $process.WaitForExit($LimitSeconds * 1000)
            if (-not $finished) {
                # only this process and what it started
                $process.Kill($true)
                [void]$process.WaitForExit(30000)
            }
            # something it left behind can keep the pipes open: what arrived until then has to do
            [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($outTask, $errTask), 10000)
            $said = @(foreach ($task in $outTask, $errTask) { if ($task.IsCompletedSuccessfully) { $task.Result -split "`r?`n" } })
            [pscustomobject]@{ TimedOut = -not $finished; Code = $(if ($finished) { $process.ExitCode } else { -1 }); Lines = @($said | ForEach-Object { $_ -replace "\x1b\[[0-9;]*m", '' } | Where-Object { $_ }) }
        } finally { $process.Dispose() }
    }
    try {
        $dir = Join-Path $ScratchDir ("m{0:D3}" -f $Mutation.Id)
        $copy = Join-Path $dir 'scripts/maintainer'
        New-Item -ItemType Directory -Force -Path $copy | Out-Null
        Copy-Item -Path (Join-Path $SourceDir '*') -Destination $copy -Recurse -Force
        # the files of the repository that the wrappers and the real tools read: the check scripts and their libraries (scripts/ without
        # this directory), the tool pins, the PR template and the workflow whose scans the self-tests read
        $repoRoot = Split-Path -Parent (Split-Path -Parent $SourceDir)
        foreach ($entry in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Force | Where-Object { $_.Name -ne 'maintainer' })) {
            Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $dir 'scripts') -Recurse -Force
        }
        foreach ($relative in @('.node-version', '.gitleaks-version', '.github/pull_request_template.md', '.github/workflows/ci.yml')) {
            $to = Join-Path $dir $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $to -Force
        }
        if ($Mutation.Find.Count) {
            $target = Join-Path $copy $Mutation.File
            $text = ([IO.File]::ReadAllText($target)) -replace "`r`n", "`n"
            $find = $Mutation.Find -join "`n"
            $count = ([regex]::Matches($text, [regex]::Escape($find))).Count
            if ($count -ne 1) {
                $result.Status = 'ERROR'; $result.Detail = "the text to find occurs $count times (needs exactly 1)"
                return [pscustomobject]$result
            }
            $replacement = $Mutation.Replace -join "`n"
            [IO.File]::WriteAllText($target, $text.Replace($find, $replacement), [Text.UTF8Encoding]::new($false))
            $problem = $null
            if ($Mutation.File -like '*.mjs') {
                $null = & $NodePath --check $target 2>&1
                if ($LASTEXITCODE -ne 0) { $problem = 'the mutated file does not parse (node --check)' }
            } elseif ($Mutation.File -match '\.psm?1$') {
                $tokens = $null; $parseErrors = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$parseErrors)
                if (@($parseErrors).Count) { $problem = "the mutated file does not parse: $(@($parseErrors)[0].Message)" }
            }
            if ($problem) {
                $result.Status = 'ERROR'; $result.Detail = $problem
                return [pscustomobject]$result
            }
        }
        if ($CheckOnly) {
            $result.Status = 'checked'
            return [pscustomobject]$result
        }
        $failed = [System.Collections.Generic.List[string]]::new()
        $codes = [System.Collections.Generic.List[string]]::new()
        $namedCase = $false
        $timedOut = $false
        $powershell = [Environment]::ProcessPath
        foreach ($name in $Mutation.Run) {
            $run = switch ($name) {
                'maint' { & $runChild $NodePath @((Join-Path $copy 'lib/maint.mjs'), '--self-test') }
                'pre-push' { & $runChild $NodePath @((Join-Path $dir 'scripts/hooks/pre-push.mjs'), '--self-test') }
                'check-secrets' { & $runChild $NodePath @((Join-Path $dir 'scripts/check-secrets.mjs'), '--self-test') }
                'check-commits' { & $runChild $NodePath @((Join-Path $dir 'scripts/check-commits.mjs'), '--self-test') }
                'privacy' { & $runChild $NodePath @((Join-Path $dir 'scripts/check-privacy.mjs'), '--self-test') }
                'shared' { & $runChild $powershell @('-NoProfile', '-File', (Join-Path $copy 'self-test.ps1'), '-Only', 'none') }
                default { & $runChild $powershell @('-NoProfile', '-File', (Join-Path $copy "$name.ps1"), '-SelfTest') }
            }
            $codes.Add("$name=$($run.Code)")
            if ($run.TimedOut) {
                $timedOut = $true
                $failed.Clear()
                $failed.Add("$name ran longer than $LimitSeconds seconds, its process tree was ended")
                break
            }
            if ($run.Code -ne 0) {
                $named = @($run.Lines | Where-Object { $_ -match '^self-test (case )?failed: ' } | Select-Object -First 2)
                if ($named.Count) {
                    $failed.Clear()
                    foreach ($line in $named) { $failed.Add($line.Trim()) }
                    $namedCase = $true
                    break   # one named case is enough: the mutation is killed
                }
                # no case named: remember what it said and let the other self-tests of the entry have their say
                foreach ($line in @($run.Lines | Where-Object { $_ -match 'FAIL|rror' } | Select-Object -First 2)) { $failed.Add($line.Trim()) }
                if (-not $failed.Count) { $failed.Add((@($run.Lines | Select-Object -Last 1) -join '')) }
            }
        }
        $result.Status = if ($timedOut) { 'CRASH' } elseif ($namedCase) { 'killed' } elseif (@($codes | Where-Object { $_ -notmatch '=0$' }).Count) { 'CRASH' } else { 'SURVIVED' }
        $result.Detail = ($failed | Select-Object -First 2) -join ' / '
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        # the runner itself: one entry that could not be run must not end the run
        $result.Status = 'ERROR'; $result.Detail = "the entry could not be run: $($_.Exception.Message)"
    }
    [pscustomobject]$result
}

$mutations = @(Read-Mutations -Path $Table)
if ($Only) { $mutations = @($mutations | Where-Object { $_.Label -like "*$Only*" -or $_.File -like "*$Only*" }) }
if ($Id) { $wanted = @($Id -split ',' | ForEach-Object { [int]$_.Trim() }); $mutations = @($mutations | Where-Object { $wanted -contains $_.Id }) }
if ($FromId) { $mutations = @($mutations | Where-Object { $_.Id -ge $FromId }) }
if ($List) { $mutations | ForEach-Object { '{0,3} {1} | {2}' -f $_.Id, $_.File, $_.Label }; exit 0 }

$resultPath = if ($Check) { $null } elseif ($ResultFile) { [IO.Path]::GetFullPath($ResultFile, (Get-Location -PSProvider FileSystem).ProviderPath) } else { Join-Path ([IO.Path]::GetTempPath()) "harness-mutation-results-$([guid]::NewGuid().ToString('N')).jsonl" }
$record = { param($entry) if ($resultPath) { [IO.File]::AppendAllText($resultPath, "$(ConvertTo-Json -InputObject $entry -Compress)`n", [Text.UTF8Encoding]::new($false)) } }
if ($resultPath) {
    [IO.File]::WriteAllText($resultPath, '', [Text.UTF8Encoding]::new($false))
    Write-Output "Results, entry by entry: $resultPath"
}
$workRoot = Join-Path ([IO.Path]::GetTempPath()) "harness-mutation-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
try {
    # the unmutated copy first: a red baseline would make every "killed" meaningless
    $baselineEntry = [pscustomobject]@{ Id = 0; File = 'self-test.ps1'; Label = 'baseline (no change)'; Run = @('push', 'pr-open', 'pr-comment', 'pr-merge', 'new-worktree', 'maint', 'shared', 'pre-push', 'check-secrets', 'check-commits', 'privacy'); Find = @(); Replace = @() }
    $baseline = if ($Check) { [pscustomobject]@{ Status = 'SURVIVED'; Detail = '' } } else { & $worker $baselineEntry $maintainerDir $nodeCommand $workRoot $false $TimeoutSeconds }
    & $record $baseline
    # a script block cannot cross into the parallel runspaces as a variable; its text can
    $workerText = $worker.ToString()
    $verifyOnly = $Check.IsPresent
    # the results arrive here one by one, in this thread, so only this thread writes the file
    $results = @($mutations | ForEach-Object -ThrottleLimit $Parallel -Parallel { & ([scriptblock]::Create($using:workerText)) $_ $using:maintainerDir $using:nodeCommand $using:workRoot $using:verifyOnly $using:TimeoutSeconds } | ForEach-Object { & $record $_; $_ })
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$results = @($results | Sort-Object Id)
Write-Output "Baseline (unmutated copy): $(if ($Check) { 'not run (-Check)' } elseif ($baseline.Status -eq 'SURVIVED') { 'all self-tests pass' } else { 'RED: ' + $baseline.Detail })"
Write-Output ''
Write-Output '| # | file | criterion removed or weakened | result | first failing case |'
Write-Output '|---|---|---|---|---|'
foreach ($r in $results) { Write-Output ("| {0} | {1} | {2} | {3} | {4} |" -f $r.Id, $r.File, ($r.Label -replace '\|', '/'), $r.Status, (($r.Detail -replace '\|', '/') -replace '^self-test (case )?failed: ', '')) }
$killed = @($results | Where-Object Status -eq 'killed').Count
$survived = @($results | Where-Object Status -eq 'SURVIVED')
$errors = @($results | Where-Object Status -eq 'ERROR')
$crashed = @($results | Where-Object Status -eq 'CRASH')
Write-Output ''
Write-Output "Mutations: $($results.Count), killed $killed, survived $($survived.Count), crashed $($crashed.Count), errors $($errors.Count)$(if ($Check) { ", valid $(@($results | Where-Object Status -eq 'checked').Count)" })"
if ($baseline.Status -ne 'SURVIVED' -or $survived.Count -or $crashed.Count -or $errors.Count) { exit 1 }
exit 0

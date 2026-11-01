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
#   pwsh scripts/maintainer/lib/mutation-check.ps1 [-Only <text in the label or file>] [-Id 5,9] [-FromId 120]   (ids as listed by -List) [-Parallel 3] [-List] [-Check]
# A run= name is a script (push, pr-open, pr-comment, pr-merge, new-worktree), maint (maint.mjs --self-test) or shared
# (the shared-module and source-hygiene rules of self-test.ps1). A mutation is killed as soon as one of its self-tests turns red.
# A mutated file that no longer parses is an ERROR, not a kill: the self-tests would turn red for the wrong reason.
# -Check only verifies that every text to find occurs exactly once and that every mutated file still parses (seconds, no self-test).
# The result is a markdown table on stdout; exit code 0 only when the unmutated copy passes and every mutation was killed.

[CmdletBinding()]
param([string]$Only, [string]$Id, [int]$FromId = 0, [int]$Parallel = 3, [switch]$List, [switch]$Check, [string]$Table = (Join-Path $PSScriptRoot 'mutations.txt'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$maintainerDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$nodeCommand = if ($env:HARNESS_NODE) { $env:HARNESS_NODE } else { 'node' }

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
    param($Mutation, $SourceDir, $NodePath, $ScratchDir, $CheckOnly)
    $dir = Join-Path $ScratchDir ("m{0:D3}" -f $Mutation.Id)
    $copy = Join-Path $dir 'scripts/maintainer'
    New-Item -ItemType Directory -Force -Path $copy | Out-Null
    Copy-Item -Path (Join-Path $SourceDir '*') -Destination $copy -Recurse -Force
    $result = [ordered]@{ Id = $Mutation.Id; File = $Mutation.File; Label = $Mutation.Label; Status = ''; Detail = '' }
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
        } else {
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
    foreach ($name in $Mutation.Run) {
        $out = if ($name -eq 'maint') { & $NodePath (Join-Path $copy 'lib/maint.mjs') --self-test 2>&1 }
        elseif ($name -eq 'shared') { & ([Environment]::ProcessPath) -NoProfile -File (Join-Path $copy 'self-test.ps1') -Only none 2>&1 }
        else { & ([Environment]::ProcessPath) -NoProfile -File (Join-Path $copy "$name.ps1") -SelfTest 2>&1 }
        $code = $LASTEXITCODE
        $codes.Add("$name=$code")
        if ($code -ne 0) {
            $text = @($out | ForEach-Object { "$_" })
            $named = @($text | Where-Object { $_ -match '^self-test failed: ' } | Select-Object -First 2)
            foreach ($line in $(if ($named.Count) { $named } else { @($text | Where-Object { $_ -match 'FAIL|rror' } | Select-Object -First 2) })) { $failed.Add($line.Trim()) }
            if (-not $failed.Count) { $failed.Add((@($out | ForEach-Object { "$_" } | Select-Object -Last 1) -join '')) }
            break   # one red self-test is enough: the mutation is killed
        }
    }
    $result.Status = if (@($codes | Where-Object { $_ -notmatch '=0$' }).Count) { 'killed' } else { 'SURVIVED' }
    $result.Detail = ($failed | Select-Object -First 2) -join ' / '
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    [pscustomobject]$result
}

$mutations = @(Read-Mutations -Path $Table)
if ($Only) { $mutations = @($mutations | Where-Object { $_.Label -like "*$Only*" -or $_.File -like "*$Only*" }) }
if ($Id) { $wanted = @($Id -split ',' | ForEach-Object { [int]$_.Trim() }); $mutations = @($mutations | Where-Object { $wanted -contains $_.Id }) }
if ($FromId) { $mutations = @($mutations | Where-Object { $_.Id -ge $FromId }) }
if ($List) { $mutations | ForEach-Object { '{0,3} {1} | {2}' -f $_.Id, $_.File, $_.Label }; exit 0 }

$workRoot = Join-Path ([IO.Path]::GetTempPath()) "harness-mutation-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
try {
    # the unmutated copy first: a red baseline would make every "killed" meaningless
    $baselineEntry = [pscustomobject]@{ Id = 0; File = 'self-test.ps1'; Label = 'baseline (no change)'; Run = @('push', 'pr-open', 'pr-comment', 'pr-merge', 'new-worktree', 'maint', 'shared'); Find = @(); Replace = @() }
    $baseline = if ($Check) { [pscustomobject]@{ Status = 'SURVIVED'; Detail = '' } } else { & $worker $baselineEntry $maintainerDir $nodeCommand $workRoot $false }
    # a script block cannot cross into the parallel runspaces as a variable; its text can
    $workerText = $worker.ToString()
    $verifyOnly = $Check.IsPresent
    $results = @($mutations | ForEach-Object -ThrottleLimit $Parallel -Parallel { & ([scriptblock]::Create($using:workerText)) $_ $using:maintainerDir $using:nodeCommand $using:workRoot $using:verifyOnly })
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$results = @($results | Sort-Object Id)
Write-Output "Baseline (unmutated copy): $(if ($Check) { 'not run (-Check)' } elseif ($baseline.Status -eq 'SURVIVED') { 'all self-tests pass' } else { 'RED: ' + $baseline.Detail })"
Write-Output ''
Write-Output '| # | file | criterion removed or weakened | result | first failing case |'
Write-Output '|---|---|---|---|---|'
foreach ($r in $results) { Write-Output ("| {0} | {1} | {2} | {3} | {4} |" -f $r.Id, $r.File, ($r.Label -replace '\|', '/'), $r.Status, (($r.Detail -replace '\|', '/') -replace '^self-test failed: ', '')) }
$killed = @($results | Where-Object Status -eq 'killed').Count
$survived = @($results | Where-Object Status -eq 'SURVIVED')
$errors = @($results | Where-Object Status -eq 'ERROR')
Write-Output ''
Write-Output "Mutations: $($results.Count), killed $killed, survived $($survived.Count), errors $($errors.Count)$(if ($Check) { ", valid $(@($results | Where-Object Status -eq 'checked').Count)" })"
if ($baseline.Status -ne 'SURVIVED' -or $survived.Count -or $errors.Count) { exit 1 }
exit 0

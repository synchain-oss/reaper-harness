# SPDX-License-Identifier: MIT
#
# Probe variables of a plugin (plugins.<id>.probe, asked for by scenarios[].probe of a render): environment variables
# whose values are paths the harness makes for the launch that renders the scenario, and the files the plugin writes
# into the directory one of them names. A configuration never gives a value of its own.
#   Read-HarnessProbeFiles -Config <config> -Scenarios <picked>
#       before REAPER starts: every file a probe variable of a picked scenario names is resolved like an extension path,
#       checked to be at most 1 MiB, read once and hashed. All problems are one usage error: REAPER is never started.
#       Returns the files by key (Get-HarnessSourceKey): Rel, Path, Sha256 (full), Bytes.
#   Get-HarnessProbePlan -ConfigDir -Scenario -Work -Checked   (pure) $null without probe, else Vars (Name, Plugin,
#       Kind, Min, Key, Path, Checked), Dir (the Var of kind dir, or $null) and Env (name -> Path). A file's place is
#       <work>\<id>.probe-<NAME><ext>, the directory <work>\<id>.out. The one builder: the scenario makes and sets what it
#       says, and collection reads it again
#   New-HarnessProbeRun -Ctx -Scenario   right before the test render: each file copied for this launch (the copy's hash
#       must be the checked one), the directory made new and empty; @{ Env; Why } (Why: the first problem, or $null)
#   Get-HarnessProbeEntries -Path        the top level of a directory, nothing followed: Name, Kind (link, dir, file),
#       Bytes; Over when it has more than 10000 entries (nothing is listed then)
#   Test-HarnessProbeFileName -Name      (pure) a name collection may use: 1 to 100 ASCII letters, digits, '.', '_'
#       and '-', starting with a letter or digit, not ending in '.', not a device name
#   Get-HarnessProbeSelection -Entries -Min   (pure) what to move (ordinal order, within 32 files, 16 MiB in all and
#       4 MiB each), the reasons for what stays (a bad name is never named), and how many entries stay
#   Remove-HarnessEmptyDirectory -Path   removes a directory that is empty and not a link, never recursing

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Extensions.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Sources.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Plugins.psm1') -ErrorAction Stop

$script:MaxFiles = 32
$script:MaxTotal = 16MB
$script:MaxFile = 4MB
$script:MaxEntries = 10000
$script:MaxInput = 1MB
# A plugin writes <dir>\<name> with a name of up to 100 characters; a directory path longer than this leaves it no room
$script:MaxDirPath = 140

function Read-HarnessProbeFiles {
    param([Parameter(Mandatory)]$Config, [object[]]$Scenarios = @())
    $bad = [Collections.Generic.List[string]]::new()
    $files = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Scenarios) {
        if (-not $s.PSObject.Properties['probe'] -or -not $s.probe) { continue }
        foreach ($e in @($s.probe.get_Values() | Where-Object { $_.Kind -ceq 'file' })) {
            $key = Get-HarnessSourceKey $Config.ConfigDir $e.File
            if (-not $seen.Add($key)) { continue }
            try {
                $full = Resolve-HarnessExtensionPath -ConfigDir $Config.ConfigDir -Relative $key -What 'probe'
                # The size is checked before the bytes are read, and again on what was read
                if ((Get-Item -LiteralPath $full).Length -gt $script:MaxInput) { $bad.Add("probe $key is larger than $($script:MaxInput) bytes"); continue }
                $bytes = [IO.File]::ReadAllBytes($full)
                if ($bytes.Length -gt $script:MaxInput) { $bad.Add("probe $key is larger than $($script:MaxInput) bytes"); continue }
                $files[$key] = [pscustomobject]@{ Rel = $key; Path = $full; Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant(); Bytes = $bytes.Length }
            } catch { $bad.Add("probe $key cannot be used: $($_.Exception.Message -replace '^USAGE: ', '')") }
        }
    }
    if ($bad.Count) { Stop-Usage ("probe files: $($bad.Count) problem(s): " + ($bad -join '; ')) }
    $files
}

# The '.probe-' and '.out' parts keep these apart from every other work file of the scenario (<id>.rpp, <id>.result,
# <id>.job.lua, <id>.report-<plugin>.json): a variable named RESULT must not give <id>.RESULT, which Windows takes for
# <id>.result. Scenario ids have no dots. The extension of a file is kept when it is a plain one: some plugins look at it.
function Get-HarnessProbePlan {
    param([Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)][string]$Work, $Checked = @{})
    if (-not $Scenario.PSObject.Properties['probe'] -or -not $Scenario.probe) { return $null }
    $vars = @(foreach ($e in $Scenario.probe.get_Values()) {
            $key = ''; $hit = $null
            if ($e.Kind -ceq 'file') {
                $key = Get-HarnessSourceKey $ConfigDir $e.File
                $ext = [IO.Path]::GetExtension($e.File)
                $leaf = "$($Scenario.id).probe-$($e.Name)" + (($ext -cmatch '\A\.[A-Za-z0-9]{1,16}\z') ? $ext : '')
                if ($null -ne $Checked -and $Checked.Contains($key)) { $hit = $Checked[$key] }
            } else { $leaf = "$($Scenario.id).out" }
            [pscustomobject]@{ Name = $e.Name; Plugin = $e.Plugin; Kind = $e.Kind; Min = $e.Min; Key = $key; Path = [IO.Path]::GetFullPath((Join-Path $Work $leaf)); Checked = $hit }
        })
    $values = @{}
    foreach ($v in $vars) { $values[$v.Name] = $v.Path }
    [pscustomobject]@{ Vars = $vars; Dir = ($vars | Where-Object { $_.Kind -ceq 'dir' } | Select-Object -First 1); Env = $values }
}

# ProbeRuns records the run as made, with the count of processes started before it: collection takes nothing from a
# directory this round did not make, and the pid of the launch from what was started after.
function New-HarnessProbeRun {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Scenario)
    $plan = Get-HarnessProbePlan -ConfigDir $Ctx.Config.ConfigDir -Scenario $Scenario -Work $Ctx.Work -Checked $Ctx['ProbeFiles']
    if ($null -eq $plan) { return @{ Env = @{}; Why = $null } }
    $fail = { param([string]$Why) @{ Env = @{}; Why = $Why } }
    foreach ($v in $plan.Vars) {
        if ($v.Kind -ceq 'file') {
            if ($null -eq $v.Checked) { return & $fail "probe file $($v.Key) was not checked before the start" }
            try {
                if (Test-Path -LiteralPath $v.Path) { Remove-Item -LiteralPath $v.Path -Force }
                [IO.File]::Copy($v.Checked.Path, $v.Path, $false)
                [IO.File]::SetAttributes($v.Path, [IO.FileAttributes]::Normal)
                $Ctx.Files.Add($v.Path)
                if ((Get-HarnessSha256 $v.Path) -cne $v.Checked.Sha256) { Remove-Item -LiteralPath $v.Path -Force; return & $fail "probe file $($v.Key) changed since it was checked" }
            } catch { return & $fail "probe file $($v.Key) could not be copied: $($_.Exception.Message -replace '\s+', ' ')" }
        } else {
            if ($v.Path.Length -gt $script:MaxDirPath) { return & $fail 'the probe directory path is too long for a plugin to write into it' }
            # Never -Force: a directory that is there already is not reused
            try { $null = New-Item -ItemType Directory -Path $v.Path }
            catch { return & $fail ((Test-Path -LiteralPath $v.Path) ? "the probe directory $(Split-Path -Leaf $v.Path) is there already" : "the probe directory $(Split-Path -Leaf $v.Path) could not be made: $($_.Exception.Message -replace '\s+', ' ')") }
            $Ctx.Dirs.Add($v.Path)
        }
    }
    $Ctx.ProbeRuns[$Scenario.id] = @{ From = $Ctx.Started.Count }
    @{ Env = $plan.Env; Why = $null }
}

# A link or junction is 'link' whatever it points at (checked first) and is never followed.
function Get-HarnessProbeEntries([Parameter(Mandatory)][string]$Path) {
    $listed = [Collections.Generic.List[object]]::new()
    foreach ($i in [IO.DirectoryInfo]::new($Path).EnumerateFileSystemInfos()) {
        if ($listed.Count -ge $script:MaxEntries) { return @{ Entries = @(); Over = $true } }
        $kind = ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) ? 'link' : (($i -is [IO.DirectoryInfo]) ? 'dir' : 'file')
        $listed.Add(@{ Name = $i.Name; Kind = $kind; Bytes = (($kind -ceq 'file') ? $i.Length : [long]0) })
    }
    @{ Entries = $listed.ToArray(); Over = $false }
}

function Get-HarnessCount([long]$N, [string]$Word) { "$N $Word$(($N -eq 1) ? '' : 's')" }

function Test-HarnessProbeFileName([AllowNull()][AllowEmptyString()][string]$Name) {
    $Name -cmatch '\A(?!(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|\z))[A-Za-z0-9](?:[A-Za-z0-9._-]{0,98}[A-Za-z0-9_-])?\z'
}

# Entries: @{ Name; Kind (link | dir | file); Bytes }. A file over 4 MiB is passed over; the first file that would pass
# 32 files or 16 MiB in all ends the walk, and it and every file after it stay. A name ending in .tmp (any case) is
# moved and marked Temporary, and does not count for Min.
function Get-HarnessProbeSelection {
    param([object[]]$Entries = @(), [int]$Min = 0)
    $move = [Collections.Generic.List[object]]::new()
    $problems = [Collections.Generic.List[string]]::new()
    $left = 0
    $badNames = @($Entries | Where-Object { -not (Test-HarnessProbeFileName $_.Name) }).Count
    if ($badNames) { $problems.Add("$badNames $(($badNames -eq 1) ? 'entry' : 'entries') whose name is not allowed (letters, digits, '.', '_' and '-', at most 100)"); $left += $badNames }
    $named = @($Entries | Where-Object { Test-HarnessProbeFileName $_.Name })
    foreach ($e in $named) {
        if ($e.Kind -ceq 'dir') { $problems.Add("a subdirectory $($e.Name)"); $left++ }
        elseif ($e.Kind -ceq 'link') { $problems.Add("a link or junction $($e.Name) (not followed)"); $left++ }
    }
    $plain = [Collections.Generic.List[object]]::new()
    foreach ($e in $named) { if ($e.Kind -ceq 'file') { $plain.Add($e) } }
    $plain.Sort([Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Name, $b.Name) })
    $total = [long]0
    for ($i = 0; $i -lt $plain.Count; $i++) {
        $f = $plain[$i]
        if ($f.Bytes -gt $script:MaxFile) { $problems.Add("$($f.Name) is larger than $($script:MaxFile) bytes"); $left++; continue }
        $limit = ($move.Count + 1 -gt $script:MaxFiles) ? "more than $($script:MaxFiles) files" : (($total + $f.Bytes -gt $script:MaxTotal) ? "more than $($script:MaxTotal) bytes in all" : '')
        if ($limit) { $rest = $plain.Count - $i; $problems.Add("${limit}: $(Get-HarnessCount $rest 'file') left in the work directory"); $left += $rest; break }
        $total += $f.Bytes
        $move.Add([pscustomobject]@{ Name = $f.Name; Bytes = [long]$f.Bytes; Temporary = $f.Name.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase) })
    }
    $real = @($move | Where-Object { -not $_.Temporary }).Count
    if ($real -lt $Min) { $problems.Add("$(Get-HarnessCount $real 'file') to collect, fewer than the $Min asked for (min)") }
    @{ Move = $move.ToArray(); Problems = $problems.ToArray(); Left = $left }
}

# Never recursive: a directory with anything in it, or one that is a link or junction, is left as it is (and a file:
# Directory.Delete refuses one).
function Remove-HarnessEmptyDirectory([Parameter(Mandatory)][string]$Path) {
    try {
        if ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) { return $false }
        [IO.Directory]::Delete($Path, $false)
        $true
    } catch { $false }
}

Export-ModuleMember -Function Get-HarnessCount, Read-HarnessProbeFiles, Get-HarnessProbePlan, New-HarnessProbeRun, Get-HarnessProbeEntries, Test-HarnessProbeFileName, Get-HarnessProbeSelection, Remove-HarnessEmptyDirectory

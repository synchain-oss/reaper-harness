# SPDX-License-Identifier: MIT
#
# Plugin self-reports. A plugin can be declared with a report (plugins.<id>.report): the name of an environment variable
# through which it is told the path of a small JSON file it writes its own counts to, the numeric fields to take from it
# and, optionally, the field that holds the id of the process that wrote it. The harness sets that variable for the
# REAPER it starts and for no other process (names the system reads are refused: Test-HarnessReportEnvName in
# Guard.psm1); the path is a new file in the work directory for every driver step. The
# driver (lua/driver.lua) copies the file at chosen moments, after waiting for a write that is newer than the moment;
# this module reads the copies and judges a field by its value at the end of a stretch or by how much it grew in it.
#   Get-HarnessReportPlan        the reports of the plugins of a layout for one driver step (pure)
#   Get-HarnessReportEnvironment its variables; ConvertTo-HarnessReportJob what the driver gets of it (pure)
#   Read-HarnessReportCopy       one copy, checked: a JSON object, the declared fields numbers, the pid this launch's
#   Read-HarnessReportReading    reading k of every report of a plan, from the driver's facts and the copies
#   Test-HarnessReportCriteria   criteria against two readings (pure)
# Counts are whatever the plugin writes: the harness only knows they are numbers. A plugin that writes per-process totals
# has to be the only instance of its kind in the project, which the configuration enforces for every plugin it judges.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Json.psm1') -ErrorAction Stop

$script:MaxBytes = 65536 # the driver copies no more (lua/driver.lua REPORT_MAX)
# Plugins: the configuration's plugins; Layout: the layout the step opens (only plugins it uses get a report); Work,
# Name: where the files go. Every row: Plugin, Env, Path (the file the plugin is told to write), Copy (the driver writes
# reading k to Copy + k + '.json'), Fields, PidField, PeriodMs.
function Get-HarnessReportPlan {
    param([Parameter(Mandatory)]$Plugins, [Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Name)
    $used = @($Layout.Tracks | ForEach-Object { $_.Fx } | ForEach-Object { $_.Plugin } | Sort-Object -Unique -CaseSensitive)
    , @(foreach ($id in $used) {
            $r = $Plugins[$id].Report
            if ($null -eq $r) { continue }
            [pscustomobject]@{ Plugin = $id; Env = $r.Env; Path = (Join-Path $Work "$Name.report-$id.json"); Copy = (Join-Path $Work "$Name.report-$id.copy-"); Fields = $r.Fields; PidField = $r.PidField; PeriodMs = $r.PeriodMs }
        })
}

# The environment of a plan: variable -> file, for Invoke-HarnessLuaStep -ReportEnv.
function Get-HarnessReportEnvironment([object[]]$Plan = @()) {
    $vars = @{}
    foreach ($r in $Plan) { $vars[$r.Env] = $r.Path }
    $vars
}

# The driver's job.reports (the fields and the pid field go along for the self-test's stand-in; the driver reads only
# path, copy and period).
function ConvertTo-HarnessReportJob([object[]]$Plan = @()) {
    , @(foreach ($r in $Plan) { @{ path = $r.Path; copy = $r.Copy; period = $r.PeriodMs / 1000.0; fields = @($r.Fields); pid = $r.PidField } })
}

function Test-HarnessReportNumber($v) { ($v -is [long] -or $v -is [int]) -or ($v -is [double] -and -not [double]::IsNaN($v) -and -not [double]::IsInfinity($v)) }

# One copy of a report. Returns @{ Numbers (field -> number, the declared fields only); Problem ($null or why the copy
# is no evidence) }. ProcessId: the REAPER this step started; with a pid field the copy must name it.
function Read-HarnessReportCopy {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Fields, [string]$PidField = '', [int]$ProcessId = 0)
    $no = { param($why) [pscustomobject]@{ Numbers = $null; Problem = $why } }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return & $no 'no copy of it was made' }
    if ((Get-Item -LiteralPath $Path).Length -gt $script:MaxBytes) { return & $no "it is larger than $($script:MaxBytes) bytes" }
    try { $doc = ConvertFrom-HarnessJson ([IO.File]::ReadAllText($Path)) } catch { return & $no 'it is not JSON' }
    if ($doc -isnot [System.Collections.IDictionary]) { return & $no 'it is not a JSON object' }
    if ($PidField) {
        $p = $doc.Contains($PidField) ? $doc[$PidField] : $null
        if (-not ($p -is [long] -or $p -is [int])) { return & $no "its $PidField is not an integer" }
        if ($p -ne $ProcessId) { return & $no "it was written by process $p, not by the REAPER of this step ($ProcessId)" }
    }
    $values = [ordered]@{}
    foreach ($f in $Fields) {
        $v = $doc.Contains($f) ? $doc[$f] : $null
        if ($null -eq $v) { return & $no "it has no field $f" }
        if (-not (Test-HarnessReportNumber $v)) { return & $no "its field $f is not a number" }
        $values[$f] = [double]$v
    }
    [pscustomobject]@{ Numbers = $values; Problem = $null }
}

# Reading K (1-based) of every report of the plan: plugin -> @{ Numbers; Problem }. Facts: the driver's result, which
# says per report j and reading k (rep<j>_<k>) whether it copied a fresh file (changed: written after the moment of the
# reading; quiet: unchanged over four write periods after it) or why not (missing, toolarge, stale, busy).
function Read-HarnessReportReading {
    param([Parameter(Mandatory)][hashtable]$Facts, [Parameter(Mandatory)][object[]]$Plan, [Parameter(Mandatory)][int]$K, [int]$ProcessId = 0)
    $out = [ordered]@{}
    for ($j = 0; $j -lt $Plan.Count; $j++) {
        $r = $Plan[$j]
        $status = $Facts["rep$($j + 1)_$K"]
        $why = switch -CaseSensitive ($status) {
            'missing' { "the plugin wrote no report ($($r.Env))" }
            'toolarge' { "its report is larger than $($script:MaxBytes) bytes" }
            'stale' { 'no fresh report could be read in time' }
            'busy' { 'its report kept changing where it had to stay the same: the plugin was still being run' }
            { $_ -cin 'changed', 'quiet' } { $null }
            default { 'the driver took no reading' }
        }
        $out[$r.Plugin] = $why ? [pscustomobject]@{ Numbers = $null; Problem = $why } : (Read-HarnessReportCopy -Path "$($r.Copy)$K.json" -Fields $r.Fields -PidField $r.PidField -ProcessId $ProcessId)
    }
    $out
}

function Format-HarnessReportNumber([double]$v) { $v.ToString(([Math]::Floor($v) -eq $v) ? '0' : 'R', [Globalization.CultureInfo]::InvariantCulture) }

function Test-HarnessReportBound($Bound, [double]$v) { ($null -ne $Bound.Exact) ? ($v -eq $Bound.Exact) : (($null -eq $Bound.Min -or $v -ge $Bound.Min) -and ($null -eq $Bound.Max -or $v -le $Bound.Max)) }

function Format-HarnessReportBound($Bound) {
    if ($null -ne $Bound.Exact) { return Format-HarnessReportNumber $Bound.Exact }
    ($null -ne $Bound.Min ? (Format-HarnessReportNumber $Bound.Min) : '') + '..' + ($null -ne $Bound.Max ? (Format-HarnessReportNumber $Bound.Max) : '')
}

# Criteria (plugin -> field -> @{ Delta; Value }, each $null or a bound @{ Exact; Min; Max }) against the readings at the
# start and the end of a stretch (Read-HarnessReportReading). Returns Gaps (no evidence: INCOMPLETE), Problems (a
# criterion not met: FAIL), Text (what was seen of the judged fields: "id.field=end (+delta)") and Facts (plugin ->
# field -> @{ start; end; delta }, every declared field of both readings that could be read).
function Test-HarnessReportCriteria {
    param([System.Collections.IDictionary]$Criteria = @{}, [Parameter(Mandatory)][System.Collections.IDictionary]$Start, [Parameter(Mandatory)][System.Collections.IDictionary]$End)
    $gaps = [Collections.Generic.List[string]]::new()
    $bad = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.List[string]]::new()
    $seenFacts = [ordered]@{}
    foreach ($id in $End.get_Keys()) {
        $a = $Start[$id]; $b = $End[$id]
        if ($a -and $b -and $null -ne $a.Numbers -and $null -ne $b.Numbers) {
            $seenFacts[$id] = [ordered]@{}
            foreach ($f in $b.Numbers.get_Keys()) { $seenFacts[$id][$f] = [ordered]@{ start = $a.Numbers[$f]; end = $b.Numbers[$f]; delta = $b.Numbers[$f] - $a.Numbers[$f] } }
        }
    }
    foreach ($id in $Criteria.get_Keys()) {
        $a = $Start[$id]; $b = $End[$id]
        $missing = @(@($a, $b) | Where-Object { $null -eq $_ -or $null -eq $_.Numbers })
        if ($missing.Count) {
            $why = @($missing | ForEach-Object { $_ ? $_.Problem : 'no reading was taken' } | Select-Object -Unique)
            $gaps.Add("the report of $id is no evidence: $($why -join '; ')"); continue
        }
        foreach ($f in $Criteria[$id].get_Keys()) {
            $c = $Criteria[$id][$f]
            $last = $b.Numbers[$f]; $delta = $last - $a.Numbers[$f]
            $seen.Add("$id.$f=$(Format-HarnessReportNumber $last) ($($delta -ge 0 ? '+' : '')$(Format-HarnessReportNumber $delta))")
            if ($c.Delta -and -not (Test-HarnessReportBound $c.Delta $delta)) { $bad.Add("$id.$f grew by $(Format-HarnessReportNumber $delta), expected $(Format-HarnessReportBound $c.Delta)") }
            if ($c.Value -and -not (Test-HarnessReportBound $c.Value $last)) { $bad.Add("$id.$f is $(Format-HarnessReportNumber $last), expected $(Format-HarnessReportBound $c.Value)") }
        }
    }
    [pscustomobject]@{ Gaps = $gaps.ToArray(); Problems = $bad.ToArray(); Text = ($seen -join ' '); Facts = $seenFacts }
}

Export-ModuleMember -Function Get-HarnessReportPlan, Get-HarnessReportEnvironment, ConvertTo-HarnessReportJob, Read-HarnessReportCopy, Read-HarnessReportReading, Test-HarnessReportCriteria

# SPDX-License-Identifier: MIT
#
# A stand-in for REAPER for the self-test's end-to-end case (the CI machine has no REAPER). It is handed to
# Invoke-HarnessHost as the Launcher: it does what REAPER would do with the command line (render a project, or run
# one driver step from the job file) right away, then starts a short-lived pwsh as "the process" (a sleeping one
# for the hang step). Plugins are pass-through. Parameter values travel inside the plugin blocks, like real plugin
# state, so device and savereopen read back what the learn step set.
#   Set-FakeReaper -Spec @{ Pwsh; CfgDir; Plugins (REAPER name -> @{ Bundle; Cid }); Seen (a list) }
#   Get-FakeReaperLauncher / Get-FakeModuleSampler   script blocks for the context (Launcher, ModuleSampler)
#   ConvertFrom-FakeLua <text>                        reads a job file written by ConvertTo-HarnessLuaTable

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '../src/Wav.psm1') -ErrorAction Stop

$script:Spec = $null
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Src = ''
$script:At = 0

function Set-FakeReaper([hashtable]$Spec) { $script:Spec = $Spec }
function Get-FakeReaperLauncher { { param($psi) Invoke-FakeLaunch $psi } }
function Get-FakeModuleSampler { { param($proc) @(Get-FakeBinaries) } }

function Get-FakeBinaries {
    foreach ($p in $script:Spec.Plugins.get_Values()) { [IO.Path]::Combine($script:Spec.CfgDir, 'plugins', $p.Bundle, 'Contents', 'x86_64-win', $p.Bundle) }
}

# ---- job files ----
function ConvertFrom-FakeLua([string]$Text) {
    $script:Src = $Text.Trim() -replace '^return ', ''
    $script:At = 0
    Read-FakeLuaValue
}

function Read-FakeLuaValue {
    $c = $script:Src[$script:At]
    if ($c -eq '{') {
        $script:At++
        $list = [Collections.Generic.List[object]]::new()
        $map = [ordered]@{}
        while ($script:Src[$script:At] -ne '}') {
            if ($script:Src[$script:At] -eq '[') {
                $script:At++
                $key = Read-FakeLuaValue
                $script:At += 2 # ']='
                $map[$key] = Read-FakeLuaValue
            } else { $list.Add((Read-FakeLuaValue)) }
            if ($script:Src[$script:At] -eq ',') { $script:At++ }
        }
        $script:At++
        if ($map.Count) { return $map }
        return , $list.ToArray()
    }
    if ($c -eq '"') {
        $sb = [Text.StringBuilder]::new()
        $script:At++
        while ($script:Src[$script:At] -ne '"') {
            $ch = $script:Src[$script:At]
            if ($ch -eq '\') {
                $script:At++
                $esc = $script:Src[$script:At]
                $ch = switch ($esc) { 'n' { "`n" } 'r' { "`r" } default { $esc } }
            }
            $null = $sb.Append($ch)
            $script:At++
        }
        $script:At++
        return $sb.ToString()
    }
    $m = [regex]::Match($script:Src.Substring($script:At), '^(nil|true|false|-?[0-9][0-9.eE+-]*)')
    $script:At += $m.Length
    switch ($m.Value) { 'nil' { return $null } 'true' { return $true } 'false' { return $false } }
    [double]::Parse($m.Value, $script:Inv)
}

# ---- projects ----
# Tracks of a project: Name, Volume, Isbus, Source (wav path or ''), Fx (Name, Bypassed, Params name -> value).
function Read-FakeProject([string]$Text) {
    $tracks = [Collections.Generic.List[object]]::new()
    $cur = $null
    $bypassNext = $false
    $fx = $null
    foreach ($raw in ($Text -split '\r?\n')) {
        $s = $raw.Trim()
        if ($s -eq '<TRACK') { $cur = [pscustomobject]@{ Name = ''; Volume = 1.0; Isbus = '0 0'; Source = ''; Fx = [Collections.Generic.List[object]]::new() }; $tracks.Add($cur); continue }
        if ($null -eq $cur) { continue }
        if ($s -match '^NAME "(.*)"$' -and -not $cur.Name) { $cur.Name = $Matches[1] }
        elseif ($s -match '^VOLPAN (\S+)') { $cur.Volume = [double]::Parse($Matches[1], $script:Inv) }
        elseif ($s -match '^ISBUS (\S+ \S+)') { $cur.Isbus = $Matches[1] }
        elseif ($s -match '^FILE "(.*)"$') { $cur.Source = $Matches[1] }
        elseif ($s -match '^BYPASS (\d)') { $bypassNext = $Matches[1] -ne '0' }
        elseif ($s -match '^<VST "([^"]*)"') { $fx = [pscustomobject]@{ Name = $Matches[1]; Bypassed = $bypassNext; Params = [ordered]@{} }; $cur.Fx.Add($fx) }
        elseif ($s -match '^FAKESTATE (\S*)$' -and $fx) {
            $state = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
            foreach ($pair in ($state -split ';' | Where-Object { $_ })) { $kv = $pair -split '=', 2; $fx.Params[$kv[0]] = [double]::Parse($kv[1], $script:Inv) }
        }
    }
    , $tracks.ToArray()
}

function Invoke-FakeRender([string]$Project) {
    $projectText = [IO.File]::ReadAllText($Project)
    $dir = [regex]::Match($projectText, '(?m)^\s*RENDER_FILE "(.*)"').Groups[1].Value
    $name = [regex]::Match($projectText, '(?m)^\s*RENDER_PATTERN "(.*)"').Groups[1].Value
    $rate = [int][regex]::Match($projectText, '(?m)^\s*SAMPLERATE (\d+)').Groups[1].Value
    $sum = $null
    $channels = 2
    $gains = [Collections.Generic.List[double]]::new() # volumes of the enclosing folders
    foreach ($t in (Read-FakeProject $projectText)) {
        $g = $t.Volume
        foreach ($x in $gains) { $g *= $x }
        if ($t.Source) {
            $w = Read-HarnessWav $t.Source
            $channels = $w.Channels
            if ($null -eq $sum) { $sum = [double[]]::new($w.Samples.Length) }
            for ($i = 0; $i -lt $w.Samples.Length; $i++) { $sum[$i] += $g * $w.Samples[$i] }
        }
        $flag = $t.Isbus -split ' '
        if ($flag[0] -eq '1') { $gains.Add($t.Volume) }
        elseif ($flag[0] -eq '2') { for ($k = 0; $k -lt -[int]$flag[1]; $k++) { $gains.RemoveAt($gains.Count - 1) } }
    }
    Write-HarnessWav -Path (Join-Path $dir "$name.wav") -Rate $rate -Channels $channels -Format float32 -Samples $sum
}

# ---- driver steps ----
function Format-Fake([double]$Value) { $Value.ToString('0.000000000', $script:Inv) }

function Add-FakeTracks($Lines, [string]$Prefix, [string]$Project, $Reads) {
    $tracks = Read-FakeProject ([IO.File]::ReadAllText($Project))
    $Lines.Add("${Prefix}tracks=$($tracks.Count)")
    for ($t = 0; $t -lt $tracks.Count; $t++) {
        $Lines.Add("${Prefix}t${t}_name=$($tracks[$t].Name)")
        $Lines.Add("${Prefix}t${t}_fx_count=$($tracks[$t].Fx.Count)")
        for ($f = 0; $f -lt $tracks[$t].Fx.Count; $f++) {
            $x = $tracks[$t].Fx[$f]
            $q = "${Prefix}t${t}_fx${f}_"
            foreach ($kv in @("name=$($x.Name)", 'pdc=0', 'chain_pdc_actual=0', "bypassed=$($x.Bypassed.ToString().ToLowerInvariant())", 'offline=false')) { $Lines.Add($q + $kv) }
        }
    }
    $k = 0
    foreach ($r in @($Reads)) {
        $k++
        $q = "${Prefix}t$([int]$r['t'])_fx$([int]$r['f'])_"
        $fx = $tracks[[int]$r['t']].Fx[[int]$r['f']]
        if ($fx.Params.Contains($r['name'])) { $v = $fx.Params[$r['name']]; $Lines.Add("${q}param$k=$(Format-Fake $v)"); $Lines.Add("${q}display$k=$($v.ToString('0.00', $script:Inv))") }
        else { $Lines.Add("${q}param$k=missing") }
    }
}

function Get-FakeIniValue([string]$IniKey) {
    $ini = [IO.File]::ReadAllText((Join-Path $script:Spec.CfgDir 'reaper.ini'))
    [regex]::Match($ini, "(?m)^$IniKey=(.*?)\r?$").Groups[1].Value
}

# Runs one step; returns how the stand-in process should behave: quick, linger (alive long enough to be sampled) or
# hang.
function Invoke-FakeStep([string]$JobFile) {
    $job = ConvertFrom-FakeLua ([IO.File]::ReadAllText($JobFile))
    $report = [Collections.Generic.List[string]]::new()
    $behave = 'quick'
    switch ($job['step']) {
        'learn' {
            $behave = 'linger'
            $rpp = [Text.StringBuilder]::new("<REAPER_PROJECT 0.1 `"7.0/win64`" 0 0`n")
            $n = 0
            foreach ($e in @($job['fx'])) {
                $n++
                $key = "fx${n}_"
                $p = $script:Spec.Plugins[$e['name']]
                if (-not $p) { $report.Add("${key}idx=-1"); continue }
                $binary = [IO.Path]::Combine($script:Spec.CfgDir, 'plugins', $p.Bundle, 'Contents', 'x86_64-win', $p.Bundle)
                foreach ($kv in @('idx=0', "name=$($e['name'])", "ident=$binary<1234567890{$($p.Cid)", 'pdc=0', 'offline=false', 'nparams=4')) { $report.Add($key + $kv) }
                $state = ''
                $k = 0
                foreach ($prm in @($e['params'])) {
                    $k++
                    $report.Add("${key}p$k=$(Format-Fake $prm['value'])"); $report.Add("${key}p${k}_display=$(([double]$prm['value']).ToString('0.00', $script:Inv))")
                    $state += "$($prm['name'])=$(([double]$prm['value']).ToString('R', $script:Inv));"
                }
                $null = $rpp.Append("  <TRACK`n    NAME `"learn-$n`"`n    <FXCHAIN`n      BYPASS 0 0 0`n      <VST `"$($e['name'])`" `"$($p.Bundle)`" 0 `"`" 1234567890{$($p.Cid)} `"`"`n")
                $null = $rpp.Append("        FAKESTATE $([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($state)))`n      >`n    >`n  >`n")
            }
            $null = $rpp.Append(">`n")
            [IO.File]::WriteAllText($job['saveAs'], $rpp.ToString())
            $report.Add('saved=true')
        }
        'device' {
            foreach ($kv in @("dev_bsize=$(Get-FakeIniValue 'dummy_blocksize')", "dev_srate=$(Get-FakeIniValue 'dummy_srate')", 'dev_mode=dummy', 'project_srate=0')) { $report.Add($kv) }
            Add-FakeTracks $report '' $job['project'] $job['reads']
        }
        'savereopen' {
            Add-FakeTracks $report 'before_' $job['project'] $job['reads']
            Copy-Item -LiteralPath $job['project'] -Destination $job['saveAs']
            Add-FakeTracks $report 'after_' $job['saveAs'] $job['reads']
            $report.Add('saved=true')
        }
        'instances' {
            $behave = 'linger'
            $report.Add("cycles_done=$([int]$job['cycles'])"); $report.Add('tracks_left=0')
            foreach ($mark in $job['warmMark'], $job['loopMark']) { [IO.File]::WriteAllText($mark, '1') }
        }
        'hang' { return 'hang' }
        default { $report.Add("error=no such step: $($job['step'])") }
    }
    [IO.File]::WriteAllText($job['result'], (($report + 'done=1') -join "`n") + "`n")
    $behave
}

function Invoke-FakeLaunch($psi) {
    $given = @($psi.ArgumentList)
    $script:Spec.Seen.Add($given -join ' ')
    $behave = 'quick'
    $renderAt = [array]::IndexOf($given, '-renderproject')
    if ($renderAt -ge 0) { Invoke-FakeRender $given[$renderAt + 1] }
    elseif ($psi.Environment['REAPER_HARNESS_JOB']) { $behave = Invoke-FakeStep $psi.Environment['REAPER_HARNESS_JOB'] }
    $psi.FileName = $script:Spec.Pwsh
    $psi.ArgumentList.Clear()
    foreach ($part in '-NoProfile', '-NonInteractive', '-Command', @{ quick = 'exit 0'; linger = 'Start-Sleep -Milliseconds 1500'; hang = 'Start-Sleep -Seconds 60' }[$behave]) { $psi.ArgumentList.Add($part) }
    [Diagnostics.Process]::Start($psi)
}

Export-ModuleMember -Function Set-FakeReaper, Get-FakeReaperLauncher, Get-FakeModuleSampler, ConvertFrom-FakeLua

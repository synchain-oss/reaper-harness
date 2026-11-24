# SPDX-License-Identifier: MIT
#
# A stand-in for REAPER for the self-test's end-to-end case (the CI machine has no REAPER). It is handed to
# Invoke-HarnessHost as the Launcher: it does what REAPER would do with the command line (render a project, or run
# one driver step from the job file) right away, then starts a short-lived pwsh as "the process" (a sleeping one
# for the hang step). Parameter values travel inside the plugin blocks, like real plugin state, so device and
# savereopen read back what the learn step set, and a state block put into a project is what the plugin then holds.
# The mix follows what REAPER was measured to do (docs/CONFIG.md): folders sum their children, sends tap before the
# FX (prefx), after the FX (pre) or after the fader (post), pan is a balance (the far side is turned down), a muted
# track and all its sends are silent, a stem is the track's output whether or not it goes to the master.
# The transport step follows what REAPER was measured to do too (see Invoke-FakeTransport).
# Plugins: a parameter named "Trim" is a gain of 2 x its value (0.5 = unchanged); every other parameter does
# nothing. The PDC JSFX reports "Delay (samples)" as PDC and, being compensated, leaves the timing alone; with
# "Report delay as PDC" off it delays the audio instead.
#   Set-FakeReaper -Spec @{ Pwsh; CfgDir; Plugins (REAPER name -> @{ Bundle; Cid }); Seen (a list) }
#       EnvName, EnvSeen (a list): the value of that variable in the environment of every launch ('' when unset)
#       EnvNames (a list), EnvLog (a list): every launch adds [ordered]@{ args (its arguments joined); <name> (the value
#       of each of EnvNames in its environment, '' when unset) }
#       Probe = @{ Script; Out; Steps; Fault; LateFinal; LateTmp; Outside }: a launch that renders (-renderproject or
#       the driver's render step) and has the variable Out set writes into that directory step-001.json ... step-<Steps>.json
#       and final.json ({"script":"<sha256 of the file the variable Script names, or null>","bytes":<its length>}).
#       LateFinal: final.json is written by the stand-in process as its very last step (LateTmp: final.json.4242.tmp
#       too), so it is only there once the process has exited. Faults: Subdir (also sub\x.json), Junction (also a
#       junction "link" to the directory Outside), DirLink (the directory replaced by a junction to Outside), BadName
#       (also "bad name!.json" and ".hidden"), Big (also big.bin of 4 MiB + 1), Many (only m-01.json ... m-33.json),
#       Total (only t1.bin ... t5.bin of 4 MiB each), Tmp (also final.json.4242.tmp), TmpOnly (only
#       final.json.4242.tmp), None (nothing)
#       FileAtStart (a list): whether the file that variable names was there when a launch started; the launch writes it
#       CopiesAtStart (a list): how many copies of the step's reports were there when a driver step started
#       JSFX are found by their add name ("JS:<path under Effects>") in the configuration directory's Effects
#       OwnModules: the module list of a learn launch shows only the binaries of the plugins that launch added (otherwise
#       every launch shows every configured binary)
#       PdcUnread: no latency is read (pdc= stays empty), in the learn step and in device, savereopen and transport
#       LearnNoResult (n): the n-th learn launch since Set-FakeReaper writes no result
#       LearnNoModules (n): the module list of the n-th learn launch since Set-FakeReaper shows no binary at all
#       Params (REAPER name -> a list of @{ Name; Value }): the parameters of that plugin in order, with their defaults;
#       names may repeat (it sets and reads the first of a name, as the driver does) and it saves them as index=value
#       pairs. Without it a plugin takes any name it is given and saves name=value pairs. HostParams: those plugins end
#       with REAPER's Bypass, Wet and Delta; nparams counts the parameters an instance has. Idents are REAPER 7.82's:
#       <index>:<1000 + index> for a plugin's own parameters, <index>:bypass, <index>:wet, <index>:delta for REAPER's.
#       A parameter listing (job entries with list, sweep) is reported like the driver does, after the save. Faults, in
#       the first listed entry: ListInexact (the name of parameter 1 is not exact), ListDrop (no display of parameter
#       1), ListError (the listing stops with an error), ListCountEnd (the count at the end is one more), SweepNoAdd
#       (the first instance to sweep is not added), SweepOtherName (the instances to sweep show another name),
#       SweepOtherBinary (their fx_ident names another binary), SweepError (the sweep stops with an error after its
#       first instance)
#       Renders: the renders since Set-FakeReaper are counted (-renderproject and the driver's render step alike).
#       RenderSkip (n): the n-th render writes no file. TailLost: no item plays past the end of its file, as if REAPER
#       ignored the longer item. Drift = @{ Plugin (bundle or JSFX ident); Step; Frame }: after that plugin's FX the
#       sample at Frame of every channel is set to Step x the number of this render, so two renders differ there only
#   An item longer than its file plays the file again from its start (REAPER's "loop source"), unless it has LOOP 0;
#   then the rest of the item is silent
#   Get-FakeReaperLauncher / Get-FakeModuleSampler   script blocks for the context (Launcher, ModuleSampler)
#   ConvertFrom-FakeLua <text>                        reads a job file written by ConvertTo-HarnessLuaTable

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '../src/Wav.psm1') -ErrorAction Stop

if (-not ('FakeMix' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class FakeMix {
    // dst += src scaled per channel (interleaved; gl for channel 1, gr for channel 2 of a stereo signal)
    public static void Add(double[] dst, double[] src, double gl, double gr, int channels) {
        int n = Math.Min(dst.Length, src.Length);
        if (channels == 2) { for (int i = 0; i + 1 < n; i += 2) { dst[i] += gl * src[i]; dst[i + 1] += gr * src[i + 1]; } }
        else { for (int i = 0; i < n; i++) dst[i] += gl * src[i]; }
    }
    // The first frames of a source on a track of ch channels, cut, or longer: looped (the source again from its start)
    // or padded with zeros; a source of one channel plays on every channel (what REAPER does with it is in the
    // validation record, not here)
    public static double[] Fit(double[] src, int srcCh, long frames, int ch, bool loop) {
        var y = new double[frames * ch];
        long have = src.Length / srcCh;
        if (have == 0) return y;
        for (long f = 0; f < frames && (loop || f < have); f++) for (int c = 0; c < ch; c++) y[f * ch + c] = src[(f % have) * srcCh + Math.Min(c, srcCh - 1)];
        return y;
    }
    public static double[] Scale(double[] x, double g) { var y = new double[x.Length]; for (int i = 0; i < x.Length; i++) y[i] = g * x[i]; return y; }
    public static double[] Delay(double[] x, int frames, int channels) {
        var y = new double[x.Length];
        int off = frames * channels;
        for (int i = off; i < x.Length; i++) y[i] = x[i - off];
        return y;
    }
}
'@
}

$script:Spec = $null
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Src = ''
$script:At = 0
$script:DelayParam = 'Delay (samples)'
$script:ReportParam = 'Report delay as PDC'

$script:LearnLaunches = 0
$script:JobBinaries = $null # the binaries the learn step of the last launch added (OwnModules)
$script:Renders = 0
function Set-FakeReaper([hashtable]$Spec) { $script:Spec = $Spec; $script:LearnLaunches = 0; $script:Renders = 0 }
function Get-FakeReaperLauncher { { param($psi) Invoke-FakeLaunch $psi } }
function Get-FakeModuleSampler {
    {
        param($proc)
        if ($null -ne $script:JobBinaries -and $script:Spec['LearnNoModules'] -eq $script:LearnLaunches) { return , @() }
        ($script:Spec['OwnModules'] -and $null -ne $script:JobBinaries) ? @($script:JobBinaries) : @(Get-FakeBinaries)
    }
}
function Get-FakeBinary([string]$Bundle) { [IO.Path]::Combine($script:Spec.CfgDir, 'plugins', $Bundle, 'Contents', 'x86_64-win', $Bundle) }
function Get-FakePdcText($fx) { $script:Spec['PdcUnread'] ? '' : "$(Get-FakePdc $fx)" }

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

# ---- plugins ----
# The name REAPER shows for a JSFX under the configuration's Effects directory ('' when it is not there).
function Get-FakeJsName([string]$ident) {
    $file = Join-Path (Join-Path $script:Spec.CfgDir 'Effects') $ident
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    $desc = @([IO.File]::ReadAllLines($file) | Where-Object { $_ -match '^desc:' } | Select-Object -First 1)
    $desc.Count ? ('JS: ' + ($desc[0] -replace '^desc:', '').Trim()) : ''
}

# A plugin by the name it is added by: @{ Kind; Name; Bundle; Cid; Ident } or $null when REAPER would not find it.
function Find-FakePlugin([string]$AddName) {
    if ($AddName.StartsWith('JS:')) {
        $ident = $AddName.Substring(3)
        $name = Get-FakeJsName $ident
        if (-not $name) { return $null }
        return [pscustomobject]@{ Kind = 'JS'; Name = $name; Bundle = ''; Cid = ''; Ident = $ident }
    }
    $p = $script:Spec.Plugins[$AddName]
    if (-not $p) { return $null }
    [pscustomobject]@{ Kind = 'VST'; Name = $AddName; Bundle = $p.Bundle; Cid = $p.Cid; Ident = [IO.Path]::Combine($script:Spec.CfgDir, 'plugins', $p.Bundle, 'Contents', 'x86_64-win', $p.Bundle) + "<1234567890{$($p.Cid)" }
}

function New-FakeParams([string]$kind) {
    $p = [ordered]@{}
    if ($kind -eq 'JS') { $p[$script:DelayParam] = 0.0; $p[$script:ReportParam] = 1.0 }
    $p
}

# The parameters of a plugin of Spec.Params by its REAPER name, in order (Name, Value, Ident); $null for any other plugin
function New-FakeParamList([string]$reaperName) {
    $given = $script:Spec['Params']
    if (-not $given -or -not $given.Contains($reaperName)) { return $null }
    $out = [Collections.Generic.List[object]]::new()
    foreach ($e in @($given[$reaperName])) { $out.Add([pscustomobject]@{ Name = [string]$e['Name']; Value = [double]$e['Value']; Ident = "$($out.Count):$(1000 + $out.Count)" }) }
    if ($script:Spec['HostParams']) { foreach ($h in 'Bypass', 'Wet', 'Delta') { $out.Add([pscustomobject]@{ Name = $h; Value = (($h -ceq 'Wet') ? 1.0 : 0.0); Ident = "$($out.Count):$($h.ToLowerInvariant())" }) } }
    , $out
}

# Every parameter of an instance, in order (Name, Value, Ident as above); without a list, those it was given
function Get-FakeParamRows($fx) {
    if ($fx.List) { return , @($fx.List) }
    $pos = 0
    , @(foreach ($pn in @($fx.Params.get_Keys())) { [pscustomobject]@{ Name = [string]$pn; Value = [double]$fx.Params[$pn]; Ident = "$($pos):$(1000 + $pos)" }; $pos++ })
}

# The index of the first parameter of that name, as findParam finds it; -1 when there is none
function Find-FakeParamIndex($fx, [string]$name) {
    $rows = Get-FakeParamRows $fx
    for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Name -ceq $name) { return $i } }
    -1
}

# The value of the first parameter of that name ($null when there is none)
function Get-FakeParamValue($fx, [string]$name) {
    if (-not $fx.List) { return $fx.Params.Contains($name) ? [double]$fx.Params[$name] : $null }
    $i = Find-FakeParamIndex $fx $name
    ($i -ge 0) ? $fx.List[$i].Value : $null
}

# Sets the first parameter of that name; a plugin without a list takes any name. False when it has no such parameter.
function Set-FakeParamValue($fx, [string]$name, [double]$Value) {
    if (-not $fx.List) { $fx.Params[$name] = $Value; return $true }
    $i = Find-FakeParamIndex $fx $name
    if ($i -lt 0) { return $false }
    $fx.List[$i].Value = $Value
    $true
}

# The state a plugin saves: its parameters as name=value; pairs, or index=value; for a plugin of Spec.Params (always
# written the same way).
function ConvertTo-FakeState($fx) {
    $pairs = $fx.List ? (-join @(for ($i = 0; $i -lt $fx.List.Count; $i++) { "$i=$(([double]$fx.List[$i].Value).ToString('R', $script:Inv));" })) :
        (-join @($fx.Params.get_Keys() | ForEach-Object { "$_=$(([double]$fx.Params[$_]).ToString('R', $script:Inv));" }))
    'FAKESTATE ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pairs))
}

function Get-FakeDisplay($fx, [string]$name, [double]$Value) {
    if ($fx.Kind -eq 'JS' -and $name -ceq $script:DelayParam) { return ($Value * 8192).ToString('0.0', $script:Inv) }
    if ($fx.Kind -eq 'JS' -and $name -ceq $script:ReportParam) { return ($Value -ge 0.5) ? 'On' : 'Off' }
    $Value.ToString('0.00', $script:Inv)
}

function Get-FakeDelay($fx) { ($fx.Kind -eq 'JS' -and $fx.Params.Contains($script:DelayParam)) ? [int][Math]::Round([double]$fx.Params[$script:DelayParam] * 8192) : 0 }
function Test-FakeReportsPdc($fx) { -not $fx.Params.Contains($script:ReportParam) -or [double]$fx.Params[$script:ReportParam] -ge 0.5 }
function Get-FakePdc($fx) { (Test-FakeReportsPdc $fx) ? (Get-FakeDelay $fx) : 0 }

# ---- projects ----
# Tracks of a project: Name, Volume, Pan, Mute, Isbus, Sel, MainSend, Recv (Src, Mode, Vol), Source (wav path or ''), Length
# (of its item, $null without one), Loop (of its item: on unless LOOP 0),
# Fx (Kind, Name, Ident, Header, Bypassed, Params name -> value).
function Read-FakeProject([string]$Text) {
    $tracks = [Collections.Generic.List[object]]::new()
    $cur = $null
    $bypassNext = $false
    $fx = $null
    $fxLevel = 0
    foreach ($raw in ($Text -split '\r?\n')) {
        $s = $raw.Trim()
        if ($fx) {
            if ($s.StartsWith('<')) { $fxLevel++ } elseif ($s -eq '>') { $fxLevel--; if ($fxLevel -eq 0) { $fx = $null }; continue }
            if ($s -match '^FAKESTATE (\S*)$') {
                $state = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
                foreach ($pair in ($state -split ';' | Where-Object { $_ })) {
                    $kv = $pair -split '=', 2
                    $pos = 0
                    if ($fx.List -and [int]::TryParse($kv[0], [ref]$pos) -and $pos -lt $fx.List.Count) { $fx.List[$pos].Value = [double]::Parse($kv[1], $script:Inv) }
                    else { $null = Set-FakeParamValue $fx $kv[0] ([double]::Parse($kv[1], $script:Inv)) }
                }
            }
            continue
        }
        if ($s -eq '<TRACK') {
            $cur = [pscustomobject]@{ Name = ''; Volume = 1.0; Pan = 0.0; Mute = $false; Isbus = '0 0'; Sel = $false; MainSend = $true; Recv = [Collections.Generic.List[object]]::new(); Source = ''; Length = $null; Loop = $true; Fx = [Collections.Generic.List[object]]::new() }
            $tracks.Add($cur); continue
        }
        if ($null -eq $cur) { continue }
        if ($s -match '^NAME (.*)$' -and -not $cur.Name) { $cur.Name = $Matches[1].Trim('"') }
        elseif ($s -match '^VOLPAN (\S+) (\S+)') { $cur.Volume = [double]::Parse($Matches[1], $script:Inv); $cur.Pan = [double]::Parse($Matches[2], $script:Inv) }
        elseif ($s -match '^MUTESOLO (\d)') { $cur.Mute = $Matches[1] -ne '0' }
        elseif ($s -match '^ISBUS (\S+ \S+)') { $cur.Isbus = $Matches[1] }
        elseif ($s -match '^SEL (\d)') { $cur.Sel = $Matches[1] -ne '0' }
        elseif ($s -match '^MAINSEND (\d)') { $cur.MainSend = $Matches[1] -ne '0' }
        elseif ($s -match '^AUXRECV (\d+) (\d+) (\S+)') { $cur.Recv.Add([pscustomobject]@{ Src = [int]$Matches[1]; Mode = [int]$Matches[2]; Vol = [double]::Parse($Matches[3], $script:Inv) }) }
        elseif ($s -match '^FILE "(.*)"$') { $cur.Source = $Matches[1] }
        elseif ($s -match '^LENGTH (\S+)$') { $cur.Length = [double]::Parse($Matches[1], $script:Inv) }
        elseif ($s -match '^LOOP (\d)$') { $cur.Loop = $Matches[1] -ne '0' }
        elseif ($s -match '^BYPASS (\d)') { $bypassNext = $Matches[1] -ne '0' }
        elseif ($s -match '^<(VST|JS) (.*)$') {
            $kind = $Matches[1]
            $tok = @([regex]::Matches($Matches[2], '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') })
            $fx = [pscustomobject]@{ Kind = $kind; Name = ''; Ident = ''; Header = $s; Bypassed = $bypassNext; Params = (New-FakeParams $kind); List = $null }
            if ($kind -eq 'JS') { $fx.Ident = $tok[0]; $fx.Name = Get-FakeJsName $tok[0] } else { $fx.Name = $tok[0] }
            $fx.List = New-FakeParamList $fx.Name
            $cur.Fx.Add($fx)
            $fxLevel = 1
        }
    }
    , $tracks.ToArray()
}

function Format-FakeFxBlock($fx) { @($fx.Header, (ConvertTo-FakeState $fx), '>') }

# The mix of a project. Returns @{ Master; Stems (track name -> samples); Rate; Channels }.
function Get-FakeMix([string]$Text) {
    $tracks = Read-FakeProject $Text
    $rate = [int][regex]::Match($Text, '(?m)^\s*SAMPLERATE (\d+)').Groups[1].Value
    $channels = [int][regex]::Match($Text, '(?m)^\s*RENDER_FMT \d+ (\d+)').Groups[1].Value
    $n = $tracks.Count
    $parent = [int[]]::new($n)
    $stack = [Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $n; $i++) {
        $parent[$i] = $stack.Count ? $stack[$stack.Count - 1] : -1
        $flag = $tracks[$i].Isbus -split ' '
        if ($flag[0] -eq '1') { $stack.Add($i) }
        elseif ($flag[0] -eq '2') { for ($k = 0; $k -lt -[int]$flag[1]; $k++) { $stack.RemoveAt($stack.Count - 1) } }
    }
    # An item plays floor(LENGTH x rate) frames of its file: a length that falls short of the last frame loses it
    $faults = $script:Spec ?? @{}
    $sources = @{}
    $len = 0
    foreach ($t in $tracks) {
        if (-not $t.Source) { continue }
        $key = "$($t.Source)|$($t.Length)|$($t.Loop)"
        if ($sources.ContainsKey($key)) { continue }
        $w = Read-HarnessWav $t.Source
        $frames = ($null -ne $t.Length) ? [long][Math]::Floor($t.Length * $rate) : $w.Frames
        if ($faults['TailLost']) { $frames = [Math]::Min($frames, $w.Frames) }
        $sources[$key] = [FakeMix]::Fit($w.Samples, $w.Channels, $frames, $channels, [bool]$t.Loop)
        $len = [Math]::Max($len, $sources[$key].Length)
    }
    $drift = $faults['Drift']
    $memo = @{}
    $busy = @{}
    $get = $null
    # Taps of track i: pre (its input, before the FX), post (after the FX), out (after volume, pan and mute)
    $get = {
        param([int]$i, [string]$tap)
        if (-not $memo.ContainsKey($i)) {
            if ($busy.ContainsKey($i)) { throw "routing loop through track $i" }
            $busy[$i] = $true
            $t = $tracks[$i]
            $pre = [double[]]::new($len)
            if ($t.Source) { [FakeMix]::Add($pre, $sources["$($t.Source)|$($t.Length)|$($t.Loop)"], 1.0, 1.0, $channels) }
            for ($j = 0; $j -lt $n; $j++) { if ($parent[$j] -eq $i -and $tracks[$j].MainSend) { [FakeMix]::Add($pre, (& $get $j 'out'), 1.0, 1.0, $channels) } }
            foreach ($r in $t.Recv) {
                if ($tracks[$r.Src].Mute) { continue } # mute silences every send of the track, pre-fader and pre-FX too
                $from = switch ($r.Mode) { 0 { 'out' } 1 { 'pre' } 3 { 'post' } default { throw "send mode $($r.Mode)" } }
                [FakeMix]::Add($pre, (& $get $r.Src $from), $r.Vol, $r.Vol, $channels)
            }
            $post = $pre
            foreach ($fx in $t.Fx) {
                if ($fx.Bypassed) { continue }
                $trim = Get-FakeParamValue $fx 'Trim'
                if ($null -ne $trim) { $post = [FakeMix]::Scale($post, 2 * $trim) }
                if (-not (Test-FakeReportsPdc $fx) -and (Get-FakeDelay $fx)) { $post = [FakeMix]::Delay($post, (Get-FakeDelay $fx), $channels) }
                $drifts = $drift -and (($fx.Kind -eq 'JS') ? ($fx.Ident -ceq $drift.Plugin) : ($script:Spec.Plugins.ContainsKey($fx.Name) -and $script:Spec.Plugins[$fx.Name].Bundle -ceq $drift.Plugin))
                if ($drifts) {
                    # A copy: $post may still be $pre, the tap before the FX
                    $post = [double[]]$post.Clone()
                    for ($ci = 0; $ci -lt $channels; $ci++) { $slot = [long]$drift.Frame * $channels + $ci; if ($slot -lt $post.Length) { $post[$slot] = $script:Renders * [double]$drift.Step } }
                }
            }
            $out = [double[]]::new($len)
            if (-not $t.Mute) {
                $gl = $t.Volume * (($channels -eq 2 -and $t.Pan -gt 0) ? (1 - $t.Pan) : 1.0)
                $gr = $t.Volume * (($channels -eq 2 -and $t.Pan -lt 0) ? (1 + $t.Pan) : 1.0)
                [FakeMix]::Add($out, $post, $gl, $gr, $channels)
            }
            $memo[$i] = @{ pre = $pre; post = $post; out = $out }
            $busy.Remove($i)
        }
        , $memo[$i][$tap]
    }
    $master = [double[]]::new($len)
    $stems = @{}
    for ($i = 0; $i -lt $n; $i++) {
        if ($parent[$i] -lt 0 -and $tracks[$i].MainSend) { [FakeMix]::Add($master, (& $get $i 'out'), 1.0, 1.0, $channels) }
        if ($tracks[$i].Sel) { $stems[$tracks[$i].Name] = & $get $i 'out' }
    }
    [pscustomobject]@{ Master = $master; Stems = $stems; Rate = $rate; Channels = $channels }
}

function Invoke-FakeRender([string]$Project) {
    $script:Renders++
    if (($script:Spec ?? @{})['RenderSkip'] -eq $script:Renders) { return } # REAPER rendered nothing
    $projectText = [IO.File]::ReadAllText($Project)
    $dir = [regex]::Match($projectText, '(?m)^\s*RENDER_FILE "(.*)"').Groups[1].Value
    $pattern = [regex]::Match($projectText, '(?m)^\s*RENDER_PATTERN "(.*)"').Groups[1].Value
    $mix = Get-FakeMix $projectText
    $write = { param([string]$Leaf, [double[]]$Samples) Write-HarnessWav -Path (Join-Path $dir "$Leaf.wav") -Rate $mix.Rate -Channels $mix.Channels -Format float32 -Samples $Samples }
    if ($projectText -notmatch '(?m)^\s*RENDER_STEMS 1') { & $write $pattern $mix.Master; return }
    & $write ($pattern.Replace('$track', 'Master')) $mix.Master
    foreach ($name in $mix.Stems.get_Keys()) { & $write ($pattern.Replace('$track', $name)) $mix.Stems[$name] }
}

# ---- driver steps ----
function Format-Fake([double]$Value) { $Value.ToString('0.000000000', $script:Inv) }

function Add-FakeTracks($Lines, [string]$Prefix, [string]$Project, $Reads) {
    $tracks = Read-FakeProject ([IO.File]::ReadAllText($Project))
    $Lines.Add("${Prefix}tracks=$($tracks.Count)")
    for ($t = 0; $t -lt $tracks.Count; $t++) {
        $Lines.Add("${Prefix}t${t}_name=$($tracks[$t].Name)")
        $Lines.Add("${Prefix}t${t}_fx_count=$($tracks[$t].Fx.Count)")
        $chain = 0
        for ($f = 0; $f -lt $tracks[$t].Fx.Count; $f++) {
            $x = $tracks[$t].Fx[$f]
            $q = "${Prefix}t${t}_fx${f}_"
            $pdc = Get-FakePdc $x
            if (-not $x.Bypassed) { $chain += $pdc }
            foreach ($kv in @("name=$($x.Name)", "pdc=$(Get-FakePdcText $x)", "chain_pdc_actual=$chain", "bypassed=$($x.Bypassed.ToString().ToLowerInvariant())", 'offline=false')) { $Lines.Add($q + $kv) }
        }
    }
    $k = 0
    foreach ($r in @($Reads)) {
        $k++
        $q = "${Prefix}t$([int]$r['t'])_fx$([int]$r['f'])_"
        $fx = $tracks[[int]$r['t']].Fx[[int]$r['f']]
        $v = Get-FakeParamValue $fx $r['name']
        if ($null -ne $v) { $Lines.Add("${q}param$k=$(Format-Fake $v)"); $Lines.Add("${q}display$k=$(Get-FakeDisplay $fx $r['name'] $v)") }
        else { $Lines.Add("${q}param$k=missing") }
    }
}

function Get-FakeIniValue([string]$IniKey, [string]$Default = '') {
    $ini = [IO.File]::ReadAllText((Join-Path $script:Spec.CfgDir 'reaper.ini'))
    $m = [regex]::Match($ini, "(?m)^$IniKey=(.*?)\r?$")
    $m.Success ? $m.Groups[1].Value : $Default
}

# The learn step: the tracks of the job's project (empty, or holding a state block), the plugin added by name
# to an empty one, parameters set on top; the saved project holds every plugin's state as it saves it.
function Invoke-FakeLearn($job, $report) {
    $given = @(($job['project'] -and (Test-Path -LiteralPath $job['project'])) ? (Read-FakeProject ([IO.File]::ReadAllText($job['project']))) : @())
    $rpp = [Text.StringBuilder]::new("<REAPER_PROJECT 0.1 `"7.0/win64`" 0 0`n")
    $n = 0
    $made = [Collections.Generic.List[object]]::new() # each entry and the instance it added, for a listing after the save
    foreach ($e in @($job['fx'])) {
        $n++
        $key = "fx${n}_"
        $fx = $null
        if ($e['preloaded']) {
            if ($n -le $given.Count -and $given[$n - 1].Fx.Count -eq 1) {
                $fx = $given[$n - 1].Fx[0]
                $found = ($fx.Kind -eq 'VST') ? (Find-FakePlugin $fx.Name) : $null
                if (-not $found) { $fx = $null } else { $fx | Add-Member -NotePropertyName Plugin -NotePropertyValue $found }
            }
        } else {
            $p = Find-FakePlugin $e['name']
            if ($p) {
                $header = ($p.Kind -eq 'JS') ? "<JS $($p.Ident) `"`"" : "<VST `"$($p.Name)`" `"$($p.Bundle)`" 0 `"`" 1234567890{$($p.Cid)} `"`""
                $fx = [pscustomobject]@{ Kind = $p.Kind; Name = $p.Name; Ident = $p.Ident; Header = $header; Bypassed = $false; Params = (New-FakeParams $p.Kind); List = (New-FakeParamList $p.Name); Plugin = $p }
            }
        }
        # Like the driver: track n of the opened project keeps its name; a track it has to add is named learn-<n>
        $trackName = ($n -le $given.Count -and $given[$n - 1].Name) ? $given[$n - 1].Name : "learn-$n"
        $null = $rpp.Append("  <TRACK`n    NAME `"$trackName`"`n")
        if (-not $fx) { $report.Add("${key}idx=-1"); $null = $rpp.Append("  >`n"); continue }
        $ident = ($fx.Kind -eq 'JS') ? $fx.Ident : $fx.Plugin.Ident
        if ($fx.Kind -ne 'JS') { $script:JobBinaries = @($script:JobBinaries) + (Get-FakeBinary $fx.Plugin.Bundle) }
        $k = 0
        $made.Add([pscustomobject]@{ N = $n; Fx = $fx })
        $readBack = foreach ($prm in @($e['params'])) {
            $k++
            if (-not (Set-FakeParamValue $fx $prm['name'] ([double]$prm['value']))) { "${key}p$k=missing"; continue }
            "${key}p$k=$(Format-Fake $prm['value'])"; "${key}p${k}_display=$(Get-FakeDisplay $fx $prm['name'] ([double]$prm['value']))"
        }
        foreach ($kv in @('idx=0', "name=$($fx.Name)", "ident=$ident", "pdc=$(Get-FakePdcText $fx)", 'offline=false', "nparams=$((Get-FakeParamRows $fx).Count)")) { $report.Add($key + $kv) }
        foreach ($line in @($readBack)) { $report.Add($line) }
        $null = $rpp.Append("    <FXCHAIN`n      BYPASS 0 0 0`n")
        foreach ($line in (Format-FakeFxBlock $fx)) { $null = $rpp.Append("      $line`n") }
        $null = $rpp.Append("    >`n  >`n")
    }
    $null = $rpp.Append(">`n")
    [IO.File]::WriteAllText($job['saveAs'], $rpp.ToString())
    $report.Add('saved=true')
    Add-FakeListing $job $report $made
}

# A parameter listing after the save, as the driver reports it: every listed entry's parameters, then the sweeps of an
# entry on a fresh instance per name. The faults of Spec act on the first listed entry.
function Add-FakeListing($job, $report, $made) {
    $faulty = $true
    foreach ($m in $made) {
        $e = @($job['fx'])[$m.N - 1]
        $fx = $m.Fx
        $key = "fx$($m.N)_"
        if (-not $e['list']) { continue }
        $fault = { param([string]$Opt) $faulty -and $script:Spec[$Opt] }
        $rows = Get-FakeParamRows $fx
        $report.Add("${key}lcount=$($rows.Count)")
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $q = "${key}l${i}_"
            $report.Add("${q}name=$($rows[$i].Name)")
            $report.Add("${q}exact=$(((& $fault 'ListInexact') -and $i -eq 1) ? 'false' : 'true')")
            $report.Add("${q}value=$(Format-Fake $rows[$i].Value)")
            if (-not ((& $fault 'ListDrop') -and $i -eq 1)) { $report.Add("${q}display=$(Get-FakeDisplay $fx $rows[$i].Name $rows[$i].Value)") }
            $report.Add("${q}dexact=true")
            $report.Add("${q}ident=$($rows[$i].Ident)")
        }
        if (& $fault 'ListError') { $report.Add("${key}lerror=driver.lua:1: listing stopped") }
        else { $report.Add("${key}lcount_end=$($rows.Count + ((& $fault 'ListCountEnd') ? 1 : 0))") }
        $sweep = $e['sweep']
        $swept = @(if ($sweep) { $sweep['names'] })
        for ($s = 1; $s -le $swept.Count; $s++) {
            $q = "${key}s${s}_"
            if ((& $fault 'SweepNoAdd') -and $s -eq 1) { $report.Add("${q}idx=-1"); continue }
            $report.Add("${q}idx=0")
            $report.Add("${q}name=$($fx.Name)$((& $fault 'SweepOtherName') ? ' 2' : '')")
            $ident = ($fx.Kind -eq 'JS') ? $fx.Ident : $fx.Plugin.Ident
            if (& $fault 'SweepOtherBinary') { $ident = [IO.Path]::Combine($env:COMMONPROGRAMFILES, 'VST3', 'Other.vst3') + $ident.Substring($ident.LastIndexOf('<')) }
            $report.Add("${q}ident=$ident")
            $fresh = [pscustomobject]@{ Kind = $fx.Kind; Name = $fx.Name; Params = (New-FakeParams $fx.Kind); List = (New-FakeParamList $fx.Name) }
            $pos = Find-FakeParamIndex $fresh $swept[$s - 1]
            if ($pos -lt 0) { $report.Add("${q}index=missing"); continue }
            $report.Add("${q}index=$pos")
            $sweepVals = @($sweep['values'])
            for ($k = 1; $k -le $sweepVals.Count; $k++) {
                $null = Set-FakeParamValue $fresh $swept[$s - 1] ([double]$sweepVals[$k - 1])
                $back = Get-FakeParamValue $fresh $swept[$s - 1]
                foreach ($kv in "v$k=$(Format-Fake $back)", "v${k}_display=$(Get-FakeDisplay $fresh $swept[$s - 1] $back)", "v${k}_dexact=true") { $report.Add($q + $kv) }
            }
            if (& $fault 'SweepError') { $report.Add("${key}serror=driver.lua:1: sweep stopped"); break }
        }
        $faulty = $false
    }
}

# Plugin reports, as the driver copies them (job.reports: path, copy, period, and for the stand-in fields and pid): every
# declared field grows by Spec.ReportDelta[field] (default 10) in each state's window and by 1 between windows; the pid
# field is the stand-in process (written once it is started). Spec.ReportMode: none (the plugin writes nothing), otherpid
# (another process wrote it), text (not JSON), string (the first field is a string), toolarge, stale, busy.
$script:PendingCopies = [Collections.Generic.List[object]]::new()
$script:ReportValue = @{}
function Write-FakeReports($job, $report, [int]$Reading) {
    $mode = [string]$script:Spec['ReportMode']
    $reps = @($job['reports'])
    for ($j = 0; $j -lt $reps.Count; $j++) {
        $r = $reps[$j]
        $status = @{ none = 'missing'; toolarge = 'toolarge'; stale = 'stale'; busy = 'busy' }[$mode]
        if ($status) { $report.Add("rep$($j + 1)_$Reading=$status"); continue }
        $doc = [ordered]@{}
        foreach ($f in @($r['fields'])) {
            $key = "$j/$f"
            $step = ($Reading % 2) ? 1 : ($script:Spec['ReportDelta'] -and $script:Spec['ReportDelta'].Contains($f) ? $script:Spec['ReportDelta'][$f] : 10)
            $script:ReportValue[$key] = (($Reading -eq 1) ? 0 : $script:ReportValue[$key]) + $step
            $doc[$f] = $script:ReportValue[$key]
        }
        if ($mode -ceq 'string') { $first = @($r['fields'])[0]; $doc[$first] = "$($doc[$first])" }
        $body = ($mode -ceq 'text') ? 'not json' : ($doc | ConvertTo-Json -Compress)
        if ($r['pid'] -and $mode -cne 'text') { $body = $body.Substring(0, $body.Length - 1) + ",`"$($r['pid'])`":__PID__}" }
        $file = "$($r['copy'])$Reading.json"
        [IO.File]::WriteAllText($file, $body)
        $script:PendingCopies.Add([pscustomobject]@{ File = $file; Shift = ($mode -ceq 'otherpid') ? 1 : 0 })
        $report.Add("rep$($j + 1)_$Reading=$(($Reading % 2) ? 'quiet' : 'changed')")
    }
}

# The transport step, as REAPER 7.82 was measured to behave (docs/CONFIG.md): the chain of the tested track is run when
# the track is armed, or when "Run FX when stopped" (bit 0 of runallonstop in the private ini) is on and the transport
# is not paused; input monitoring is in effect when the track is armed and monitoring is on, or auto while not playing;
# only then does the chain get the feed (Data\reaper-harness\feed.wav of the configuration directory, when the job has
# a feed and the file is there), which plays in every armed state. A window of n samples is n / block blocks, rounded
# up, on the clock as well. Spec.FeedIdle = a state name: the feed plays nothing in that state; '*': it never runs.
# Spec.Unread = a state name: no clean reading of that state's counts, so it reports none of them, like the driver.
# A window held open (windows.hold) is held 3 ms longer; Spec.HoldShort: 1000 ms shorter (at least 0); Spec.HoldMissing:
# no hold time is reported; Spec.HoldAlways: one is reported for a window without hold too, as by a driver that sent it.
function Invoke-FakeTransport($job, $report) {
    $sr = [int](Get-FakeIniValue 'dummy_srate')
    $block = [int](Get-FakeIniValue 'dummy_blocksize')
    $ras = [int](Get-FakeIniValue 'runallonstop' '1')
    # Spec.RecordFor = a scenario id: a file appears in the record directory of that scenario, as if it had recorded
    if ($script:Spec['RecordFor'] -and (Split-Path -Leaf ([string]$job['recordDir'])) -ceq "$($script:Spec['RecordFor'])-record") {
        $null = New-Item -ItemType Directory -Force -Path $job['recordDir']
        [IO.File]::WriteAllText((Join-Path $job['recordDir'] 'take.wav'), 'recorded')
    }
    foreach ($kv in @("dev_bsize=$block", "dev_srate=$sr", 'dev_mode=dummy', "cfg_workrender=$(Get-FakeIniValue 'workrender' '17')", "cfg_runallonstop=$ras", "cfg_vstfullstate=$($script:Spec['VstFullStateReads'] ?? (Get-FakeIniValue 'vstfullstate' '49989'))", 'cfg_runafterstop=4000')) { $report.Add($kv) }
    Add-FakeTracks $report '' $job['project'] $job['reads']
    # Spec.RecordPathFails: the record path does not read back, and like the driver the step stops before it arms anything
    if ($script:Spec['RecordPathFails']) { $report.Add('record_path=failed'); $report.Add('error=the record path of the project could not be set to the work directory; nothing was armed'); return }
    $report.Add('record_path=ok')
    $tracks = Read-FakeProject ([IO.File]::ReadAllText($job['project']))
    $probe = Find-FakePlugin $job['probe']
    $ident = $probe ? $probe.Ident : ''
    foreach ($kv in @("clock_ident=$ident", "probe_idx=$($script:Spec['ProbeIdx'] ?? 0)", "probe_ident=$ident", "probe_fx_count=$($tracks[[int]$job['track']].Fx.Count + 1)")) { $report.Add($kv) }
    $nch = 0; $rate = 0
    if ($job.Contains('feed')) {
        $feed = Find-FakePlugin $job['feed']
        $report.Add("feed_ident=$($feed ? $feed.Ident : '')")
        $file = Join-Path $script:Spec.CfgDir 'Data\reaper-harness\feed.wav'
        if (Test-Path -LiteralPath $file) { $w = Read-HarnessWav $file; $nch = $w.Channels; $rate = $w.Rate }
    }
    $mode = $job.Contains('feedMode') ? [int]$job['feedMode'] : 2
    $report.Add("settle=$($job.Contains('settle') ? [int]$job['settle'] : [int](4.5 * $sr))")
    $n = 0
    $armed = $false
    foreach ($st in @($job['states'])) {
        $n++
        $arm = [int]$st['arm']; $mon = [int]$st['monitor']; $t = [string]$st['transport']
        $armed = $armed -or $arm -eq 1
        $blocks = [int][Math]::Ceiling([double]$st['samples'] / $block)
        $b = ($arm -eq 1 -or (($ras -band 1) -and $t -cne 'pause')) ? $blocks : 0
        $monitoring = $arm -eq 1 -and ($mon -eq 1 -or ($mon -eq 2 -and $t -cne 'play'))
        $idle = $script:Spec['FeedIdle'] -ceq '*' -or $script:Spec['FeedIdle'] -ceq [string]$st['name']
        $fedBlocks = ($arm -eq 1 -and $nch -gt 0 -and -not $idle) ? $blocks : 0
        $sig = ($monitoring -and $fedBlocks -gt 0) ? $b : 0
        $same = ($mode -eq 1 -or ($mode -eq 2 -and $nch -eq 1)) ? $sig : 0
        $values = [ordered]@{
            settled = $blocks * $block; clock = $blocks; clock_samples = $blocks * $block; blocks = $b; samples = $b * $block; silent = $b - $sig; signal = $sig
            left = $sig; right = ($mode -eq 0) ? 0 : $sig; equal = $same; fed = $fedBlocks; fed_samples = $fedBlocks * $block; playstate = @{ stop = 0; play = 1; pause = 2 }[$t]; arm = $arm; monitor = $mon; monitoring = [int]$monitoring
        }
        if ($script:Spec['Unread'] -ceq [string]$st['name']) { foreach ($k in 'clock', 'clock_samples', 'blocks', 'samples', 'silent', 'signal', 'left', 'right', 'equal', 'fed', 'fed_samples') { $values.Remove($k) } }
        foreach ($e in $values.GetEnumerator()) { $report.Add("st${n}_$($e.Key)=$($e.Value)") }
        # Windows open and close every time, but Spec.WindowsFail times fewer
        if ($st.Contains('windows')) { foreach ($w in 'win_open', 'win_closed') { $report.Add("st${n}_$w=$([int]$st['windows']['count'] - [int]($script:Spec['WindowsFail'] ?? 0))") } }
        if ($st.Contains('windows') -and ($st['windows'].Contains('hold') -or $script:Spec['HoldAlways']) -and -not $script:Spec['HoldMissing']) {
            $hold = $st['windows'].Contains('hold') ? [int]$st['windows']['hold'] : 0
            $report.Add("st${n}_win_held=$($script:Spec['HoldShort'] ? [Math]::Max(0, $hold - 1000) : $hold + 3)")
        }
        Write-FakeReports $job $report (2 * $n - 1)
        Write-FakeReports $job $report (2 * $n)
    }
    $report.Add("states_done=$n")
    $handle = (-not $armed -or $script:Spec['FeedIdle'] -ceq '*') ? -2 : (($nch -gt 0) ? 1 : -1)
    foreach ($kv in @("feed_handle=$handle", "feed_channels=$nch", "feed_rate=$rate")) { $report.Add($kv) }
}

# Runs one step; returns how the stand-in process should behave: quick, linger (alive long enough to be sampled) or
# hang.
function Invoke-FakeStep([string]$JobFile) {
    $job = ConvertFrom-FakeLua ([IO.File]::ReadAllText($JobFile))
    if ($script:Spec.ContainsKey('CopiesAtStart') -and $job.Contains('reports')) {
        $script:Spec.CopiesAtStart.Add(@(foreach ($r in @($job['reports'])) { Get-ChildItem -LiteralPath (Split-Path $r['copy']) -Filter "$(Split-Path $r['copy'] -Leaf)*.json" -File }).Count)
    }
    $report = [Collections.Generic.List[string]]::new()
    $behave = 'quick'
    switch ($job['step']) {
        'learn' {
            $behave = 'linger'
            $script:JobBinaries = @()
            $script:LearnLaunches++
            if ($script:Spec['LearnNoResult'] -eq $script:LearnLaunches) { return $behave }
            Invoke-FakeLearn $job $report
        }
        'device' {
            foreach ($kv in @("dev_bsize=$(Get-FakeIniValue 'dummy_blocksize')", "dev_srate=$(Get-FakeIniValue 'dummy_srate')", 'dev_mode=dummy', 'project_srate=0', "cfg_workrender=$(Get-FakeIniValue 'workrender' '17')", "cfg_runallonstop=$(Get-FakeIniValue 'runallonstop' '1')", "cfg_vstfullstate=$(Get-FakeIniValue 'vstfullstate' '49989')")) { $report.Add($kv) }
            Add-FakeTracks $report '' $job['project'] $job['reads']
            # Like the driver, saved says the file is there, whoever wrote it. Spec.SaveFails: this launch cannot save.
            if ($job.Contains('saveAs')) {
                if (-not $script:Spec['SaveFails']) { Copy-Item -LiteralPath $job['project'] -Destination $job['saveAs'] }
                $report.Add("saved=$((Test-Path -LiteralPath $job['saveAs']) ? 'true' : 'false')")
            }
        }
        'savereopen' {
            Add-FakeTracks $report 'before_' $job['project'] $job['reads']
            Copy-Item -LiteralPath $job['project'] -Destination $job['saveAs']
            $cycles = $job.Contains('cycles') ? [int]$job['cycles'] : 1
            for ($i = 1; $i -le $cycles; $i++) { Add-FakeTracks $report "after${i}_" $job['saveAs'] $job['reads'] }
            $report.Add('saved=true')
        }
        'instances' {
            $behave = 'linger'
            $report.Add("cycles_done=$([int]$job['cycles'])"); $report.Add('tracks_left=0')
            foreach ($mark in $job['warmMark'], $job['loopMark']) { [IO.File]::WriteAllText($mark, '1') }
        }
        'transport' { Invoke-FakeTransport $job $report }
        'render' {
            foreach ($kv in @("dev_bsize=$(Get-FakeIniValue 'dummy_blocksize')", "dev_srate=$(Get-FakeIniValue 'dummy_srate')", "cfg_workrender=$(Get-FakeIniValue 'workrender' '17')", "cfg_runallonstop=$(Get-FakeIniValue 'runallonstop' '1')", "cfg_vstfullstate=$($script:Spec['VstFullStateReads'] ?? (Get-FakeIniValue 'vstfullstate' '49989'))")) { $report.Add($kv) }
            Write-FakeReports $job $report 1
            if (-not $script:Spec['RenderFails']) { Invoke-FakeRender $job['project'] }
            Write-FakeReports $job $report 2
        }
        'hang' { return 'hang' }
        default { $report.Add("error=no such step: $($job['step'])") }
    }
    [IO.File]::WriteAllText($job['result'], (($report + 'done=1') -join "`n") + "`n")
    $behave
}

# What a plugin with probe variables writes into its directory (Spec.Probe; see the header). Returns the text of
# final.json when the stand-in process is to write it last, else ''.
function Write-FakeProbe($psi) {
    $p = $script:Spec['Probe']
    if (-not $p) { return '' }
    $outDir = [string]$psi.Environment[$p.Out]
    if (-not $outDir) { return '' }
    $scriptFile = [string]$psi.Environment[$p.Script]
    $final = ($scriptFile -and (Test-Path -LiteralPath $scriptFile -PathType Leaf)) ?
        ('{{"script":"{0}","bytes":{1}}}' -f [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($scriptFile))).ToLowerInvariant(), ([IO.FileInfo]::new($scriptFile).Length)) : '{"script":null,"bytes":null}'
    $fault = [string]$p['Fault']
    $put = { param([string]$Leaf, [string]$Text) [IO.File]::WriteAllText((Join-Path $outDir $Leaf), $Text) }
    $sized = { param([string]$Leaf, [long]$Length) $fs = [IO.File]::Create((Join-Path $outDir $Leaf)); try { $fs.SetLength($Length) } finally { $fs.Dispose() } }
    switch ($fault) {
        'None' { return '' }
        'Many' { for ($i = 1; $i -le 33; $i++) { & $put ('m-{0:d2}.json' -f $i) '{}' }; return '' }
        'Total' { for ($i = 1; $i -le 5; $i++) { & $sized "t$i.bin" 4194304 }; return '' }
        'TmpOnly' { & $put 'final.json.4242.tmp' '{}'; return '' }
    }
    for ($i = 1; $i -le [int]($p['Steps'] ?? 0); $i++) { & $put ('step-{0:d3}.json' -f $i) "{""step"":$i}" }
    switch ($fault) {
        'Subdir' { $null = New-Item -ItemType Directory -Path (Join-Path $outDir 'sub'); & $put 'sub\x.json' '{}' }
        'Junction' { $null = New-Item -ItemType Junction -Path (Join-Path $outDir 'link') -Target $p.Outside }
        'BadName' { & $put 'bad name!.json' '{}'; & $put '.hidden' '{}' }
        'Big' { & $sized 'big.bin' 4194305 }
        'Tmp' { & $put 'final.json.4242.tmp' '{}' }
    }
    if ($p['LateFinal']) { return $final }
    & $put 'final.json' $final
    if ($fault -ceq 'DirLink') {
        # The plugin replaces its directory by a junction to another one that holds files of its own
        Remove-Item -LiteralPath $outDir -Recurse -Force
        $null = New-Item -ItemType Junction -Path $outDir -Target $p.Outside
    }
    ''
}

function Invoke-FakeLaunch($psi) {
    $given = @($psi.ArgumentList)
    $script:JobBinaries = $null
    $script:Spec.Seen.Add($given -join ' ')
    if ($script:Spec['EnvName']) {
        $told = [string]$psi.Environment[$script:Spec.EnvName]
        $script:Spec.EnvSeen.Add($told)
        if ($told -and $script:Spec.ContainsKey('FileAtStart')) { $script:Spec.FileAtStart.Add((Test-Path -LiteralPath $told)); [IO.File]::WriteAllText($told, '{}') }
    }
    if ($script:Spec['EnvNames']) {
        $logged = [ordered]@{ args = ($given -join ' ') }
        foreach ($n in $script:Spec.EnvNames) { $logged[$n] = [string]$psi.Environment[$n] }
        $script:Spec.EnvLog.Add($logged)
    }
    $behave = 'quick'
    $renderAt = [array]::IndexOf($given, '-renderproject')
    $jobPath = [string]$psi.Environment['REAPER_HARNESS_JOB']
    $rendering = $renderAt -ge 0 -or ($jobPath -and (ConvertFrom-FakeLua ([IO.File]::ReadAllText($jobPath)))['step'] -ceq 'render')
    if ($renderAt -ge 0) { Invoke-FakeRender $given[$renderAt + 1] }
    elseif ($jobPath) { $behave = Invoke-FakeStep $jobPath }
    $late = $rendering ? (Write-FakeProbe $psi) : ''
    $psi.FileName = $script:Spec.Pwsh
    $psi.ArgumentList.Clear()
    $command = @{ quick = 'exit 0'; linger = 'Start-Sleep -Milliseconds 1500'; hang = 'Start-Sleep -Seconds 60' }[$behave]
    if ($late) {
        # The stand-in writes final.json (and a .tmp) last, right before it exits: the text and the place travel in its environment
        $psi.Environment['FAKE_PROBE_DIR'] = [string]$psi.Environment[$script:Spec.Probe.Out]
        $psi.Environment['FAKE_PROBE_FINAL'] = $late
        $command = 'Start-Sleep -Milliseconds 400; ' + ($script:Spec.Probe['LateTmp'] ? "[IO.File]::WriteAllText((Join-Path `$env:FAKE_PROBE_DIR 'final.json.4242.tmp'), '{}'); " : '') + "[IO.File]::WriteAllText((Join-Path `$env:FAKE_PROBE_DIR 'final.json'), `$env:FAKE_PROBE_FINAL); exit 0"
    }
    foreach ($part in '-NoProfile', '-NonInteractive', '-Command', $command) { $psi.ArgumentList.Add($part) }
    $proc = [Diagnostics.Process]::Start($psi)
    foreach ($c in $script:PendingCopies) { [IO.File]::WriteAllText($c.File, [IO.File]::ReadAllText($c.File).Replace('__PID__', "$($proc.Id + $c.Shift)")) }
    $script:PendingCopies.Clear()
    $proc
}

Export-ModuleMember -Function Set-FakeReaper, Get-FakeReaperLauncher, Get-FakeModuleSampler, ConvertFrom-FakeLua, Get-FakeMix

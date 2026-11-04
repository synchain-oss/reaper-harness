# SPDX-License-Identifier: MIT
#
# The transport kind: a sequence of transport, arm and monitoring states of one track, each observed for a number of
# device samples (not of wall-clock time: REAPER's main thread can stall for a second while the audio runs on).
#   Read-HarnessFeeds -Config <config>
#       every transport scenario whose feed names a WAV file: the path follows the rules of extension paths, the file
#       must hold samples, its rate must be the scenario's (nothing is resampled), 1 or 2 channels, and 2 for
#       "different"; a channel the feed plays must not have a peak of 0 (a silent feed would let every "silent"
#       expectation pass without evidence). Problems are usage errors: REAPER is never started. Fills in File, Sha256
#       (first 12 hex digits) and FileChannels of the feed.
#   Get-HarnessTransportJob      the job of the driver's transport step (pure)
#   Get-HarnessTransportTimeout  the time the driver's transport step may take (pure)
#   Read-HarnessTransportRow     the numbers the driver reported for one state (pure)
#   Test-HarnessTransportSetup   the probes, the clock, the feed and the record directory the driver set up (pure)
#   Test-HarnessTransportState   one state against what it expects (pure)
# How the driver observes (lua/driver.lua, step transport): jsfx/harness-block-probe.jsfx first in the FX chain of the
# tested track counts the blocks that chain is run with and what they carry (it sees what the plugin under test gets);
# a second one on a track of the harness's own, armed with recording disabled and no output, counts the device's
# blocks: an armed track is run in every state. jsfx/harness-feed.jsfx in the input FX chain of the tested track
# plays the feed, so what reaches the chain has come through arming and input monitoring like a hardware input.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Extensions.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Plugins.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Wav.psm1') -ErrorAction Stop

$script:MonitorCode = @{ off = 0; on = 1; auto = 2 } # I_RECMON
$script:PlayCode = @{ stop = 0; play = 1; pause = 2 } # GetPlayState: 1 playing, 2 paused; 4 (recording) never
$script:FeedMode = @{ left = 0; same = 1; different = 2 } # the Channels parameter of the feed JSFX
$script:Fields = 'clock', 'clock_samples', 'blocks', 'samples', 'silent', 'signal', 'left', 'right', 'equal', 'fed', 'fed_samples', 'playstate', 'arm', 'monitor', 'monitoring'

function Read-HarnessFeeds {
    param([Parameter(Mandatory)]$Config)
    $bad = [Collections.Generic.List[string]]::new()
    foreach ($s in @($Config.Scenarios) + @($Config.Negative)) {
        if ($s.kind -cne 'transport' -or $null -eq $s.feed -or -not $s.feed.Wav) { continue }
        $rel = $s.feed.Wav
        try { $file = Resolve-HarnessExtensionPath -ConfigDir $Config.ConfigDir -Relative $rel -What 'feed' }
        catch { $bad.Add("$($s.id): $($_.Exception.Message -replace '^USAGE: ', '')"); continue }
        try { $w = Read-HarnessWav $file } catch { $bad.Add("$($s.id): feed $rel cannot be read: $($_.Exception.Message -replace '^WAV: ', '')"); continue }
        if ($w.Frames -lt 1) { $bad.Add("$($s.id): feed $rel holds no samples"); continue }
        if ($w.Rate -ne $s.sr) { $bad.Add("$($s.id): feed $rel is at $($w.Rate) Hz and the scenario runs at $($s.sr) Hz: nothing is resampled") }
        if ($w.Channels -notin 1, 2) { $bad.Add("$($s.id): feed $rel has $($w.Channels) channels: 1 or 2 are accepted") }
        elseif ($w.Channels -eq 1 -and $s.feed.Channels -ceq 'different') { $bad.Add("$($s.id): feed $rel has one channel: channels ""different"" needs two") }
        else {
            # "left" and "same" play the first channel of the file, "different" both
            $peaks = [HarnessWav]::ChannelPeaks($w)
            $played = ($s.feed.Channels -ceq 'different') ? $w.Channels : 1
            for ($ch = 0; $ch -lt $played; $ch++) { if ($peaks[$ch] -eq 0) { $bad.Add("$($s.id): feed $rel has a peak of 0 on channel $($ch + 1): a silent feed proves nothing") } }
        }
        $s.feed.File = $file
        $s.feed.Sha256 = (Get-HarnessSha256 $file).Substring(0, 12)
        $s.feed.FileChannels = $w.Channels
    }
    if ($bad.Count) { Stop-Usage ("feeds: $($bad.Count) problem(s): " + ($bad -join '; ')) }
}

# Tools: tool JSFX name -> the name to add it by. The tested track is found by name in the layout; tracks are written
# in layout order, so its index in the project is its index there.
function Get-HarnessTransportJob {
    param([Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][hashtable]$Tools, [Parameter(Mandatory)][string]$RecordDir)
    $index = -1
    for ($i = 0; $i -lt $Layout.Tracks.Count; $i++) { if ($Layout.Tracks[$i].Name -ceq $Scenario.track) { $index = $i; break } }
    if ($index -lt 0) { throw "the tested track '$($Scenario.track)' is not in the layout" }
    $job = @{
        track = $index; sr = $Scenario.sr; probe = $Tools['harness-block-probe']; recordDir = $RecordDir
        states = @(foreach ($st in $Scenario.states) { @{ name = $st.Name; transport = $st.Transport; arm = ($st.Arm ? 1 : 0); monitor = $script:MonitorCode[$st.Monitor]; samples = $st.Samples } })
    }
    if ($null -ne $Scenario.settleSamples) { $job.settle = $Scenario.settleSamples }
    if ($null -ne $Scenario.feed) { $job.feed = $Tools['harness-feed']; $job.feedMode = $script:FeedMode[$Scenario.feed.Channels] }
    $job
}

function ConvertTo-TransportNumber([AllowNull()][string]$Text) {
    $v = 0.0
    if ($null -eq $Text -or -not [double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $null }
    if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return $null }
    [long][Math]::Round($v)
}

# What the Lua step may take: luaTimeoutSec, the settle times and windows three times over (the main thread can stall
# while the audio runs on) and the 10 s each of a state's two waits gives itself in the driver, so that the driver's own
# "the device clock stopped" comes before the watchdog. Without settleSamples it counts 5 s a state, REAPER's default.
function Get-HarnessTransportTimeout {
    param([Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)][double]$LuaTimeoutSec)
    $seconds = 0.0
    foreach ($st in $Scenario.states) { $seconds += ($st.Samples + (($null -ne $Scenario.settleSamples) ? $Scenario.settleSamples : 5 * $Scenario.sr)) / $Scenario.sr }
    $LuaTimeoutSec + 3 * $seconds + 20 * @($Scenario.states).Count
}

# The driver's numbers for state N (1-based): $null when the state was not observed (a field missing or unreadable).
function Read-HarnessTransportRow([Parameter(Mandatory)][hashtable]$Facts, [int]$N) {
    $values = [ordered]@{}
    foreach ($f in $script:Fields) {
        $v = ConvertTo-TransportNumber $Facts["st${N}_$f"]
        if ($null -eq $v) { return $null }
        $values[$f] = $v
    }
    [pscustomobject]$values
}

# Problems with the setup, any of which leaves no evidence (INCOMPLETE): the probes and the feed are not the harness's
# own files, the probe is not first in the chain, a recording could have gone elsewhere, not every state was observed,
# or the feed could not play its source. Idents: tool JSFX name -> fx_ident of its private copy.
function Test-HarnessTransportSetup {
    param([Parameter(Mandatory)][hashtable]$Facts, [Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)][hashtable]$Idents, [int]$FxCount)
    $bad = [Collections.Generic.List[string]]::new()
    $probe = $Idents['harness-block-probe']
    if ($Facts['probe_ident'] -cne $probe -or (ConvertTo-TransportNumber $Facts['probe_idx']) -ne 0) { $bad.Add("the block probe of the tested track is not the harness's own first in its chain (idx $($Facts['probe_idx']), '$($Facts['probe_ident'])')") }
    if ((ConvertTo-TransportNumber $Facts['probe_fx_count']) -ne $FxCount + 1) { $bad.Add("the tested track has $($Facts['probe_fx_count']) FX with the probe, expected $($FxCount + 1)") }
    if ($Facts['clock_ident'] -cne $probe) { $bad.Add("the clock track has no block probe of the harness ('$($Facts['clock_ident'])')") }
    if ($Facts['record_path'] -cne 'ok') { $bad.Add('the record path of the project could not be set to the work directory') }
    if ((ConvertTo-TransportNumber $Facts['states_done']) -ne @($Scenario.states).Count) { $bad.Add("$($Facts['states_done']) of $(@($Scenario.states).Count) states were observed") }
    if ($null -ne $Scenario.feed) {
        if ($Facts['feed_ident'] -cne $Idents['harness-feed']) { $bad.Add("the feed of the input chain is not the harness's own ('$($Facts['feed_ident'])')") }
        $h = ConvertTo-TransportNumber $Facts['feed_handle']
        # -2: the feed never ran, which is right only when no state arms the track (the input chain runs on armed tracks)
        if ($null -eq $h) { $bad.Add('the feed reported nothing') }
        elseif ($h -eq -1 -or $h -lt -2) { $bad.Add('the feed could not open its source') }
        elseif ($h -eq -2 -and @($Scenario.states | Where-Object { $_.Arm }).Count) { $bad.Add('the feed never ran although a state arms the track') }
        elseif ($h -ge 0) {
            if ((ConvertTo-TransportNumber $Facts['feed_channels']) -ne $Scenario.feed.FileChannels) { $bad.Add("the feed opened a source with $($Facts['feed_channels']) channels, expected $($Scenario.feed.FileChannels)") }
            if ((ConvertTo-TransportNumber $Facts['feed_rate']) -ne $Scenario.sr) { $bad.Add("the feed opened a source at $($Facts['feed_rate']) Hz, expected $($Scenario.sr)") }
        }
    }
    , $bad.ToArray()
}

function Format-TransportPlay([long]$Code) { switch ($Code) { 0 { 'stop' } 1 { 'play' } 2 { 'pause' } default { "$Code" } } }

# One state (State: from the configuration) against the driver's numbers (Row, $null when not observed). Status:
# PASS / FAIL / INCOMPLETE, or recorded for a state without expectations. INCOMPLETE: the device did not run the whole
# window, REAPER does not report the transport, arm and monitoring the state asked for (the numbers would describe
# another state), or the scenario has a feed (HasFeed), the track is armed and the feed played nothing in the window (a
# silent input would prove nothing). Line: what was seen, then "; failed: ..." or "; no evidence: ...".
function Test-HarnessTransportState {
    param([Parameter(Mandatory)]$State, [AllowNull()]$Row, [switch]$HasFeed)
    if ($null -eq $Row) { return [pscustomobject]@{ Status = 'INCOMPLETE'; Line = "$($State.Name): not observed"; Problems = @('not observed') } }
    $r = $Row
    $line = '{0}: blocks={1}/{2} silent={3} signal={4} left={5} right={6} same={7} transport={8} monitoring={9}' -f $State.Name, $r.blocks, $r.clock, $r.silent, $r.signal, $r.left, $r.right, $r.equal, (Format-TransportPlay $r.playstate), $r.monitoring
    $gap = [Collections.Generic.List[string]]::new()
    if ($r.clock_samples -lt $State.Samples) { $gap.Add("the device ran $($r.clock_samples) of $($State.Samples) samples") }
    if ($r.playstate -ne $script:PlayCode[$State.Transport]) { $gap.Add("the transport reads $(Format-TransportPlay $r.playstate), expected $($State.Transport)") }
    if ($r.arm -ne [int]$State.Arm) { $gap.Add("arm reads $($r.arm), expected $([int]$State.Arm)") }
    if ($r.monitor -ne $script:MonitorCode[$State.Monitor]) { $gap.Add("monitoring mode reads $($r.monitor), expected $($script:MonitorCode[$State.Monitor])") }
    if ($HasFeed -and $State.Arm -and $r.fed -eq 0) { $gap.Add('the feed played no block in the window although the track is armed') }
    if ($gap.Count) { return [pscustomobject]@{ Status = 'INCOMPLETE'; Line = "$line; no evidence: $($gap -join '; ')"; Problems = $gap.ToArray() } }
    $x = $State.Expect
    if ($null -eq $x) { return [pscustomobject]@{ Status = 'recorded'; Line = $line; Problems = @() } }
    $bad = [Collections.Generic.List[string]]::new()
    $none = 'not called, so it has no input'
    if ($true -eq $x.Called -and $r.blocks -eq 0) { $bad.Add("not called (0 blocks while the device ran $($r.clock))") }
    if ($false -eq $x.Called -and $r.blocks -ne 0) { $bad.Add("called in $($r.blocks) blocks") }
    if ($null -ne $x.Input -or $null -ne $x.Channels) {
        if ($r.blocks -eq 0) { if ($true -ne $x.Called) { $bad.Add($none) } }
        else {
            if ('silent' -ceq $x.Input -and $r.signal -ne 0) { $bad.Add("signal in $($r.signal) of $($r.blocks) blocks") }
            if ('signal' -ceq $x.Input -and $r.silent -ne 0) { $bad.Add("silent in $($r.silent) of $($r.blocks) blocks") }
            switch ($x.Channels) {
                'left' {
                    if ($r.signal -eq 0) { $bad.Add('no signal') }
                    elseif ($r.left -ne $r.signal) { $bad.Add("no signal on the left in $($r.signal - $r.left) of $($r.signal) blocks with signal") }
                    if ($r.right -ne 0) { $bad.Add("signal on the right in $($r.right) of $($r.blocks) blocks") }
                }
                'same' {
                    if ($r.signal -eq 0) { $bad.Add('no signal') }
                    elseif ($r.equal -ne $r.signal) { $bad.Add("left and right differ in $($r.signal - $r.equal) of $($r.signal) blocks with signal") }
                }
                'different' {
                    if ($r.signal -eq 0) { $bad.Add('no signal') }
                    else {
                        if ($r.left -ne $r.signal) { $bad.Add("no signal on the left in $($r.signal - $r.left) of $($r.signal) blocks with signal") }
                        if ($r.right -ne $r.signal) { $bad.Add("no signal on the right in $($r.signal - $r.right) of $($r.signal) blocks with signal") }
                        if ($r.equal -ne 0) { $bad.Add("left and right are the same in $($r.equal) of $($r.signal) blocks with signal") }
                    }
                }
            }
        }
    }
    if ($null -ne $x.Monitoring -and $r.monitoring -ne [int][bool]$x.Monitoring) { $bad.Add("monitoring in effect reads $($r.monitoring), expected $([int][bool]$x.Monitoring)") }
    if ($bad.Count) { return [pscustomobject]@{ Status = 'FAIL'; Line = "$line; failed: $($bad -join '; ')"; Problems = $bad.ToArray() } }
    [pscustomobject]@{ Status = 'PASS'; Line = $line; Problems = @() }
}

Export-ModuleMember -Function Read-HarnessFeeds, Get-HarnessTransportJob, Get-HarnessTransportTimeout, Read-HarnessTransportRow, Test-HarnessTransportSetup, Test-HarnessTransportState

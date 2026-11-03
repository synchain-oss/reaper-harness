# SPDX-License-Identifier: MIT
#
# Running scenarios: make the signal, write the project, start REAPER to render or to run a Lua driver step, judge.
# Every scenario returns @{ Status; Detail [; Facts] }: PASS / FAIL / INCOMPLETE. INCOMPLETE means no conclusion
# could be reached (timeout, killed, stuck dialog, no output file, lock not available, skip marker appeared) and is
# never treated as PASS. FAIL is only for a criterion that was checked and not met.
# Built-in kinds (handlers in $script:Handlers):
#   render      render a layout and compare with the same layout without FX (dry), the same render again (repeat)
#               or another variant (layout / block / mode / bypass)
#   device      device block size and sample rate read back; every FX reports the configured latency
#   savereopen  FX state survives save and reopen; the reopened project renders bit-identical to the original
#   instances   add and remove instances many times; handle and memory growth stay below the limits
#   hang        a driver step that never finishes (only for the built-in watchdog negative cases)
# Extension kinds are registered through Extensions.psm1 and receive the same context and the API in Ctx.Api.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Host.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Locks.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Rpp.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Wav.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -ErrorAction Stop

function New-HarnessOutcome([string]$Status, [string]$Detail = '', $Facts = $null) {
    $o = [ordered]@{ Status = $Status; Detail = $Detail }
    if ($null -ne $Facts) { $o.Facts = $Facts }
    [pscustomobject]$o
}

# Paths in any text that leaves the machine (result json, console) are masked, from a drive letter, \\ or // on. A path
# can hold spaces, apostrophes, semicolons and commas (a user name, for one), so none of those ends it; what does is a
# character no Windows file name can have (a double quote, < > | ? *, a colon that is not followed by a slash) or the end
# of the line. So whatever follows an unquoted path on its line goes with it: a sentence cut short is the price, a user
# name in a result file is not. A path in single quotes, the way .NET and PowerShell write them, ends at the last single
# quote of that stretch that a blank, a punctuation mark or the end of the text follows, and the sentence around it stays.
# Any other single quote is an apostrophe in a name: with no closing quote the path is masked like an unquoted one.
$script:PathStart = '(?:[A-Za-z]:[\\/]|\\\\|//)'
$script:PathBody = '(?:[^"<>|?*:\r\n]|:[\\/])*'
$script:QuoteEnd = '(?=[\s.,;:)\]]|$)'
function Hide-HarnessPaths([AllowNull()][string]$Text) {
    if (-not $Text) { return '' }
    $Text -replace "'$($script:PathStart)$($script:PathBody)'$($script:QuoteEnd)", "'<path>'" -replace "$($script:PathStart)$($script:PathBody)", '<path>'
}

# The same for the facts of an outcome, which an extension fills with whatever it likes: every string at any depth, keys
# too. Numbers and booleans stay as they are. Anything nested deeper than any real result is cut off, not written out.
function Hide-HarnessFacts([AllowNull()]$Value, [int]$Depth = 0) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return Hide-HarnessPaths $Value }
    if ($Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Depth -ge 32) { return '<too deep>' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $props = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $props[$p.Name] = $p.Value }
        return Hide-HarnessFacts $props $Depth
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $masked = [ordered]@{}
        foreach ($k in @($Value.get_Keys())) { $masked[(Hide-HarnessPaths ([string]$k))] = Hide-HarnessFacts $Value[$k] ($Depth + 1) }
        return $masked
    }
    if ($Value -is [System.Collections.IEnumerable]) { return , @(foreach ($item in $Value) { , (Hide-HarnessFacts $item ($Depth + 1)) }) }
    Hide-HarnessPaths ([string]$Value)
}

# The context of one round. Installed: rows from Install-HarnessPlugins. Locks: full mutex names (fixed order).
function New-HarnessContext {
    param(
        [Parameter(Mandatory)][string]$ReaperExe, [Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string]$Driver,
        [Parameter(Mandatory)]$Config, [object[]]$Installed = @(), [Parameter(Mandatory)][string[]]$Locks, [string[]]$SkipMarkers = @(),
        [string[]]$LuaExtensions = @(), [hashtable]$Kinds = @{}
    )
    $byId = @{}
    foreach ($row in $Installed) { $byId[$row.Id] = $row }
    @{
        Exe = $ReaperExe; Work = $WorkDir; Driver = $Driver; Config = $Config; Limits = $Config.Limits; Signal = $Config.Signal
        Locks = $Locks; LockWaitSec = [double]$Config.Limits.lockWaitSec; SkipMarkers = $SkipMarkers; LuaExtensions = $LuaExtensions; Kinds = $Kinds
        Installed = $byId; Blocks = @{}; Names = @{}; Launches = 0; LaunchLog = [Collections.Generic.List[object]]::new()
        Signals = @{}; Refs = @{}; Files = [Collections.Generic.List[string]]::new()
        Started = [Collections.Generic.List[object]]::new() # every process started: Pid, StartUtc
        StillRunning = $null # set when the watchdog could not end a process: Pid, Label, Lock
        Launcher = $null; ModuleSampler = $null; Stopper = $null # self-test only
        Api = $null # filled in below
    }
}

# Private ini: Dummy audio device (silent), sample rate and block size; no save prompt after recording.
function Set-HarnessAudioConfig([int]$Sr, [int]$Block) {
    $null = Set-HarnessIniValue -Section audioconfig -Key mode -Value 4
    $null = Set-HarnessIniValue -Section audioconfig -Key dummy_srate -Value $Sr
    $null = Set-HarnessIniValue -Section audioconfig -Key dummy_blocksize -Value $Block
    $null = Set-HarnessIniValue -Section REAPER -Key promptendrec -Value 0
}

function Get-HarnessSkipMarkerHit([string[]]$Markers) { @($Markers | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) | Select-Object -First 1 }

# The locks of a launch whose process could not be ended stay held until this process exits, when the kernel takes them
# back. Referenced from here so that no garbage collection closes them earlier, which would end them just the same.
$script:KeptLocks = [Collections.Generic.List[object]]::new()

# Starts REAPER once while holding every lock of the set. Lock not available -> Status LockBusy; a skip marker that
# appeared since the preflight -> Status SkipMarker; an earlier process of this context that could not be ended ->
# Status Blocked. In all three REAPER is not started (the caller records INCOMPLETE; the harness never runs REAPER
# without its locks, nor next to a REAPER it could not end). The launch that reports StillRunning keeps its locks: its
# window may still be on the desktop, and the next start of any harness has to wait for it.
function Invoke-HarnessLaunch {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][hashtable]$HostArgs, [string]$Label = '')
    $none = { param($s) [pscustomobject]@{ Status = $s; ExitCode = $null; Seconds = 0; Pid = 0; Modal = $null; Dismissed = @(); Windows = @(); Marks = @{}; SampleLost = @(); Modules = @{}; ModuleScans = 0; PluginModules = @(); StillRunning = $false } }
    if ($Ctx.StillRunning) { return & $none 'Blocked' }
    if (Get-HarnessSkipMarkerHit $Ctx.SkipMarkers) { return & $none 'SkipMarker' }
    $lock = Enter-HarnessLocks -Names $Ctx.Locks -TimeoutSeconds $Ctx.LockWaitSec
    if (-not $lock) { return & $none 'LockBusy' }
    $keepLock = $false
    try {
        # The marker is checked again while holding the locks: someone may have started a manual test meanwhile
        if (Get-HarnessSkipMarkerHit $Ctx.SkipMarkers) { return & $none 'SkipMarker' }
        $Ctx.Launches++
        $Watch = @($Ctx.Installed.get_Values() | ForEach-Object { $_.BinaryLeaf })
        $extra = @{ WatchModules = $Watch; StartedList = $Ctx.Started }
        if ($Ctx.Launcher) { $extra.Launcher = $Ctx.Launcher }
        if ($Ctx.ModuleSampler) { $extra.ModuleSampler = $Ctx.ModuleSampler }
        if ($Ctx.Stopper) { $extra.Stopper = $Ctx.Stopper }
        $Run = Invoke-HarnessHost -ReaperExe $Ctx.Exe -WorkDir $Ctx.Work -Lock $lock @HostArgs @extra
        $Ctx.LaunchLog.Add([pscustomobject]@{ Label = $Label; Status = $Run.Status; Modules = $Run.Modules; PluginModules = @($Run.PluginModules) })
        if ($Run.StillRunning) {
            $keepLock = $true
            $script:KeptLocks.Add($lock)
            $Ctx.StillRunning = [pscustomobject]@{ Pid = $Run.Pid; Label = $Label; Lock = $lock }
        }
        $Run
    } finally { if (-not $keepLock) { Exit-HarnessLocks $lock } }
}

# Did this launch end normally; if not, how it ended (the start of these texts is what the negative cases match, so a
# process that is still there has a text of its own: the watchdog did not do its job).
function Get-HarnessHostFailure($Run) {
    if ($Run.PSObject.Properties['StillRunning'] -and $Run.StillRunning) { return "the watchdog could not end process $($Run.Pid) ($($Run.Status) after $($Run.Seconds) s): the GUI locks stay held and REAPER is not started again" }
    switch ($Run.Status) {
        'Blocked' { return 'an earlier REAPER of this round could not be ended; REAPER was not started' }
        'LockBusy' { return 'the GUI locks were not available in time; REAPER was not started' }
        'SkipMarker' { return 'a skip marker appeared; REAPER was not started' }
        'Timeout' { return "timed out after $($Run.Seconds) s and was ended" }
        'Killed' { return "killed at the deadline ($($Run.Seconds) s)" }
        'Modal' { return "stuck on dialog $($Run.Modal) (seen: $($Run.Windows -join ', ')), ended" }
        'Error' { return "watching the process failed and it was ended: $($Run.Error)" }
    }
    if ($Run.ExitCode -ne 0) { return "exit code $($Run.ExitCode)" }
    $null
}

function Get-HarnessSignal {
    param([Parameter(Mandatory)]$Ctx, [int]$Sr, [int]$Channels, [int]$OffsetSamples = 0)
    $key = "$Sr-$Channels-$OffsetSamples"
    if (-not $Ctx.Signals.ContainsKey($key)) {
        $path = Join-Path $Ctx.Work "signal-$key.wav"
        $s = $Ctx.Signal
        New-HarnessSignalFile -Path $path -Rate $Sr -Channels $Channels -Seconds $s.Seconds -Seed $s.Seed -NoiseDb $s.NoiseDb -SineHz $s.SineHz -SineDb $s.SineDb -OffsetSamples $OffsetSamples
        $Ctx.Files.Add($path)
        $Ctx.Signals[$key] = $path
    }
    $Ctx.Signals[$key]
}

function Get-HarnessLayout($Ctx, [string]$Id) { ($Id -ceq '@dry') ? (Get-HarnessDryLayout) : $Ctx.Config.Layouts[$Id] }

# Writes the project and sets the audio configuration; returns the project path and the path of its render.
function New-HarnessRun {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Layout, [int]$Sr = 48000, [int]$Block = 512,
          [string]$Mode = 'offline', [int]$Channels = 2, [string[]]$Bypass = @(), [double]$VolumeScale = 1.0, [int]$OffsetSamples = 0, [switch]$NoFx,
          [hashtable]$Blocks = $null)
    $Project = Join-Path $Ctx.Work "$Name.rpp"
    $Wav = Join-Path $Ctx.Work "$Name.wav"
    if (Test-Path -LiteralPath $Wav) { Remove-Item -LiteralPath $Wav }
    $Text = New-HarnessProjectText -Layout $Layout -Blocks ($Blocks ?? $Ctx.Blocks) -SourceWav (Get-HarnessSignal $Ctx $Sr $Channels $OffsetSamples) -RenderDir $Ctx.Work -RenderName $Name `
        -SampleRate $Sr -Channels $Channels -Mode $Mode -Bypass $Bypass -Seconds $Ctx.Signal.Seconds -VolumeScale $VolumeScale -NoFx:$NoFx
    Write-HarnessText -Path $Project -Text $Text
    Set-HarnessAudioConfig -Sr $Sr -Block $Block
    $Ctx.Files.Add($Project); $Ctx.Files.Add($Wav)
    [pscustomobject]@{ Project = $Project; Wav = $Wav }
}

function Invoke-HarnessRender($Ctx, [string]$Project, [string]$Wav, [string]$Label = 'render') {
    $Run = Invoke-HarnessLaunch -Ctx $Ctx -Label $Label -HostArgs @{ ReaperArgs = @('-renderproject', $Project); TimeoutSec = [double]$Ctx.Limits.renderTimeoutSec }
    $why = Get-HarnessHostFailure $Run
    if (-not $why -and -not (Test-Path -LiteralPath $Wav)) { $why = 'the render produced no file' }
    [pscustomobject]@{ Run = $Run; Why = $why }
}

# Runs one driver step. Job: extra fields for the job file. Watch: label -> mark file (process counters are sampled
# when it appears). Result: the key=value lines as a hashtable.
function Invoke-HarnessLuaStep {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Step, [hashtable]$Job = @{}, [hashtable]$Watch = @{},
          [double]$TimeoutSec = 0, [double]$KillAfterSec = 0)
    $jobFile = Join-Path $Ctx.Work "$Name.job.lua"
    $resultFile = Join-Path $Ctx.Work "$Name.result"
    foreach ($f in @($resultFile) + @($Watch.get_Values())) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f } }
    $Ctx.Files.Add($jobFile); $Ctx.Files.Add($resultFile); foreach ($f in $Watch.get_Values()) { $Ctx.Files.Add($f) }
    $full = @{ step = $Step; result = $resultFile; extensions = @($Ctx.LuaExtensions) }
    foreach ($k in $Job.get_Keys()) { $full[$k] = $Job[$k] }
    Write-HarnessText -Path $jobFile -Text (ConvertTo-HarnessLuaTable $full)
    $Run = Invoke-HarnessLaunch -Ctx $Ctx -Label $Step -HostArgs @{
        ReaperArgs = @($Ctx.Driver); Environment = @{ REAPER_HARNESS_JOB = $jobFile }; WatchFiles = $Watch
        TimeoutSec = ($TimeoutSec -gt 0 ? $TimeoutSec : [double]$Ctx.Limits.luaTimeoutSec); KillAfterSec = $KillAfterSec
    }
    $report = @{}
    if (Test-Path -LiteralPath $resultFile) {
        foreach ($line in [IO.File]::ReadAllLines($resultFile)) { $i = $line.IndexOf('='); if ($i -gt 0) { $report[$line.Substring(0, $i)] = $line.Substring($i + 1) } }
    }
    $why = Get-HarnessHostFailure $Run
    if (-not $why -and $report['done'] -ne '1') { $why = 'the Lua driver wrote no result' }
    if (-not $why -and $report.ContainsKey('error')) { $why = "the Lua driver reported an error: $($report['error'])" }
    [pscustomobject]@{ Run = $Run; Result = $report; Why = $why }
}

# Parameter reads for the driver (device, savereopen): one entry per configured parameter of every FX of the layout,
# with what is expected back.
function Get-HarnessParamReads($Layout) {
    $Reads = [Collections.Generic.List[object]]::new()
    for ($t = 0; $t -lt $Layout.Tracks.Count; $t++) {
        $fxs = @($Layout.Tracks[$t].Fx)
        for ($f = 0; $f -lt $fxs.Count; $f++) {
            foreach ($pn in $fxs[$f].Params.get_Keys()) {
                $p = $fxs[$f].Params[$pn]
                $Reads.Add([pscustomobject]@{ t = $t; f = $f; name = $pn; Normalized = $p.Normalized; Display = $p.Display })
            }
        }
    }
    , $Reads.ToArray()
}

function ConvertTo-LuaReads([object[]]$Reads) { , @($Reads | ForEach-Object { @{ t = $_.t; f = $_.f; name = $_.name } }) }

# Pure function: is a parameter read back what was asked for? With a display text, the text decides; otherwise the
# normalized value must be within 1e-6 (REAPER reports 9 decimals).
function Test-HarnessParamValue([string]$Read, [string]$Display, $Want) {
    if ($Read -ceq 'missing' -or -not $Read) { return 'no such parameter' }
    if ($null -ne $Want.Display) { return ($Display -ceq [string]$Want.Display) ? $null : "shows '$Display', expected '$($Want.Display)'" }
    $v = 0.0
    if (-not [double]::TryParse($Read, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return "unreadable value '$Read'" }
    ([Math]::Abs($v - [double]$Want.Normalized) -le 1e-6) ? $null : "reads $Read, expected $(([double]$Want.Normalized).ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture))"
}

# Pure function: the driver's report of one project (prefix '' / before_ / after_) against the layout. Checks the
# track and FX counts, the learned names, the bypass states, the latency (pdc == expectPdc), that no FX is
# offline, and the configured parameters. Bypass: plugin ids bypassed on top of the layout ('*' = all).
function Test-HarnessFxReport {
    param([Parameter(Mandatory)][hashtable]$Facts, [string]$Prefix = '', [Parameter(Mandatory)]$Layout, [hashtable]$Names = @{}, $Plugins, [string[]]$Bypass = @(), [object[]]$Reads = @())
    $bad = [Collections.Generic.List[string]]::new()
    $p = $Prefix
    if ($Facts["${p}tracks"] -ne "$($Layout.Tracks.Count)") { $bad.Add("${p}tracks=$($Facts["${p}tracks"]), expected $($Layout.Tracks.Count)") }
    for ($t = 0; $t -lt $Layout.Tracks.Count; $t++) {
        $fxs = @($Layout.Tracks[$t].Fx)
        $k = "${p}t${t}_"
        if ($Facts["${k}fx_count"] -ne "$($fxs.Count)") { $bad.Add("${k}fx_count=$($Facts["${k}fx_count"]), expected $($fxs.Count)"); continue }
        for ($f = 0; $f -lt $fxs.Count; $f++) {
            $fx = $fxs[$f]
            $q = "${k}fx${f}_"
            $Want = $Names[$fx.Plugin]
            if ($Want -and $Facts["${q}name"] -cne $Want) { $bad.Add("${q}name='$($Facts["${q}name"])', expected '$Want'") }
            $pdc = $Plugins[$fx.Plugin].ExpectPdc
            if ($Facts["${q}pdc"] -ne "$pdc") { $bad.Add("${q}pdc=$($Facts["${q}pdc"]), expected $pdc") }
            $off = ($fx.Bypass -or ('*' -cin $Bypass) -or ($fx.Plugin -cin $Bypass)) ? 'true' : 'false'
            if ($Facts["${q}bypassed"] -ne $off) { $bad.Add("${q}bypassed=$($Facts["${q}bypassed"]), expected $off") }
            if ($Facts["${q}offline"] -ne 'false') { $bad.Add("${q}offline=$($Facts["${q}offline"]) (the plugin did not load)") }
        }
    }
    for ($i = 0; $i -lt $Reads.Count; $i++) {
        $r = $Reads[$i]
        $q = "${p}t$($r.t)_fx$($r.f)_"
        $why = Test-HarnessParamValue $Facts["${q}param$($i + 1)"] $Facts["${q}display$($i + 1)"] $r
        if ($why) { $bad.Add("${q}parameter '$($r.name)' $why") }
    }
    , $bad.ToArray()
}

# -------- kinds --------

function Get-HarnessReference($Ctx, [string]$LayoutId, [int]$Sr, [int]$Block, [string]$Mode, [int]$Channels) {
    $key = "dry-$($LayoutId.TrimStart('@'))-$Sr-$Block-$Mode-$Channels"
    if (-not $Ctx.Refs.ContainsKey($key)) {
        $r = New-HarnessRun -Ctx $Ctx -Name $key -Layout (Get-HarnessLayout $Ctx $LayoutId) -Sr $Sr -Block $Block -Mode $Mode -Channels $Channels -NoFx
        $res = Invoke-HarnessRender $Ctx $r.Project $r.Wav 'reference'
        $Ctx.Refs[$key] = [pscustomobject]@{ Wav = $r.Wav; Why = $res.Why }
    }
    $Ctx.Refs[$key]
}

function Invoke-HarnessCompare($Ctx, $s, [string]$Reference, [string]$Test) {
    Compare-HarnessWavFiles -A $Reference -B $Test -MaxDiffDb $s.maxDiffDb -Lag ([int]$s.lag) -LagSearch ([int]$Ctx.Limits.lagSearch) -PeakMaxDb $s.peakMaxDb `
        -NotSilent:([bool]$s.notSilent) -HeadSeconds ([double]$Ctx.Limits.headSeconds)
}

function Invoke-HarnessRenderScenario($Ctx, $s) {
    $ch = $s.mono ? 1 : 2
    $mut = $s.mutate
    $offset = $mut ? [int]$mut.sourceOffsetSamples : 0
    $vol = $mut ? [double]$mut.trackVolume : 1.0
    $Layout = Get-HarnessLayout $Ctx $s.layout
    $c = $s.compare
    switch ($c.Kind) {
        'dry' {
            $ref = Get-HarnessReference $Ctx $s.layout ([int]$s.sr) ([int]$s.block) $s.mode $ch
            if ($ref.Why) { return New-HarnessOutcome INCOMPLETE "the dry reference render failed: $($ref.Why)" }
            $refWav = $ref.Wav
        }
        'repeat' {
            $r0 = New-HarnessRun -Ctx $Ctx -Name "$($s.id)-first" -Layout $Layout -Sr $s.sr -Block $s.block -Mode $s.mode -Channels $ch -Bypass $s.bypass
            $res0 = Invoke-HarnessRender $Ctx $r0.Project $r0.Wav
            if ($res0.Why) { return New-HarnessOutcome INCOMPLETE "the first render failed: $($res0.Why)" }
            $refWav = $r0.Wav
        }
        'variant' {
            $r0 = New-HarnessRun -Ctx $Ctx -Name "$($s.id)-variant" -Layout (Get-HarnessLayout $Ctx $c.Layout) -Sr $s.sr -Block $c.Block -Mode $c.Mode -Channels $ch -Bypass $c.Bypass
            $res0 = Invoke-HarnessRender $Ctx $r0.Project $r0.Wav
            if ($res0.Why) { return New-HarnessOutcome INCOMPLETE "the variant render failed: $($res0.Why)" }
            $refWav = $r0.Wav
        }
    }
    $r = New-HarnessRun -Ctx $Ctx -Name $s.id -Layout $Layout -Sr $s.sr -Block $s.block -Mode $s.mode -Channels $ch -Bypass $s.bypass -VolumeScale $vol -OffsetSamples $offset
    $res = Invoke-HarnessRender $Ctx $r.Project $r.Wav
    if ($res.Why) { return New-HarnessOutcome INCOMPLETE $res.Why }
    Invoke-HarnessCompare $Ctx $s $refWav $r.Wav
}

function Invoke-HarnessDeviceScenario($Ctx, $s) {
    $Layout = Get-HarnessLayout $Ctx $s.layout
    $r = New-HarnessRun -Ctx $Ctx -Name $s.id -Layout $Layout -Sr $s.sr -Block $s.block
    $Reads = Get-HarnessParamReads $Layout
    $lua = Invoke-HarnessLuaStep -Ctx $Ctx -Name $s.id -Step device -Job @{ project = $r.Project; reads = (ConvertTo-LuaReads $Reads) }
    if ($lua.Why) { return New-HarnessOutcome INCOMPLETE $lua.Why }
    $bad = [Collections.Generic.List[string]]::new()
    if ($lua.Result['dev_bsize'] -ne "$($s.block)") { $bad.Add("block size reads $($lua.Result['dev_bsize']), expected $($s.block)") }
    if ($lua.Result['dev_srate'] -ne "$($s.sr)") { $bad.Add("sample rate reads $($lua.Result['dev_srate']), expected $($s.sr)") }
    foreach ($p in (Test-HarnessFxReport -Facts $lua.Result -Layout $Layout -Names $Ctx.Names -Plugins $Ctx.Config.Plugins -Reads $Reads)) { $bad.Add($p) }
    if ($bad.Count) { return New-HarnessOutcome FAIL ($bad -join '; ') }
    $fxCount = @($Layout.Tracks | ForEach-Object { $_.Fx }).Count
    New-HarnessOutcome PASS "block $($s.block) and rate $($s.sr) read back; $fxCount FX report the configured latency; $($Reads.Count) parameters read back"
}

function Invoke-HarnessSaveReopenScenario($Ctx, $s) {
    $Layout = Get-HarnessLayout $Ctx $s.layout
    $r = New-HarnessRun -Ctx $Ctx -Name $s.id -Layout $Layout -Sr $s.sr -Block $s.block -Mode $s.mode -Bypass $s.bypass
    $saved = Join-Path $Ctx.Work "$($s.id)-saved.rpp"
    if (Test-Path -LiteralPath $saved) { Remove-Item -LiteralPath $saved }
    $Ctx.Files.Add($saved)
    $Reads = Get-HarnessParamReads $Layout
    $lua = Invoke-HarnessLuaStep -Ctx $Ctx -Name $s.id -Step savereopen -Job @{ project = $r.Project; saveAs = $saved; reads = (ConvertTo-LuaReads $Reads) }
    if ($lua.Why) { return New-HarnessOutcome INCOMPLETE $lua.Why }
    $bad = [Collections.Generic.List[string]]::new()
    foreach ($Prefix in 'before_', 'after_') {
        foreach ($p in (Test-HarnessFxReport -Facts $lua.Result -Prefix $Prefix -Layout $Layout -Names $Ctx.Names -Plugins $Ctx.Config.Plugins -Bypass $s.bypass -Reads $Reads)) { $bad.Add($p) }
    }
    foreach ($k in @($lua.Result.get_Keys() | Where-Object { $_ -like 'before_*' } | Sort-Object)) {
        $a = 'after_' + $k.Substring(7)
        if ($lua.Result[$a] -cne $lua.Result[$k]) { $bad.Add("$($k.Substring(7)) changed on reopen: '$($lua.Result[$k])' -> '$($lua.Result[$a])'") }
    }
    if ($lua.Result['saved'] -ne 'true') { $bad.Add('no new project file was saved') }
    if ($bad.Count) { return New-HarnessOutcome FAIL ($bad -join '; ') }
    $res = Invoke-HarnessRender $Ctx $r.Project $r.Wav
    if ($res.Why) { return New-HarnessOutcome INCOMPLETE "the render before saving failed: $($res.Why)" }
    $reopened = Join-Path $Ctx.Work "$($s.id)-saved.wav"
    if (Test-Path -LiteralPath $reopened) { Remove-Item -LiteralPath $reopened }
    # The saved copy keeps the render settings of the original, so it renders to the same name: move the first
    # render aside first.
    Move-Item -LiteralPath $r.Wav -Destination $reopened
    $Ctx.Files.Add($reopened)
    $res2 = Invoke-HarnessRender $Ctx $saved $r.Wav
    if ($res2.Why) { return New-HarnessOutcome INCOMPLETE "the render of the reopened project failed: $($res2.Why)" }
    $cmp = Compare-HarnessWavFiles -A $reopened -B $r.Wav -LagSearch ([int]$Ctx.Limits.lagSearch) -HeadSeconds ([double]$Ctx.Limits.headSeconds)
    New-HarnessOutcome $cmp.Status "FX state unchanged after save and reopen ($($Reads.Count) parameters); reopened render vs original: $($cmp.Detail)"
}

function Invoke-HarnessInstancesScenario($Ctx, $s) {
    $empty = [pscustomobject]@{ Id = '@empty'; Tracks = @(); Plugins = @() }
    $r = New-HarnessRun -Ctx $Ctx -Name $s.id -Layout $empty -Sr $s.sr -Block $s.block
    $Watch = @{ warm = (Join-Path $Ctx.Work "$($s.id).warm"); loop = (Join-Path $Ctx.Work "$($s.id).loop") }
    $Names = @($s.plugins | ForEach-Object { $Ctx.Names[$_] })
    if (@($Names | Where-Object { -not $_ }).Count) { return New-HarnessOutcome INCOMPLETE 'a plugin of this scenario has no learned name' }
    $lua = Invoke-HarnessLuaStep -Ctx $Ctx -Name $s.id -Step instances -Watch $Watch -Job @{
        project = $r.Project; names = $Names; cycles = [int]$s.cycles; warmup = [int]$s.warmup; play = [bool]$s.play; warmMark = $Watch.warm; loopMark = $Watch.loop
    }
    if ($lua.Why) { return New-HarnessOutcome INCOMPLETE $lua.Why }
    if ($lua.Result['cycles_done'] -ne "$($s.cycles)") { return New-HarnessOutcome FAIL "only $($lua.Result['cycles_done']) of $($s.cycles) cycles done" }
    $marks = $lua.Run.Marks
    $markWhy = Get-HarnessMarkProblem -Samples $marks -LostAt @($lua.Run.SampleLost) -Need 'warm', 'loop'
    if ($markWhy) { return New-HarnessOutcome INCOMPLETE $markWhy }
    $dh = $marks['loop'].Handles - $marks['warm'].Handles
    $dm = [math]::Round($marks['loop'].PrivateMB - $marks['warm'].PrivateMB, 1)
    $summary = "$($s.cycles) cycles ($($s.warmup) warm-up) of $($s.plugins -join '+'): handles $($dh -ge 0 ? '+' : '')$dh, private memory $($dm -ge 0 ? '+' : '')$dm MB, tracks left $($lua.Result['tracks_left'])"
    if ($dh -gt [int]$s.maxHandleGrowth -or $dm -gt [double]$s.maxPrivateGrowthMB) { return New-HarnessOutcome FAIL "growth above the limits (handles $($s.maxHandleGrowth), memory $($s.maxPrivateGrowthMB) MB): $summary" }
    New-HarnessOutcome PASS $summary
}

# A driver step that never finishes: timeout and kill must both end as INCOMPLETE, with the process gone and every
# lock of the set free again. Returns INCOMPLETE when the watchdog did that; PASS (the hang ended by itself) or FAIL
# (process still alive though the launch says it is gone: the PID and its start time, since Windows hands out the number
# again once a process is gone) otherwise. A process the watchdog says it could not end is
# INCOMPLETE like every launch with StillRunning, and without the "free" text, so the negative case is not verified. A
# lock that is busy because another process took it right after ours was released cannot be told apart from ours not
# being released: that is INCOMPLETE without the "free" text as well.
function Invoke-HarnessHangScenario($Ctx, $s) {
    $lua = Invoke-HarnessLuaStep -Ctx $Ctx -Name $s.id -Step hang -TimeoutSec ([double]$s.timeoutSec) -KillAfterSec ([double]$s.killAfterSec)
    if (-not $lua.Why) { return New-HarnessOutcome PASS 'the driver that should hang finished normally (the negative case did not take effect)' }
    if ($lua.Run.Status -in 'LockBusy', 'SkipMarker', 'Blocked') { return New-HarnessOutcome INCOMPLETE "$($lua.Why); the watchdog could not be checked" }
    if ($lua.Run.StillRunning) { return New-HarnessOutcome INCOMPLETE $lua.Why }
    if (@(Get-HarnessOwnProcessesLeft -Started $Ctx.Started.ToArray() | Where-Object { $_.Pid -eq $lua.Run.Pid }).Count) { return New-HarnessOutcome FAIL "process $($lua.Run.Pid) is still alive" }
    $busy = @()
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $busy = @($Ctx.Locks | Where-Object { -not (Test-HarnessLockFree -FullName $_) })
        if ($busy.Count) { Start-Sleep -Milliseconds 500 }
    } while ($busy.Count -and (Get-Date) -lt $deadline)
    if ($busy.Count) { return New-HarnessOutcome INCOMPLETE "$($lua.Why); lock still busy 20 s after the process ended (held by another process, or not released): $($busy -join ', ')" }
    New-HarnessOutcome INCOMPLETE "$($lua.Why); the process has ended and the GUI locks are free"
}

$script:Handlers = @{
    render = ${function:Invoke-HarnessRenderScenario}; device = ${function:Invoke-HarnessDeviceScenario}; savereopen = ${function:Invoke-HarnessSaveReopenScenario}
    instances = ${function:Invoke-HarnessInstancesScenario}; hang = ${function:Invoke-HarnessHangScenario}
}

function Get-HarnessScenarioKinds { , @($script:Handlers.get_Keys() | Sort-Object) }

# The functions extension handlers get in Ctx.Api (see docs/EXTENDING.md).
function Get-HarnessApi {
    @{
        Outcome = ${function:New-HarnessOutcome}; NewRun = ${function:New-HarnessRun}; Render = ${function:Invoke-HarnessRender}; LuaStep = ${function:Invoke-HarnessLuaStep}
        Compare = ${function:Compare-HarnessWavFiles}; HostFailure = ${function:Get-HarnessHostFailure}; Layout = ${function:Get-HarnessLayout}; Signal = ${function:Get-HarnessSignal}
        Reference = ${function:Get-HarnessReference}; HidePaths = ${function:Hide-HarnessPaths}; FxReport = ${function:Test-HarnessFxReport}; ParamReads = ${function:Get-HarnessParamReads}
    }
}

# Runs one scenario of any kind; an exception inside a handler is INCOMPLETE (no conclusion), never PASS.
function Invoke-HarnessScenario {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Scenario)
    if (-not $Ctx.Api) { $Ctx.Api = Get-HarnessApi }
    $handler = $script:Handlers[$Scenario.kind]
    $ext = $Ctx.Kinds.ContainsKey($Scenario.kind) ? $Ctx.Kinds[$Scenario.kind] : $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not $handler -and -not $ext) { $o = New-HarnessOutcome INCOMPLETE "no handler for kind $($Scenario.kind)" }
    else {
        try {
            $o = $handler ? (& $handler $Ctx $Scenario) : (& $ext.Run $Ctx $Scenario)
            if ($null -eq $o -or $o.Status -cnotin 'PASS', 'FAIL', 'INCOMPLETE') { $o = New-HarnessOutcome INCOMPLETE "the handler of kind $($Scenario.kind) returned no valid outcome" }
        } catch { $o = New-HarnessOutcome INCOMPLETE "the scenario threw: $($_.Exception.Message -replace '\s+', ' ')" }
    }
    $o | Add-Member -NotePropertyName Seconds -NotePropertyValue ([math]::Round($sw.Elapsed.TotalSeconds, 1)) -PassThru -Force
}

Export-ModuleMember -Function New-HarnessOutcome, Hide-HarnessPaths, Hide-HarnessFacts, New-HarnessContext, Set-HarnessAudioConfig, Invoke-HarnessLaunch, Get-HarnessHostFailure, Get-HarnessSignal,
    Get-HarnessLayout, New-HarnessRun, Invoke-HarnessRender, Invoke-HarnessLuaStep, Get-HarnessParamReads, Test-HarnessParamValue, Test-HarnessFxReport, Get-HarnessReference,
    Get-HarnessScenarioKinds, Get-HarnessApi, Invoke-HarnessScenario, Get-HarnessSkipMarkerHit

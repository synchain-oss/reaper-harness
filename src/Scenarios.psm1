# SPDX-License-Identifier: MIT
#
# Running scenarios: make the signal, write the project, start REAPER to render or to run a Lua driver step, judge.
# Every scenario returns @{ Status; Detail [; Facts] }: PASS / FAIL / INCOMPLETE. INCOMPLETE means no conclusion
# could be reached (timeout, killed, stuck dialog, no output file, lock not available, skip marker appeared) and is
# never treated as PASS. FAIL is only for a criterion that was checked and not met.
# Built-in kinds (handlers in $script:Handlers):
#   render      render a layout (and the stems asked for) and compare with the same layout without FX (dry), the
#               same render again (repeat) or another variant (layout / block / mode / bypass), or judge it on its
#               own (none)
#   device      device block size, sample rate and anticipative FX setting read back; every FX reports the
#               configured latency; FX with a named state are saved back unchanged
#   savereopen  FX state survives save and reopen (cycles times); the reopened project renders bit-identical to the
#               original
#   instances   add and remove instances many times; handle and memory growth stay below the limits
#   transport   a sequence of transport, arm and monitoring states of one track: whether its FX chain is run in each,
#               and what it gets (Transport.psm1)
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
Import-Module (Join-Path $PSScriptRoot 'Plugins.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Transport.psm1') -ErrorAction Stop

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
# quote of that stretch that a blank, a punctuation mark or the end of the text follows, and the sentence around it stays,
# unless a \ or / still comes after it on that line: then that quote was an apostrophe followed by a blank inside a name
# ('D:\Jane O' Neil\x.wav' goes on past it), and the whole stretch is masked like an unquoted path, the rest of the line
# with it. Any other single quote is an apostrophe in a name: with no closing quote the path is masked like an unquoted
# one. What cannot be told apart: an apostrophe followed by a blank in the last part of a path, with no separator after
# it on the line ('D:\a\Jane O' Neil.wav'), reads as the closing quote, and the end of that file name stays in the text.
$script:PathStart = '(?:[A-Za-z]:[\\/]|\\\\|//)'
$script:PathBody = '(?:[^"<>|?*:\r\n]|:[\\/])*'
$script:QuoteEnd = '(?=[\s.,;:)\]]|$)(?![^\r\n]*[\\/])'
function Hide-HarnessPaths([AllowNull()][string]$Text) {
    if (-not $Text) { return '' }
    $Text -replace "'$($script:PathStart)$($script:PathBody)'$($script:QuoteEnd)", "'<path>'" -replace "$($script:PathStart)$($script:PathBody)", '<path>'
}

# The same for the facts of an outcome, which an extension fills with whatever it likes: every string at any depth, keys
# too. Numbers, booleans, characters, dates and enums stay as they are; any other value type (a pair of strings, for one)
# can hold a path in its text, so it is masked as text. Anything nested deeper than any real result is cut off, not
# written out.
function Hide-HarnessFacts([AllowNull()]$Value, [int]$Depth = 0) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return Hide-HarnessPaths $Value }
    if ($Value -is [bool] -or $Value -is [decimal] -or $Value -is [DateTime] -or $Value -is [DateTimeOffset] -or $Value -is [Enum] -or ($Value -is [ValueType] -and $Value.GetType().IsPrimitive)) { return $Value }
    if ($Value -is [ValueType]) { return Hide-HarnessPaths ([string]$Value) }
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
        [Parameter(Mandatory)]$Config, [object[]]$Installed = @(), [object[]]$Jsfx = @(), $States = $null, [Parameter(Mandatory)][string[]]$Locks, [string[]]$SkipMarkers = @(),
        [string[]]$LuaExtensions = @(), [hashtable]$Kinds = @{}, [hashtable]$ToolJsfx = @{}
    )
    $byId = @{}
    foreach ($row in $Installed) { $byId[$row.Id] = $row }
    $jsById = @{}
    foreach ($row in $Jsfx) { $jsById[$row.Id] = $row }
    @{
        Exe = $ReaperExe; Work = $WorkDir; Driver = $Driver; Config = $Config; Limits = $Config.Limits; Signal = $Config.Signal
        Locks = $Locks; LockWaitSec = [double]$Config.Limits.lockWaitSec; SkipMarkers = $SkipMarkers; LuaExtensions = $LuaExtensions; Kinds = $Kinds
        Installed = $byId; Jsfx = $jsById; States = ($States ?? [ordered]@{}); Blocks = @{}; Names = @{}; AddNames = @{}; Launches = 0; LaunchLog = [Collections.Generic.List[object]]::new()
        Signals = @{}; Refs = @{}; Files = [Collections.Generic.List[string]]::new(); ToolJsfx = $ToolJsfx
        Retries = [Collections.Generic.List[object]]::new() # launches started once more (see Invoke-HarnessLaunch)
        Started = [Collections.Generic.List[object]]::new() # every process started: Pid, StartUtc
        StillRunning = $null # set when the watchdog could not end a process: Pid, Label, Lock
        Launcher = $null; ModuleSampler = $null; Stopper = $null # self-test only
        Api = $null # filled in below
    }
}

# REAPER keeps "anticipative FX processing" in bit 0 of [REAPER] workrender; without the key it uses 17 (bit 0 set).
# Both measured on REAPER 7.82 (see docs/CONFIG.md). Pure function: the value to write, other bits kept.
$script:WorkrenderDefault = 17
function Get-HarnessWorkrender([AllowNull()][AllowEmptyString()][string]$Current, [bool]$AnticipativeFx) {
    $v = 0
    if (-not [int]::TryParse($Current, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $v = $script:WorkrenderDefault }
    $AnticipativeFx ? ($v -bor 1) : ($v -band -bnot 1)
}

# "Run FX when stopped" is bit 0 of [REAPER] runallonstop; without the key REAPER uses 1. Measured on REAPER 7.82 (see
# docs/CONFIG.md). Pure function: the value to write, other bits kept.
function Get-HarnessRunAllOnStop([AllowNull()][AllowEmptyString()][string]$Current, [bool]$RunFxWhenStopped) {
    $v = 0
    if (-not [int]::TryParse($Current, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $v = 1 }
    $RunFxWhenStopped ? ($v -bor 1) : ($v -band -bnot 1)
}

# Private ini: Dummy audio device (silent), sample rate and block size; no save prompt after recording;
# anticipative FX processing on or off; "Run FX when stopped" on or off (written every time, so it is never left over
# from an earlier scenario).
function Set-HarnessAudioConfig([int]$Sr, [int]$Block, [bool]$AnticipativeFx = $true, [bool]$RunFxWhenStopped = $true) {
    $null = Set-HarnessIniValue -Section audioconfig -Key mode -Value 4
    $null = Set-HarnessIniValue -Section audioconfig -Key dummy_srate -Value $Sr
    $null = Set-HarnessIniValue -Section audioconfig -Key dummy_blocksize -Value $Block
    $null = Set-HarnessIniValue -Section REAPER -Key promptendrec -Value 0
    $null = Set-HarnessIniValue -Section REAPER -Key workrender -Value (Get-HarnessWorkrender (Get-HarnessIniValue -Section REAPER -Key workrender) $AnticipativeFx)
    $null = Set-HarnessIniValue -Section REAPER -Key runallonstop -Value (Get-HarnessRunAllOnStop (Get-HarnessIniValue -Section REAPER -Key runallonstop) $RunFxWhenStopped)
}

function Get-HarnessSkipMarkerHit([string[]]$Markers) { @($Markers | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) | Select-Object -First 1 }

# The locks of a launch whose process could not be ended stay held until this process exits, when the kernel takes them
# back. Referenced from here so that no garbage collection closes them earlier, which would end them just the same.
$script:KeptLocks = [Collections.Generic.List[object]]::new()

# Starts REAPER while holding every lock of the set. Lock not available -> Status LockBusy; a skip marker that
# appeared since the preflight -> Status SkipMarker; an earlier process of this context that could not be ended ->
# Status Blocked. In all three REAPER is not started (the caller records INCOMPLETE; the harness never runs REAPER
# without its locks, nor next to a REAPER it could not end). The launch that reports StillRunning keeps its locks: its
# window may still be on the desktop, and the next start of any harness has to wait for it.
# REAPER's evaluation licence reminder comes up now and then at the start of a launch and ends it (stuck dialog): it is
# never clicked away, the launch is ended by its PID as always, and then the whole launch is done once more, through
# every guard again (skip marker, locks, the configuration directory), after deleting Outputs (the files the launch
# is to write, so that nothing the first attempt left counts for the second). Only once, never after StillRunning; a
# second reminder ends the launch like any stuck dialog. Each retry is listed in Ctx.Retries (the result has them).
function Invoke-HarnessLaunch {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][hashtable]$HostArgs, [string]$Label = '', [string[]]$Outputs = @())
    $Run = Invoke-HarnessLaunchOnce -Ctx $Ctx -HostArgs $HostArgs -Label $Label
    if ($Run.Status -ceq 'Modal' -and $Run.Modal -ceq 'license-nag' -and -not $Run.StillRunning) {
        # What the first launch left behind must not be read as the second one's: when it cannot be removed, no retry
        foreach ($f in $Outputs) { if (Test-Path -LiteralPath $f) { try { Remove-Item -LiteralPath $f -Force } catch { return $Run } } }
        $Ctx.Retries.Add([pscustomobject]@{ Label = $Label; Reason = 'license-nag' })
        Write-Host "  [retry] $Label`: the evaluation licence reminder ended the launch; starting it once more"
        $Run = Invoke-HarnessLaunchOnce -Ctx $Ctx -HostArgs $HostArgs -Label $Label
    }
    $Run
}

function Invoke-HarnessLaunchOnce {
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
        # REAPER looks for a new version about once a day and, when there is one, shows a notification that ends the launch
        # as stuck (INCOMPLETE). [REAPER] verchk=0 turns that check off; written on every launch, so that a directory
        # initialised without it is covered too. Measured on REAPER 7.82: with the key a week-old [verchk] lastt stays as it
        # was and no notification comes; without it the notification shows within about 2 s.
        $null = Set-HarnessIniValue -Section REAPER -Key verchk -Value 0
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

# The signal file for a rate and channel count. Spec: a track's own signal (seed, noise, sine; Config.psm1), or none
# for the top-level one. The same settings always give the same file, whichever track or layout asks.
function Get-HarnessSignal {
    param([Parameter(Mandatory)]$Ctx, [int]$Sr, [int]$Channels, [int]$OffsetSamples = 0, $Spec = $null)
    $key = "$Sr-$Channels-$OffsetSamples"
    $s = $Ctx.Signal
    if ($null -ne $Spec) {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $specText = '{0}|{1}|{2}|{3}' -f $Spec.Seed, $Spec.NoiseDb.ToString('R', $inv), $Spec.SineHz.ToString('R', $inv), $Spec.SineDb.ToString('R', $inv)
        $key += '-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($specText))).Substring(0, 8).ToLowerInvariant()
        $s = [pscustomobject]@{ Seconds = $Ctx.Signal.Seconds; Seed = $Spec.Seed; NoiseDb = $Spec.NoiseDb; SineHz = $Spec.SineHz; SineDb = $Spec.SineDb }
    }
    if (-not $Ctx.Signals.ContainsKey($key)) {
        $path = Join-Path $Ctx.Work "_signal-$key.wav"
        New-HarnessSignalFile -Path $path -Rate $Sr -Channels $Channels -Seconds $s.Seconds -Seed $s.Seed -NoiseDb $s.NoiseDb -SineHz $s.SineHz -SineDb $s.SineDb -OffsetSamples $OffsetSamples
        $Ctx.Files.Add($path)
        $Ctx.Signals[$key] = $path
    }
    $Ctx.Signals[$key]
}

function Get-HarnessLayout($Ctx, [string]$Id) { ($Id -ceq '@dry') ? (Get-HarnessDryLayout) : $Ctx.Config.Layouts[$Id] }

# The files of one render in the work directory (pure): Project, Wav (the master) and Stems (track name -> file).
# With stems REAPER writes <Name>-stem-<track>.wav per stem and <Name>-stem-Master.wav for the master (the render
# pattern of New-HarnessProjectText), so a stem never takes the name of another render of the scenario
# (<id>-first, <id>-variant). The files the scenarios of a round share (the signals, the dry references) start with
# '_', which no scenario id does, so no scenario renders into them either.
function Get-HarnessRunFiles([string]$Work, [string]$Name, [string[]]$Stems = @()) {
    $stemFiles = [ordered]@{}
    foreach ($st in $Stems) { $stemFiles[$st] = Join-Path $Work "$Name-stem-$st.wav" }
    [pscustomobject]@{ Project = (Join-Path $Work "$Name.rpp"); Wav = (Join-Path $Work ($Stems.Count ? "$Name-stem-Master.wav" : "$Name.wav")); Stems = $stemFiles }
}

# Writes the project and sets the audio configuration; returns the project path, the path of its (master) render and
# Stems (track name -> path of its stem), named as Get-HarnessRunFiles says.
function New-HarnessRun {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Layout, [int]$Sr = 48000, [int]$Block = 512,
          [string]$Mode = 'offline', [int]$Channels = 2, [string[]]$Bypass = @(), [double]$VolumeScale = 1.0, [int]$OffsetSamples = 0, [switch]$NoFx,
          [hashtable]$Blocks = $null, [string[]]$Stems = @(), [bool]$AnticipativeFx = $true, [bool]$RunFxWhenStopped = $true, [switch]$NoItems)
    $files = Get-HarnessRunFiles $Ctx.Work $Name $Stems
    $Project = $files.Project
    $Wav = $files.Wav
    $stemFiles = $files.Stems
    foreach ($f in @($Wav) + @($stemFiles.get_Values())) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f } }
    $sources = @{}
    foreach ($t in $Layout.Tracks) { if ($t.Source -and $null -ne $t.Signal) { $sources[$t.Name] = Get-HarnessSignal $Ctx $Sr $Channels $OffsetSamples -Spec $t.Signal } }
    $Text = New-HarnessProjectText -Layout $Layout -Blocks ($Blocks ?? $Ctx.Blocks) -SourceWav (Get-HarnessSignal $Ctx $Sr $Channels $OffsetSamples) -Sources $sources -RenderDir $Ctx.Work -RenderName $Name `
        -SampleRate $Sr -Channels $Channels -Mode $Mode -Bypass $Bypass -Seconds $Ctx.Signal.Seconds -VolumeScale $VolumeScale -Stems $Stems -NoFx:$NoFx -NoItems:$NoItems
    Write-HarnessText -Path $Project -Text $Text
    Set-HarnessAudioConfig -Sr $Sr -Block $Block -AnticipativeFx $AnticipativeFx -RunFxWhenStopped $RunFxWhenStopped
    $Ctx.Files.Add($Project); $Ctx.Files.Add($Wav); foreach ($f in $stemFiles.get_Values()) { $Ctx.Files.Add($f) }
    [pscustomobject]@{ Project = $Project; Wav = $Wav; Stems = $stemFiles }
}

# Renders a project. Also: further files the render must produce (stems).
function Invoke-HarnessRender($Ctx, [string]$Project, [string]$Wav, [string]$Label = 'render', [string[]]$Also = @()) {
    $Run = Invoke-HarnessLaunch -Ctx $Ctx -Label $Label -HostArgs @{ ReaperArgs = @('-renderproject', $Project); TimeoutSec = [double]$Ctx.Limits.renderTimeoutSec } -Outputs (@($Wav) + $Also)
    $why = Get-HarnessHostFailure $Run
    if (-not $why -and -not (Test-Path -LiteralPath $Wav)) { $why = 'the render produced no file' }
    if (-not $why) {
        $missing = @($Also | Where-Object { -not (Test-Path -LiteralPath $_) } | ForEach-Object { Split-Path -Leaf $_ })
        if ($missing.Count) { $why = "the render produced no stem file $($missing -join ', ')" }
    }
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
    $Run = Invoke-HarnessLaunch -Ctx $Ctx -Label $Step -Outputs (@($resultFile) + @($Watch.get_Values()) + @($Job['saveAs'] | Where-Object { $_ })) -HostArgs @{
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

# Pure function: the FX of the layout that run with a named state, against a project REAPER saved with them loaded
# (Saved: Get-HarnessFxBlocks of it). The block REAPER saves back must be the one it was given (the header line aside):
# then the plugin holds that state. Blocks: variant key -> the block lines written; States: "<plugin>@<state>" ->
# state (for the name and hash in the text). Returns @{ Problems; Proven (texts like "input a-ch1 0123456789ab") }.
function Test-HarnessStateProof {
    param([Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][hashtable]$Blocks, [System.Collections.IDictionary]$States = @{}, $Saved)
    $bad = [Collections.Generic.List[string]]::new()
    $proven = [Collections.Generic.List[string]]::new()
    foreach ($t in $Layout.Tracks) {
        $fxs = @($t.Fx)
        for ($f = 0; $f -lt $fxs.Count; $f++) {
            $fx = $fxs[$f]
            if (-not $fx.State) { continue }
            $sk = "$($fx.Plugin)@$($fx.State)"
            $Label = "track '$($t.Name)' FX $($f + 1) ($($fx.Plugin) state $($fx.State))"
            $list = @(($null -ne $Saved -and $Saved.Contains($t.Name)) ? $Saved[$t.Name] : @())
            if ($f -ge $list.Count) { $bad.Add("${Label}: not in the saved project"); continue }
            $Want = @($Blocks[$fx.Variant] | Select-Object -Skip 1)
            $got = @($list[$f].Lines | Select-Object -Skip 1)
            if (($Want -join "`n") -cne ($got -join "`n")) { $bad.Add("${Label}: the block REAPER saved back differs from the one it loaded, so the plugin does not hold that state"); continue }
            $proven.Add("$($fx.Plugin) $($fx.State)$($States.Contains($sk) ? " $($States[$sk].Sha)" : '')")
        }
    }
    [pscustomobject]@{ Problems = $bad.ToArray(); Proven = $proven.ToArray() }
}

function Test-HarnessHasStates($Layout) { [bool]@($Layout.Tracks | ForEach-Object { $_.Fx } | Where-Object { $_.State }).Count }

# Pure function: the audio settings the device step read back (Facts: the driver's report) against the scenario's:
# block size, sample rate, anticipative FX processing (bit 0 of workrender) and, when given, "Run FX when stopped"
# (bit 0 of runallonstop). Returns the problems.
function Test-HarnessHostReadback([Parameter(Mandatory)][hashtable]$Facts, [int]$Block, [int]$Sr, [bool]$AnticipativeFx, [Nullable[bool]]$RunFxWhenStopped = $null) {
    $bad = [Collections.Generic.List[string]]::new()
    if ($Facts['dev_bsize'] -ne "$Block") { $bad.Add("block size reads $($Facts['dev_bsize']), expected $Block") }
    if ($Facts['dev_srate'] -ne "$Sr") { $bad.Add("sample rate reads $($Facts['dev_srate']), expected $Sr") }
    $wr = 0
    if (-not [int]::TryParse([string]$Facts['cfg_workrender'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$wr)) { $bad.Add("workrender reads '$($Facts['cfg_workrender'])'") }
    elseif ([bool]($wr -band 1) -ne $AnticipativeFx) { $bad.Add("anticipative FX processing reads $(($wr -band 1) ? 'on' : 'off'), expected $($AnticipativeFx ? 'on' : 'off')") }
    if ($null -ne $RunFxWhenStopped) {
        $ro = 0
        if (-not [int]::TryParse([string]$Facts['cfg_runallonstop'], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$ro)) { $bad.Add("runallonstop reads '$($Facts['cfg_runallonstop'])'") }
        elseif ([bool]($ro -band 1) -ne $RunFxWhenStopped) { $bad.Add("Run FX when stopped reads $(($ro -band 1) ? 'on' : 'off'), expected $($RunFxWhenStopped ? 'on' : 'off')") }
    }
    , $bad.ToArray()
}

# Pure function: the savereopen report (Facts) after Cycles save and reopen cycles: every before_ value must read the
# same after each reopen (a value missing after a reopen counts as changed). Returns the problems, one per value
# (the first reopen it changed on).
function Test-HarnessReopenFacts([Parameter(Mandatory)][hashtable]$Facts, [int]$Cycles) {
    $bad = [Collections.Generic.List[string]]::new()
    foreach ($k in @($Facts.get_Keys() | Where-Object { $_ -like 'before_*' } | Sort-Object)) {
        foreach ($i in 1..$Cycles) {
            $a = "after${i}_" + $k.Substring(7)
            if ($Facts[$a] -cne $Facts[$k]) { $bad.Add("$($k.Substring(7)) changed on reopen $i of ${Cycles}: '$($Facts[$k])' -> '$($Facts[$a])'"); break }
        }
    }
    , $bad.ToArray()
}

# -------- kinds --------

# The name of a dry reference render (pure); it starts with '_' (see Get-HarnessRunFiles).
function Get-HarnessReferenceName([string]$LayoutId, [int]$Sr, [int]$Block, [string]$Mode, [int]$Channels, [string[]]$Stems = @(), [bool]$AnticipativeFx = $true, [bool]$RunFxWhenStopped = $true) {
    $key = "_dry-$($LayoutId.TrimStart('@'))-$Sr-$Block-$Mode-$Channels" + ($AnticipativeFx ? '' : '-noaf') + ($RunFxWhenStopped ? '' : '-norfs')
    if ($Stems.Count) { $key += '-stems-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Stems -join "`n"))).Substring(0, 8).ToLowerInvariant() }
    $key
}

# The dry reference: the layout without any FX. Stems: tracks rendered as stems as well. Cached per round.
function Get-HarnessReference($Ctx, [string]$LayoutId, [int]$Sr, [int]$Block, [string]$Mode, [int]$Channels, [string[]]$Stems = @(), [bool]$AnticipativeFx = $true, [bool]$RunFxWhenStopped = $true) {
    $key = Get-HarnessReferenceName $LayoutId $Sr $Block $Mode $Channels $Stems $AnticipativeFx $RunFxWhenStopped
    if (-not $Ctx.Refs.ContainsKey($key)) {
        $r = New-HarnessRun -Ctx $Ctx -Name $key -Layout (Get-HarnessLayout $Ctx $LayoutId) -Sr $Sr -Block $Block -Mode $Mode -Channels $Channels -Stems $Stems -AnticipativeFx $AnticipativeFx -RunFxWhenStopped $RunFxWhenStopped -NoFx
        $res = Invoke-HarnessRender $Ctx $r.Project $r.Wav 'reference' -Also @($r.Stems.get_Values())
        $Ctx.Refs[$key] = [pscustomobject]@{ Wav = $r.Wav; Stems = $r.Stems; Why = $res.Why }
    }
    $Ctx.Refs[$key]
}

# One render file against its criteria (the scenario's own or a stem's): with a reference compared with it, without
# one judged on its own.
function Invoke-HarnessCompare($Ctx, $s, [string]$Reference, [string]$Test) {
    $levels = @{ RmsDb = $s.rmsDb; EnergyRatioDb = $s.energyRatioDb }
    if (-not $Reference) { return Test-HarnessWavFile -Path $Test -PeakMaxDb $s.peakMaxDb -NotSilent:([bool]$s.notSilent) @levels }
    Compare-HarnessWavFiles -A $Reference -B $Test -MaxDiffDb $s.maxDiffDb -Lag ([int]$s.lag) -LagSearch ([int]$Ctx.Limits.lagSearch) -PeakMaxDb $s.peakMaxDb `
        -NotSilent:([bool]$s.notSilent) -HeadSeconds ([double]$Ctx.Limits.headSeconds) -RmsChangeDb $s.rmsChangeDb @levels
}

function Get-HarnessOutcomeStatus([string[]]$StatusList) { foreach ($x in 'FAIL', 'INCOMPLETE') { if ($x -cin $StatusList) { return $x } }; 'PASS' }

function Invoke-HarnessRenderScenario($Ctx, $s) {
    $ch = $s.mono ? 1 : 2
    $mut = $s.mutate
    $offset = $mut ? [int]$mut.sourceOffsetSamples : 0
    $vol = $mut ? [double]$mut.trackVolume : 1.0
    $af = [bool]$s.host.AnticipativeFx
    $rfs = [bool]$s.host.RunFxWhenStopped
    $Layout = Get-HarnessLayout $Ctx $s.layout
    $Stems = @($s.stems)
    $refStems = @($Stems | Where-Object { $_.Compare -eq 'reference' } | ForEach-Object { $_.Track })
    $c = $s.compare
    $ref = $null
    switch ($c.Kind) {
        'dry' {
            $ref = Get-HarnessReference $Ctx $s.layout ([int]$s.sr) ([int]$s.block) $s.mode $ch -Stems $refStems -AnticipativeFx $af -RunFxWhenStopped $rfs
            if ($ref.Why) { return New-HarnessOutcome INCOMPLETE "the dry reference render failed: $($ref.Why)" }
        }
        'repeat' {
            $ref = New-HarnessRun -Ctx $Ctx -Name "$($s.id)-first" -Layout $Layout -Sr $s.sr -Block $s.block -Mode $s.mode -Channels $ch -Bypass $s.bypass -Stems $refStems -AnticipativeFx $af -RunFxWhenStopped $rfs
            $res0 = Invoke-HarnessRender $Ctx $ref.Project $ref.Wav -Also @($ref.Stems.get_Values())
            if ($res0.Why) { return New-HarnessOutcome INCOMPLETE "the first render failed: $($res0.Why)" }
        }
        'variant' {
            $ref = New-HarnessRun -Ctx $Ctx -Name "$($s.id)-variant" -Layout (Get-HarnessLayout $Ctx $c.Layout) -Sr $s.sr -Block $c.Block -Mode $c.Mode -Channels $ch -Bypass $c.Bypass -Stems $refStems -AnticipativeFx $af -RunFxWhenStopped $rfs
            $res0 = Invoke-HarnessRender $Ctx $ref.Project $ref.Wav -Also @($ref.Stems.get_Values())
            if ($res0.Why) { return New-HarnessOutcome INCOMPLETE "the variant render failed: $($res0.Why)" }
        }
    }
    $r = New-HarnessRun -Ctx $Ctx -Name $s.id -Layout $Layout -Sr $s.sr -Block $s.block -Mode $s.mode -Channels $ch -Bypass $s.bypass -VolumeScale $vol -OffsetSamples $offset `
        -Stems @($Stems | ForEach-Object { $_.Track }) -AnticipativeFx $af -RunFxWhenStopped $rfs
    $res = Invoke-HarnessRender $Ctx $r.Project $r.Wav -Also @($r.Stems.get_Values())
    if ($res.Why) { return New-HarnessOutcome INCOMPLETE $res.Why }
    $master = Invoke-HarnessCompare $Ctx $s ($ref ? $ref.Wav : '') $r.Wav
    if (-not $Stems.Count) { return $master }
    # The master line first (negative cases match its start), then one part per stem
    $outcomes = @($master) + @(foreach ($st in $Stems) {
            $o = Invoke-HarnessCompare $Ctx $st.Criteria (($st.Compare -eq 'reference') ? $ref.Stems[$st.Track] : '') $r.Stems[$st.Track]
            [pscustomobject]@{ Status = $o.Status; Detail = "stem $($st.Track): $($o.Detail)" }
        })
    New-HarnessOutcome (Get-HarnessOutcomeStatus @($outcomes | ForEach-Object { $_.Status })) (@($outcomes | ForEach-Object { $_.Detail }) -join ' | ')
}

function Invoke-HarnessDeviceScenario($Ctx, $s) {
    $Layout = Get-HarnessLayout $Ctx $s.layout
    $af = [bool]$s.host.AnticipativeFx
    $rfs = [bool]$s.host.RunFxWhenStopped
    $r = New-HarnessRun -Ctx $Ctx -Name $s.id -Layout $Layout -Sr $s.sr -Block $s.block -AnticipativeFx $af -RunFxWhenStopped $rfs
    $Reads = Get-HarnessParamReads $Layout
    $Job = @{ project = $r.Project; reads = (ConvertTo-LuaReads $Reads) }
    $hasStates = Test-HarnessHasStates $Layout
    if ($hasStates) {
        # A copy saved while the project is open shows what the plugins hold
        $Job.saveAs = Join-Path $Ctx.Work "$($s.id)-device.rpp"
        if (Test-Path -LiteralPath $Job.saveAs) { Remove-Item -LiteralPath $Job.saveAs }
        $Ctx.Files.Add($Job.saveAs)
    }
    $lua = Invoke-HarnessLuaStep -Ctx $Ctx -Name $s.id -Step device -Job $Job
    if ($lua.Why) { return New-HarnessOutcome INCOMPLETE $lua.Why }
    $bad = [Collections.Generic.List[string]]::new()
    foreach ($p in (Test-HarnessHostReadback -Facts $lua.Result -Block $s.block -Sr $s.sr -AnticipativeFx $af -RunFxWhenStopped $rfs)) { $bad.Add($p) }
    foreach ($p in (Test-HarnessFxReport -Facts $lua.Result -Layout $Layout -Names $Ctx.Names -Plugins $Ctx.Config.Plugins -Reads $Reads)) { $bad.Add($p) }
    $proof = $null
    if ($hasStates) {
        if ($lua.Result['saved'] -ne 'true' -or -not (Test-Path -LiteralPath $Job.saveAs)) { return New-HarnessOutcome INCOMPLETE 'the copy that proves the states was not saved' }
        $proof = Test-HarnessStateProof -Layout $Layout -Blocks $Ctx.Blocks -States $Ctx.States -Saved (Get-HarnessFxBlocks ([IO.File]::ReadAllText($Job.saveAs)))
        foreach ($p in $proof.Problems) { $bad.Add($p) }
    }
    if ($bad.Count) { return New-HarnessOutcome FAIL ($bad -join '; ') }
    $fxCount = @($Layout.Tracks | ForEach-Object { $_.Fx }).Count
    $summary = "block $($s.block) and rate $($s.sr) read back, anticipative FX $($af ? 'on' : 'off'); $fxCount FX report the configured latency; $($Reads.Count) parameters read back"
    if ($proof) { $summary += "; states saved back unchanged: $($proof.Proven -join ', ')" }
    New-HarnessOutcome PASS $summary
}

function Invoke-HarnessSaveReopenScenario($Ctx, $s) {
    $Layout = Get-HarnessLayout $Ctx $s.layout
    $af = [bool]$s.host.AnticipativeFx
    $reopens = [int]$s.cycles
    $r = New-HarnessRun -Ctx $Ctx -Name $s.id -Layout $Layout -Sr $s.sr -Block $s.block -Mode $s.mode -Bypass $s.bypass -AnticipativeFx $af -RunFxWhenStopped ([bool]$s.host.RunFxWhenStopped)
    $copy = Join-Path $Ctx.Work "$($s.id)-saved.rpp"
    if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy }
    $Ctx.Files.Add($copy)
    $Reads = Get-HarnessParamReads $Layout
    $lua = Invoke-HarnessLuaStep -Ctx $Ctx -Name $s.id -Step savereopen -Job @{ project = $r.Project; saveAs = $copy; reads = (ConvertTo-LuaReads $Reads); cycles = $reopens }
    if ($lua.Why) { return New-HarnessOutcome INCOMPLETE $lua.Why }
    $bad = [Collections.Generic.List[string]]::new()
    $prefixes = @('before_') + @(1..$reopens | ForEach-Object { "after${_}_" })
    foreach ($Prefix in $prefixes) {
        foreach ($p in (Test-HarnessFxReport -Facts $lua.Result -Prefix $Prefix -Layout $Layout -Names $Ctx.Names -Plugins $Ctx.Config.Plugins -Bypass $s.bypass -Reads $Reads)) { $bad.Add($p) }
    }
    foreach ($p in (Test-HarnessReopenFacts -Facts $lua.Result -Cycles $reopens)) { $bad.Add($p) }
    if ($lua.Result['saved'] -ne 'true') { $bad.Add('no new project file was saved') }
    $proof = $null
    if ((Test-HarnessHasStates $Layout) -and (Test-Path -LiteralPath $copy)) {
        $proof = Test-HarnessStateProof -Layout $Layout -Blocks $Ctx.Blocks -States $Ctx.States -Saved (Get-HarnessFxBlocks ([IO.File]::ReadAllText($copy)))
        foreach ($p in $proof.Problems) { $bad.Add($p) }
    }
    if ($bad.Count) { return New-HarnessOutcome FAIL ($bad -join '; ') }
    $res = Invoke-HarnessRender $Ctx $r.Project $r.Wav
    if ($res.Why) { return New-HarnessOutcome INCOMPLETE "the render before saving failed: $($res.Why)" }
    $reopened = Join-Path $Ctx.Work "$($s.id)-saved.wav"
    if (Test-Path -LiteralPath $reopened) { Remove-Item -LiteralPath $reopened }
    # The saved copy keeps the render settings of the original, so it renders to the same name: move the first
    # render aside first.
    Move-Item -LiteralPath $r.Wav -Destination $reopened
    $Ctx.Files.Add($reopened)
    $res2 = Invoke-HarnessRender $Ctx $copy $r.Wav
    if ($res2.Why) { return New-HarnessOutcome INCOMPLETE "the render of the reopened project failed: $($res2.Why)" }
    $cmp = Compare-HarnessWavFiles -A $reopened -B $r.Wav -LagSearch ([int]$Ctx.Limits.lagSearch) -HeadSeconds ([double]$Ctx.Limits.headSeconds)
    $stateText = $proof ? "; states saved back unchanged: $($proof.Proven -join ', ')" : ''
    New-HarnessOutcome $cmp.Status "FX state unchanged after $reopens save and reopen cycle$($reopens -eq 1 ? '' : 's') ($($Reads.Count) parameters)$stateText; reopened render vs original: $($cmp.Detail)"
}

function Invoke-HarnessInstancesScenario($Ctx, $s) {
    $empty = [pscustomobject]@{ Id = '@empty'; Tracks = @(); Plugins = @() }
    $r = New-HarnessRun -Ctx $Ctx -Name $s.id -Layout $empty -Sr $s.sr -Block $s.block -AnticipativeFx ([bool]$s.host.AnticipativeFx) -RunFxWhenStopped ([bool]$s.host.RunFxWhenStopped)
    $Watch = @{ warm = (Join-Path $Ctx.Work "$($s.id).warm"); loop = (Join-Path $Ctx.Work "$($s.id).loop") }
    $Names = @($s.plugins | ForEach-Object { $Ctx.AddNames.ContainsKey($_) ? $Ctx.AddNames[$_] : $Ctx.Names[$_] })
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

# The transport kind (Transport.psm1 builds the job and judges). A readback that differs from what was asked for (the
# device, anticipative FX, Run FX when stopped, the FX of the layout) or a file in the record directory is FAIL; a
# setup that leaves no evidence is INCOMPLETE; otherwise the worst of the states. The project has no items: what the
# tested track gets comes through its input. The Lua step gets the time its windows need on top of luaTimeoutSec
# (Get-HarnessTransportTimeout).
function Invoke-HarnessTransportScenario($Ctx, $s) {
    if (-not $Ctx.ToolJsfx.Count) { return New-HarnessOutcome INCOMPLETE 'the block probe and the feed JSFX were not installed' }
    $Layout = Get-HarnessLayout $Ctx $s.layout
    $af = [bool]$s.host.AnticipativeFx
    $rfs = [bool]$s.host.RunFxWhenStopped
    $r = New-HarnessRun -Ctx $Ctx -Name $s.id -Layout $Layout -Sr $s.sr -Block $s.block -AnticipativeFx $af -RunFxWhenStopped $rfs -NoItems
    $feed = $null
    if ($null -ne $s.feed) {
        Install-HarnessFeedWav -Source ($s.feed.File ? $s.feed.File : (Get-HarnessSignal $Ctx $s.sr 2))
        $feed = [ordered]@{ source = ($s.feed.Wav ? $s.feed.Wav : 'test signal'); sha256 = ($s.feed.Wav ? $s.feed.Sha256 : $null); channels = $s.feed.Channels }
    }
    $recordDir = Join-Path $Ctx.Work "$($s.id)-record"
    $Reads = Get-HarnessParamReads $Layout
    $Job = Get-HarnessTransportJob -Scenario $s -Layout $Layout -Tools @{ 'harness-block-probe' = $Ctx.ToolJsfx['harness-block-probe'].AddName; 'harness-feed' = $Ctx.ToolJsfx['harness-feed'].AddName } -RecordDir $recordDir
    $Job.project = $r.Project
    $Job.reads = ConvertTo-LuaReads $Reads
    $lua = Invoke-HarnessLuaStep -Ctx $Ctx -Name $s.id -Step transport -Job $Job -TimeoutSec (Get-HarnessTransportTimeout -Scenario $s -LuaTimeoutSec ([double]$Ctx.Limits.luaTimeoutSec))
    $recorded = @(Get-ChildItem -LiteralPath $recordDir -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($recorded.Count) { return New-HarnessOutcome FAIL "$($recorded.Count) file(s) appeared in the record directory of the project: something was recorded" }
    if ($lua.Why) { return New-HarnessOutcome INCOMPLETE $lua.Why }
    $f = $lua.Result
    $bad = [Collections.Generic.List[string]]::new()
    foreach ($p in (Test-HarnessHostReadback -Facts $f -Block $s.block -Sr $s.sr -AnticipativeFx $af -RunFxWhenStopped $rfs)) { $bad.Add($p) }
    foreach ($p in (Test-HarnessFxReport -Facts $f -Layout $Layout -Names $Ctx.Names -Plugins $Ctx.Config.Plugins -Reads $Reads)) { $bad.Add($p) }
    if ($bad.Count) { return New-HarnessOutcome FAIL ($bad -join '; ') }
    $idents = @{ 'harness-block-probe' = $Ctx.ToolJsfx['harness-block-probe'].Ident; 'harness-feed' = $Ctx.ToolJsfx['harness-feed'].Ident }
    $gap = Test-HarnessTransportSetup -Facts $f -Scenario $s -Idents $idents -FxCount @($Layout.Tracks[$Job.track].Fx).Count
    if ($gap.Count) { return New-HarnessOutcome INCOMPLETE ($gap -join '; ') }
    $perState = [Collections.Generic.List[object]]::new()
    $judged = for ($i = 0; $i -lt $s.states.Count; $i++) {
        $st = $s.states[$i]
        $row = Read-HarnessTransportRow $f ($i + 1)
        $j = Test-HarnessTransportState -State $st -Row $row -HasFeed:($null -ne $s.feed)
        $one = [ordered]@{ name = $st.Name; transport = $st.Transport; arm = $st.Arm; monitor = $st.Monitor; windowSamples = $st.Samples; status = $j.Status; problems = @($j.Problems) }
        if ($row) { foreach ($p in $row.PSObject.Properties) { $one[$p.Name] = $p.Value } }
        $perState.Add($one)
        $j
    }
    $seen = [ordered]@{ track = $s.track; runFxWhenStopped = $rfs; runFxAfterStopMs = $f['cfg_runafterstop']; settleSamples = $f['settle']; feed = $feed; states = $perState.ToArray() }
    New-HarnessOutcome (Get-HarnessOutcomeStatus @($judged | ForEach-Object { $_.Status })) (@($judged | ForEach-Object { $_.Line }) -join ' | ') $seen
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
    instances = ${function:Invoke-HarnessInstancesScenario}; transport = ${function:Invoke-HarnessTransportScenario}; hang = ${function:Invoke-HarnessHangScenario}
}

function Get-HarnessScenarioKinds { , @($script:Handlers.get_Keys() | Sort-Object) }

# The functions extension handlers get in Ctx.Api (see docs/EXTENDING.md).
function Get-HarnessApi {
    @{
        Outcome = ${function:New-HarnessOutcome}; NewRun = ${function:New-HarnessRun}; Render = ${function:Invoke-HarnessRender}; LuaStep = ${function:Invoke-HarnessLuaStep}
        Compare = ${function:Compare-HarnessWavFiles}; HostFailure = ${function:Get-HarnessHostFailure}; Layout = ${function:Get-HarnessLayout}; Signal = ${function:Get-HarnessSignal}
        Reference = ${function:Get-HarnessReference}; HidePaths = ${function:Hide-HarnessPaths}; FxReport = ${function:Test-HarnessFxReport}; ParamReads = ${function:Get-HarnessParamReads}
        Judge = ${function:Invoke-HarnessCompare}; StateProof = ${function:Test-HarnessStateProof}; FxBlocks = ${function:Get-HarnessFxBlocks}
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
    Get-HarnessLayout, Get-HarnessRunFiles, Get-HarnessReferenceName, New-HarnessRun, Invoke-HarnessRender, Invoke-HarnessLuaStep, Get-HarnessParamReads, Test-HarnessParamValue, Test-HarnessFxReport, Get-HarnessReference,
    Get-HarnessScenarioKinds, Get-HarnessApi, Invoke-HarnessScenario, Get-HarnessSkipMarkerHit, Get-HarnessWorkrender, Test-HarnessStateProof, Invoke-HarnessCompare,
    Test-HarnessHostReadback, Test-HarnessReopenFacts, Get-HarnessRunAllOnStop

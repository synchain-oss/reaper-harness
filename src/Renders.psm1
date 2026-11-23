# SPDX-License-Identifier: MIT
#
# Kept renders, their manifest, and the version of the harness itself.
#   Get-HarnessToolVersion      { version (one constant); commit } of this harness
#   Get-HarnessGitCommit <dir>  the commit checked out in a directory, read from its .git without running git: .git as a
#                               directory or as a "gitdir:" file (worktrees, with commondir), HEAD as a commit or as a
#                               ref resolved through its loose file or packed-refs. Anything unexpected gives $null,
#                               never an error and never a path. Changes not committed are not detected.
#   New-HarnessKeep             what one run keeps: <ResultDir>/renders/<run stamp>/, run fields of every manifest line
#   Save-HarnessKeptRender      after the verdict of a render scenario with keep: moves its own render and stems to
#                               run<k>/<id>.wav and run<k>/<id>-stem-<track>.wav, never over a file that is there, then
#                               appends its manifest line (written and flushed at once, every string masked). The
#                               first one checks that renders/<stamp> is under the result directory (real paths) and
#                               claims it by creating the manifest: a run of the same second finds it and keeps nothing.
#                               A repeat that reports its residual keeps its first render too (run<k>/<id>-first.wav
#                               and -first-stem-<track>.wav) when the two differ, or always with keepFirst.
#                               Returns Status and Detail of the row (INCOMPLETE added when something could not be
#                               kept or a kept file could not be read, FAIL stays FAIL) and the Record. Probe: the
#                               scenario's collected files (Save-HarnessProbeFiles), the line's probe.
#   Save-HarnessProbeFiles      after a render scenario with probe returned (every launch of it has ended), with or
#                               without keep: the files its plugin wrote into the probe directory move to
#                               run<k>/<id>.out/<name> (Get-HarnessProbeSelection decides which; the run directory is
#                               claimed as for keeping). Never throws; returns Status, Detail (a collection problem is
#                               INCOMPLETE, FAIL stays FAIL) and Facts ($null when it stopped on an unexpected error).
#   ConvertTo-HarnessProbeRowFacts  those facts as the row has them: dir relative to the result directory, masked
#   Move-HarnessKeptFile        one file, only to a place under the result directory, never over another (pure on files);
#                               -Retry: a move that met a sharing violation is tried again (Invoke-HarnessHeldRetry)
#   Get-HarnessKeptFileFacts    a kept file: path, sha256, frames, channels, sampleRate, format, peakDb, nanCount, infCount
#   Get-HarnessFxFacts          every FX of a layout as rendered: plugin, binary hash, bypass, state, the hash of its
#                               block as written into the project, the parameters asked for (value and display text)
#                               and read back, the latency
#   ConvertTo-HarnessKeptFacts  a record with its paths relative to the result directory (the facts of the row)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Guard.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Json.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Wav.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Rpp.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Plugins.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Sources.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Scenarios.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Probe.psm1') -ErrorAction Stop

$script:ToolVersion = '0.1.0'
$script:Hex40 = '^[0-9a-f]{40}$'

function Get-HarnessGitCommit([string]$Root) {
    try {
        $dotGit = Join-Path $Root '.git'
        if (Test-Path -LiteralPath $dotGit -PathType Container) { $gitDir = $dotGit }
        elseif (Test-Path -LiteralPath $dotGit -PathType Leaf) {
            $m = [regex]::Match([IO.File]::ReadAllText($dotGit), '\Agitdir: ([^\r\n]+)\r?\n?\z')
            if (-not $m.Success) { return $null }
            $gitDir = [IO.Path]::GetFullPath($m.Groups[1].Value, $Root)
        } else { return $null }
        $common = $gitDir
        $cd = Join-Path $gitDir 'commondir'
        if (Test-Path -LiteralPath $cd -PathType Leaf) { $common = [IO.Path]::GetFullPath([IO.File]::ReadAllText($cd).Trim(), $gitDir) }
        $head = [IO.File]::ReadAllText((Join-Path $gitDir 'HEAD')).Trim()
        if ($head -cmatch $script:Hex40) { return $head }
        $r = [regex]::Match($head, '\Aref: (refs/[A-Za-z0-9._/-]+)\z')
        if (-not $r.Success -or $r.Groups[1].Value.Contains('..')) { return $null }
        $ref = $r.Groups[1].Value
        foreach ($d in $gitDir, $common) {
            $f = Join-Path $d $ref
            if (Test-Path -LiteralPath $f -PathType Leaf) { $v = [IO.File]::ReadAllText($f).Trim(); return ($v -cmatch $script:Hex40) ? $v : $null }
        }
        $packed = Join-Path $common 'packed-refs'
        if (Test-Path -LiteralPath $packed -PathType Leaf) {
            foreach ($line in [IO.File]::ReadAllLines($packed)) { if ($line -cmatch '\A([0-9a-f]{40}) (\S+)\z' -and $Matches[2] -ceq $ref) { return $Matches[1] } }
        }
        $null
    } catch { $null }
}

function Get-HarnessToolVersion { [ordered]@{ version = $script:ToolVersion; commit = (Get-HarnessGitCommit ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))) } }

# Run: the fields every manifest line repeats (reaper, toolVersion, toolCommit, buildLabel, config).
function New-HarnessKeep([Parameter(Mandatory)][string]$ResultDir, [Parameter(Mandatory)][string]$Stamp, [System.Collections.IDictionary]$Run = [ordered]@{}) {
    $dir = Join-Path $ResultDir "renders/$Stamp"
    [pscustomobject]@{ ResultDir = $ResultDir; Stamp = $Stamp; Rel = "renders/$Stamp"; Dir = $dir; Manifest = (Join-Path $dir 'manifest.jsonl'); Run = $Run; Checked = $false; Refused = ''; Lines = 0 }
}

# A scanner or the plugin's own process may hold a file a moment longer. Only a sharing violation (an IOException,
# also inside the exception PowerShell wraps around it) is worth another try: at most three, 200 ms apart. Any other
# error is thrown at once.
function Test-HarnessSharingViolation([Exception]$Failure) {
    for ($inner = $Failure; $null -ne $inner; $inner = $inner.InnerException) { if ($inner -is [IO.IOException] -and ($inner.HResult -band 0xFFFF) -in 32, 33) { return $true } }
    $false
}

function Invoke-HarnessHeldRetry([Parameter(Mandatory)][scriptblock]$Action) {
    for ($attempt = 0; ; $attempt++) {
        try { return & $Action }
        catch { if ($attempt -ge 3 -or -not (Test-HarnessSharingViolation $_.Exception)) { throw } }
        Start-Sleep -Milliseconds 200
    }
}

# A real path that cannot be read (links that lead round in a circle, nested too deep) proves nothing: refused too.
function Move-HarnessKeptFile([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To, [Parameter(Mandatory)][string]$ResultDir, [switch]$Retry) {
    $leaf = Split-Path -Leaf $To
    try { $inside = (Test-HarnessUnder $To $ResultDir) -and (Test-HarnessUnder (Resolve-HarnessRealPath $To) (Resolve-HarnessRealPath $ResultDir)) }
    catch { return "$leaf cannot be shown to be under the result directory: $($_.Exception.Message -replace '\s+', ' ')" }
    if (-not $inside) { return "$leaf would not be under the result directory" }
    if (Test-Path -LiteralPath $To) { return "$leaf is there already and is never overwritten" }
    try { $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $To); if ($Retry) { Invoke-HarnessHeldRetry { [IO.File]::Move($From, $To, $false) } } else { [IO.File]::Move($From, $To, $false) } }
    catch { return "$leaf could not be moved there: $($_.Exception.Message -replace '\s+', ' ')" }
    $null
}

# Rel: the path the manifest names the file by ('' when nothing was kept: every field is null then). peakDb is null for
# a file without a finite sample above zero. A kept file that cannot be read (a scanner holding it, not a WAV) keeps
# the fields read so far, and the reason goes to Reasons.
function Get-HarnessKeptFileFacts([string]$Path, [string]$Rel, [Collections.Generic.List[string]]$Reasons = [Collections.Generic.List[string]]::new()) {
    $f = [ordered]@{ path = $null; sha256 = $null; frames = $null; channels = $null; sampleRate = $null; format = $null; peakDb = $null; nanCount = $null; infCount = $null }
    if (-not $Rel) { return $f }
    $f.path = $Rel
    try {
        $f.sha256 = Get-HarnessSha256 $Path
        $scan = Get-HarnessWavScan $Path
        $f.frames = $scan.Info.Frames; $f.channels = $scan.Info.Channels; $f.sampleRate = $scan.Info.Rate; $f.format = $scan.Info.Format
        $f.peakDb = ($scan.Peak -gt 0) ? [Math]::Round(20 * [Math]::Log10($scan.Peak), 6) : $null
        $f.nanCount = $scan.Nan; $f.infCount = $scan.Inf
    } catch { $Reasons.Add("$(Split-Path -Leaf $Rel) could not be read: $($_.Exception.Message -replace '\s+', ' ')") }
    $f
}

function Get-HarnessFxFacts([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Layout, [string[]]$Bypass = @()) {
    , @(foreach ($t in $Layout.Tracks) {
            for ($i = 0; $i -lt $t.Fx.Count; $i++) {
                $fx = $t.Fx[$i]
                $vst = $Ctx.Installed.ContainsKey($fx.Plugin) ? $Ctx.Installed[$fx.Plugin] : $null
                $js = $Ctx.Jsfx.ContainsKey($fx.Plugin) ? $Ctx.Jsfx[$fx.Plugin] : $null
                $read = $Ctx.LearnReads.ContainsKey($fx.Variant) ? $Ctx.LearnReads[$fx.Variant] : $null
                $sk = "$($fx.Plugin)@$($fx.State)"
                $pdc = 0
                [ordered]@{
                    track = $t.Name; index = $i; plugin = $fx.Plugin; bundle = ($vst ? $vst.Bundle : $null); jsfx = ($js ? $js.Jsfx : $null); name = ($read ? $read.Name : $null)
                    version = ($vst ? $vst.Info.Version : $null)
                    sha256 = ($vst ? $vst.Sha256.Substring(0, 12) : ($js ? $js.Sha256.Substring(0, 12) : $null)); bypass = (Test-HarnessFxBypassed $fx $Bypass)
                    state = ($fx.State ? $fx.State : $null); stateSha256 = (($fx.State -and $Ctx.States.Contains($sk)) ? $Ctx.States[$sk].Sha : $null)
                    blockSha256 = ($Ctx.Blocks.ContainsKey($fx.Variant) ? (Get-HarnessBlockTextSha $Ctx.Blocks[$fx.Variant]) : $null)
                    params = @(foreach ($pn in $fx.Params.get_Keys()) {
                            $back = ($read -and $read.Params.Contains($pn)) ? $read.Params[$pn] : $null
                            [ordered]@{ name = $pn; normalized = $fx.Params[$pn].Normalized; display = $fx.Params[$pn].Display; readNormalized = ($back ? $back.Read : $null); readDisplay = ($back ? $back.Display : $null) }
                        })
                    pdc = (($read -and [int]::TryParse([string]$read.Pdc, [ref]$pdc)) ? $pdc : $null); pdcReadAt = ($read ? [ordered]@{ sr = $read.Sr; block = $read.Block } : $null)
                }
            }
        })
}

function Get-HarnessSourceFacts([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Layout) {
    , @(foreach ($t in $Layout.Tracks) {
            if (-not $t.Source) { continue }
            $file = Get-HarnessTrackFile $t
            if ($file) {
                $key = Get-HarnessSourceKey $Ctx.Config.ConfigDir $file
                $c = $Ctx.SourceCopies.ContainsKey($key) ? $Ctx.SourceCopies[$key] : $null
                [ordered]@{ track = $t.Name; file = ($c ? (ConvertTo-HarnessSourceFact $c.File) : [ordered]@{ path = $key }); signal = $null }
            } else {
                $g = $t.Signal ?? $Ctx.Signal
                [ordered]@{ track = $t.Name; file = $null; signal = [ordered]@{ seconds = $Ctx.Signal.Seconds; seed = $g.Seed; noiseDb = $g.NoiseDb; sine = (($g.SineHz -gt 0) ? [ordered]@{ hz = $g.SineHz; db = $g.SineDb } : $null) } }
            }
        })
}

# Why nothing of this run can be kept ('' when it can): renders/<stamp> must be under the result directory, links and
# junctions resolved, before anything is made there, and it is claimed by creating its manifest, which a run started in
# the same second finds there. Never throws: whatever goes wrong is the reason, for every scenario of the run.
function Get-HarnessKeepRefusal([Parameter(Mandatory)]$Keep) {
    try { $inside = Test-HarnessUnder (Resolve-HarnessRealPath $Keep.Dir) (Resolve-HarnessRealPath $Keep.ResultDir) }
    catch { return "$($Keep.Rel) cannot be shown to be under the result directory: $($_.Exception.Message -replace '\s+', ' ')" }
    if (-not $inside) { return "$($Keep.Rel) would not be under the result directory" }
    try { $null = New-Item -ItemType Directory -Force -Path $Keep.Dir; [IO.FileStream]::new($Keep.Manifest, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read).Dispose(); '' }
    catch { (Test-Path -LiteralPath $Keep.Manifest) ? "$($Keep.Rel)/manifest.jsonl is there already (a run started in the same second)" : "$($Keep.Rel) could not be made: $($_.Exception.Message -replace '\s+', ' ')" }
}

# Keeping and collecting check and claim the run directory once for the whole run: the refusal, '' when it may be used.
function Get-HarnessKeepClaim([Parameter(Mandatory)]$Keep) {
    # The refusal is set before the claim counts as done: a claim that threw is tried again, never taken as made
    if (-not $Keep.Checked) { $Keep.Refused = Get-HarnessKeepRefusal $Keep; $Keep.Checked = $true }
    $Keep.Refused
}

function Get-HarnessWorse([string]$A, [string]$B) { foreach ($x in 'FAIL', 'INCOMPLETE') { if ($x -cin $A, $B) { return $x } }; 'PASS' }

# Whether the first render of a repeat is kept as well (pure): only when the residual is reported (Comparison: the
# row's comparison, $null when nothing reports), always with keepFirst, else when the master or a stem compared with
# the reference is not known to be bit-identical.
function Test-HarnessKeepFirst($Scenario, $Comparison) {
    if ($null -eq $Comparison -or $Scenario.compare.Kind -cne 'repeat') { return $false }
    if ($Scenario.PSObject.Properties['keepFirst'] -and $Scenario.keepFirst) { return $true }
    foreach ($x in @($Comparison['master']) + @($Comparison['stems'])) { if ($null -eq $x -or $x['identical'] -ne $true) { return $true } }
    $false
}

# Comparison, Tail and Probe: the row's comparison, tail and probe facts ($null when it has none), written into the line.
function Save-HarnessKeptRender {
    param([Parameter(Mandatory)]$Keep, [Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Scenario, [int]$Round = 1, [Parameter(Mandatory)][string]$Status, [string]$Detail = '',
          $Comparison = $null, $Tail = $null, $Probe = $null)
    $s = $Scenario
    try {
        $null = Get-HarnessKeepClaim $Keep
        $problems = [Collections.Generic.List[string]]::new() # what was not kept
        $unread = [Collections.Generic.List[string]]::new() # what was kept but could not be described
        if ($Keep.Refused) { $problems.Add($Keep.Refused) }
        $stemTracks = @($s.stems | ForEach-Object { $_.Track })
        $files = Get-HarnessRunFiles $Ctx.Work $s.id $stemTracks
        # The master of a render with stems is <id>-stem-Master.wav in the work directory; kept, it is <id>.wav
        $planOf = { param($From, [string]$Name)
            @([pscustomobject]@{ From = $From.Wav; Leaf = "$Name.wav"; Track = '' }) + @(foreach ($t in $From.Stems.get_Keys()) { [pscustomobject]@{ From = $From.Stems[$t]; Leaf = "$Name-stem-$t.wav"; Track = $t } }) }
        $move = { param($p)
            $keptRel = "run$Round/$($p.Leaf)"
            $dest = Join-Path $Keep.Dir $keptRel
            $kept = $false
            # No file (the render failed): nothing to move; the line still says how the scenario ended
            if (-not $Keep.Refused -and (Test-Path -LiteralPath $p.From -PathType Leaf)) {
                $why = Move-HarnessKeptFile -From $p.From -To $dest -ResultDir $Keep.ResultDir
                if ($why) { $problems.Add($why) } else { $kept = $true; while ($Ctx.Files.Remove($p.From)) { } }
            }
            $facts = Get-HarnessKeptFileFacts $dest ($kept ? $keptRel : '') $unread
            if ($p.Track) { $named = [ordered]@{ track = $p.Track }; foreach ($k in $facts.get_Keys()) { $named[$k] = $facts[$k] }; $facts = $named }
            $facts
        }
        $out = @(foreach ($p in (& $planOf $files $s.id)) { & $move $p })
        # The first render of a reported repeat, with its stems compared with the reference: kept next to the second
        # when the two differ (or with keepFirst), described in comparison.first; else a work file
        $cmp = $null
        if ($null -ne $Comparison) {
            $cmp = [ordered]@{}; foreach ($k in $Comparison.get_Keys()) { $cmp[$k] = $Comparison[$k] }
            $cmp.first = $null
            if (Test-HarnessKeepFirst $s $Comparison) {
                $firstFiles = Get-HarnessRunFiles $Ctx.Work "$($s.id)-first" @($s.stems | Where-Object { $_.Compare -eq 'reference' } | ForEach-Object { $_.Track })
                $firstOut = @(foreach ($p in (& $planOf $firstFiles "$($s.id)-first")) { & $move $p })
                $cmp.first = $firstOut[0]; $cmp.first['stems'] = @($firstOut | Select-Object -Skip 1)
            }
        }
        # The layout as rendered (the variant's, when it is one); a plugin whose latency is only reported has it read at
        # learning: a kept render without that reading is not described in full
        $scenarioLayout = Get-HarnessScenarioLayout $Ctx.Config $s
        $fxFacts = Get-HarnessFxFacts $Ctx $scenarioLayout @($s.bypass)
        if ($out[0]['path']) { foreach ($x in $fxFacts) { if ($Ctx.Config.Plugins[$x.plugin].ExpectPdc -is [string] -and $null -eq $x.pdc) { $unread.Add("the latency of $($x.plugin) on $($x.track) was not read") } } }
        if ($problems.Count) { $Status = Get-HarnessWorse $Status 'INCOMPLETE'; $Detail += "; not kept: $($problems -join '; ')" }
        if ($unread.Count) { $Status = Get-HarnessWorse $Status 'INCOMPLETE'; $Detail += "; kept, but $($unread -join '; ')" }
        $record = [ordered]@{
            schema = 1; runStamp = $Keep.Stamp; round = $Round; scenario = $s.id; baseScenario = ($s.PSObject.Properties['baseId'] ? $s.baseId : $s.id)
            variant = ($s.PSObject.Properties['variant'] ? $s.variant : $null); layout = $s.layout; kind = $s.kind
            status = $Status; detail = $Detail; output = $out[0]; stems = @($out | Select-Object -Skip 1)
            render = [ordered]@{ sr = $s.sr; block = $s.block; mode = $s.mode; channels = ($s.mono ? 1 : 2)
                tailSeconds = ($s.PSObject.Properties['tailSeconds'] ? [double]$s.tailSeconds : 0.0); tailFrames = ($s.PSObject.Properties['tailFrames'] ? [long]$s.tailFrames : [long]0)
                endPeakDb = (($Tail -is [Collections.IDictionary]) ? $Tail['endPeakDb'] : $null)
                host = [ordered]@{ anticipativeFx = [bool]$s.host.AnticipativeFx; runFxWhenStopped = [bool]$s.host.RunFxWhenStopped; informOfflineState = [bool]$s.host.InformOfflineState } }
            comparison = $cmp; probe = $Probe; sources = (Get-HarnessSourceFacts $Ctx $scenarioLayout); fx = $fxFacts
        }
        foreach ($k in $Keep.Run.get_Keys()) { $record[$k] = $Keep.Run[$k] }
        $record = Hide-HarnessFacts $record # every string of the line, keys too: details carry exception texts, names come from plugins
        if (-not $Keep.Refused) {
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-HarnessJsonText -Value $record) + "`n")
                $fs = [IO.FileStream]::new($Keep.Manifest, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
                try {
                    # A line a write that failed left unfinished (a full disk) stays on a line of its own: this one starts after it
                    if ($fs.Length -gt 0) { $null = $fs.Seek(-1, [IO.SeekOrigin]::End); if ($fs.ReadByte() -ne 10) { $fs.WriteByte(10) } }
                    $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true)
                } finally { $fs.Dispose() }
                $Keep.Lines++
            } catch { $Status = Get-HarnessWorse $Status 'INCOMPLETE'; $Detail += "; its manifest line could not be written: $($_.Exception.Message -replace '\s+', ' ')" }
        }
        [pscustomobject]@{ Status = $Status; Detail = $Detail; Record = $record }
    } catch {
        [pscustomobject]@{ Status = (Get-HarnessWorse $Status 'INCOMPLETE'); Detail = "$Detail; not kept: keeping it stopped on an unexpected error: $($_.Exception.Message -replace '\s+', ' ')"; Record = $null }
    }
}

# The row's copy of a manifest line: paths relative to the result directory instead of the manifest's directory.
function ConvertTo-HarnessKeptFacts([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Rel) {
    $copy = ConvertFrom-HarnessJson (ConvertTo-HarnessJsonText -Value $Entry)
    $first = ($copy['comparison'] -is [Collections.IDictionary]) ? $copy['comparison']['first'] : $null
    foreach ($f in @($copy['output']) + @($copy['stems']) + @($first) + @($first ? $first['stems'] : @())) { if ($f -and $f['path']) { $f['path'] = "$Rel/$($f['path'])" } }
    if ($copy.Contains('probe') -and $copy['probe'] -is [Collections.IDictionary] -and $copy['probe']['dir']) { $copy['probe']['dir'] = "$Rel/$($copy['probe']['dir'])" }
    $copy
}

function Save-HarnessProbeFiles {
    param([Parameter(Mandatory)]$Keep, [Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Scenario, [int]$Round = 1, [Parameter(Mandatory)][string]$Status, [string]$Detail = '')
    $s = $Scenario
    try {
        $plan = Get-HarnessProbePlan -ConfigDir $Ctx.Config.ConfigDir -Scenario $s -Work $Ctx.Work -Checked $Ctx['ProbeFiles']
        if ($null -eq $plan) { return [pscustomobject]@{ Status = $Status; Detail = $Detail; Facts = $null } }
        $runs = $Ctx['ProbeRuns']
        $made = ($runs -is [Collections.IDictionary]) -and $runs.Contains($s.id)
        $probeFacts = [ordered]@{
            variables = @(foreach ($v in $plan.Vars) {
                    $isFile = $v.Kind -ceq 'file'
                    [ordered]@{ name = $v.Name; plugin = $v.Plugin; kind = $v.Kind; path = ($isFile ? $v.Key : $null); sha256 = (($isFile -and $v.Checked) ? $v.Checked.Sha256 : $null)
                        bytes = (($isFile -and $v.Checked) ? $v.Checked.Bytes : $null); min = ($isFile ? $null : $v.Min) }
                })
            pid = $null; dir = $null; files = @(); collected = 0; bytes = [long]0; temporary = 0; left = 0
        }
        $notes = [Collections.Generic.List[string]]::new() # each a '; probe: ...' part of the detail
        $bad = $false
        if ($made) {
            # The REAPER of the scenario's own render: the last process started after the run was made (a retry's, if any)
            if ($Ctx.Started.Count -gt $runs[$s.id].From) { $probeFacts.pid = $Ctx.Started[$Ctx.Started.Count - 1].Pid }
            # The plugin may have changed its own input copy; a retry would then have run on other bytes. A copy that
            # cannot be read is noted, and collection goes on
            foreach ($v in @($plan.Vars | Where-Object { $_.Kind -ceq 'file' })) {
                try { $now = (Test-Path -LiteralPath $v.Path -PathType Leaf) ? (Invoke-HarnessHeldRetry { Get-HarnessSha256 $v.Path }) : $null }
                catch { $notes.Add("the probe input $($v.Name) could not be read back: $($_.Exception.Message -replace '\s+', ' ')"); $bad = $true; continue }
                if (-not $v.Checked -or $now -cne $v.Checked.Sha256) { $notes.Add("the probe input $($v.Name) changed during the launch"); $bad = $true }
            }
        }
        $d = $plan.Dir
        if ($d) {
            $probeFacts.left = $null
            $leaf = Split-Path -Leaf $d.Path
            $attr = try { [IO.File]::GetAttributes($d.Path) } catch { $null }
            $stop = if (-not $made) { 'the directory was not made' }
            elseif ($Ctx.StillRunning) { 'nothing collected: a REAPER of this round could not be ended and may still write there' }
            elseif ($null -eq $attr) { 'nothing collected: the directory is not there any more' }
            # Only an ancestor of the work directory may be a link; the directory itself is never followed. The real path
            # backs the attributes up: a directory swapped for a link after they were read resolves elsewhere
            elseif (($attr -band [IO.FileAttributes]::ReparsePoint) -or -not ($attr -band [IO.FileAttributes]::Directory) -or
                (Resolve-HarnessRealPath $d.Path) -ine [IO.Path]::Join((Resolve-HarnessRealPath $Ctx.Work), $leaf)) { 'nothing collected: the directory was replaced by a link or junction' }
            else { $null }
            $listed = $stop ? $null : (Get-HarnessProbeEntries -Path $d.Path)
            if ($listed -and $listed.Over) { $stop = 'nothing collected: more than 10000 entries' }
            if ($stop) { $notes.Add($stop); $bad = $true }
            else {
                $sel = Get-HarnessProbeSelection -Entries $listed.Entries -Min $d.Min
                $notMoved = [Collections.Generic.List[string]]::new()
                foreach ($p in $sel.Problems) { $notMoved.Add($p) }
                $left = $sel.Left
                $refused = $sel.Move.Count ? (Get-HarnessKeepClaim $Keep) : ''
                if ($refused) { $notMoved.Add($refused); $left += $sel.Move.Count }
                $outRel = "run$Round/$($s.id).out"
                $got = [Collections.Generic.List[object]]::new()
                $unread = [Collections.Generic.List[string]]::new()
                foreach ($m in @($sel.Move | Where-Object { -not $refused })) {
                    $dest = Join-Path $Keep.Dir "$outRel/$($m.Name)"
                    $why = Move-HarnessKeptFile -From (Join-Path $d.Path $m.Name) -To $dest -ResultDir $Keep.ResultDir -Retry
                    if ($why) { $notMoved.Add($why); $left++; continue }
                    $one = [ordered]@{ name = $m.Name; bytes = $null; sha256 = $null; temporary = $m.Temporary }
                    try { $one.sha256 = Invoke-HarnessHeldRetry { Get-HarnessSha256 $dest }; $one.bytes = [IO.FileInfo]::new($dest).Length }
                    catch { $one.sha256 = $null; $unread.Add("$($m.Name) could not be read: $($_.Exception.Message -replace '\s+', ' ')") }
                    $got.Add($one)
                }
                $probeFacts.dir = $got.Count ? $outRel : $null
                $probeFacts.files = $got.ToArray()
                $probeFacts.collected = $got.Count
                $probeFacts.bytes = [long](@($got | ForEach-Object { [long]($_.bytes ?? 0) }) | Measure-Object -Sum).Sum
                $probeFacts.temporary = @($got | Where-Object { $_.temporary }).Count
                $probeFacts.left = $left
                $line = "$(Get-HarnessCount $got.Count 'file') collected, $($probeFacts.bytes) bytes" + ($probeFacts.temporary ? ", $($probeFacts.temporary) temporary" : '')
                if ($notMoved.Count) { $line += "; not collected: $($notMoved -join '; ')"; $bad = $true }
                $notes.Add($line)
                foreach ($u in $unread) { $notes.Add("collected, but $u"); $bad = $true }
            }
        }
        if ($bad) { $Status = Get-HarnessWorse $Status 'INCOMPLETE' }
        foreach ($n in $notes) { $Detail += "; probe: $n" }
        [pscustomobject]@{ Status = $Status; Detail = $Detail; Facts = $probeFacts }
    } catch {
        [pscustomobject]@{ Status = (Get-HarnessWorse $Status 'INCOMPLETE'); Detail = "$Detail; probe: collection stopped on an unexpected error: $($_.Exception.Message -replace '\s+', ' ')"; Facts = $null }
    }
}

# The row's copy of the probe facts: dir relative to the result directory, like facts.kept, every string masked.
function ConvertTo-HarnessProbeRowFacts($Probe, [string]$Rel) {
    if ($null -eq $Probe) { return $null }
    $copy = ConvertFrom-HarnessJson (ConvertTo-HarnessJsonText -Value $Probe)
    if ($copy['dir']) { $copy['dir'] = "$Rel/$($copy['dir'])" }
    Hide-HarnessFacts $copy
}

Export-ModuleMember -Function Get-HarnessToolVersion, Get-HarnessGitCommit, New-HarnessKeep, Move-HarnessKeptFile, Get-HarnessKeptFileFacts, Get-HarnessFxFacts, Get-HarnessSourceFacts,
    Save-HarnessKeptRender, ConvertTo-HarnessKeptFacts, Get-HarnessKeepClaim, Save-HarnessProbeFiles, ConvertTo-HarnessProbeRowFacts
